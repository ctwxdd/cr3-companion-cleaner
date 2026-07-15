import CryptoKit
import Darwin
import Foundation

/// Detached Foundation workers do not automatically drain autoreleased NSData
/// buffers. A pool per chunk keeps large card/library scans at constant memory.
private func forEachFileChunk(at url: URL, body: (Data) throws -> Void) throws {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1)
    while true {
        try Task.checkCancellation()
        let hadData = try autoreleasepool { () throws -> Bool in
            guard let data = try handle.read(upToCount: 4 * 1_024 * 1_024), !data.isEmpty else {
                return false
            }
            try body(data)
            return true
        }
        if !hadData { break }
    }
}

private func streamedSHA256(of url: URL) throws -> String {
    var hasher = SHA256()
    try forEachFileChunk(at: url) { hasher.update(data: $0) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

enum BackupCheckStatus: String, Sendable {
    case backedUp = "Backed Up"
    case notFound = "Not Found"
}

struct BackupCheckItem: Identifiable, Hashable, Sendable {
    let sourceURL: URL
    let backupURL: URL?
    let byteCount: Int64

    var id: URL { sourceURL }
    var status: BackupCheckStatus { backupURL == nil ? .notFound : .backedUp }
}

struct BackupCheckReport: Sendable {
    let items: [BackupCheckItem]
    let cardFileCount: Int
    let backupFileCount: Int
    let errors: [FileOperationFailure]
    let cachedHashCount: Int
    let hashedByteCount: Int64
}

struct BackupCheckProgress: Sendable {
    let stage: String
    let completedCount: Int
    let totalCount: Int?
    let currentFileName: String
}

struct BackupSpacePlan: Sendable {
    let fileCount: Int
    let requiredByteCount: Int64
    let availableByteCount: Int64
    let destinationRoot: URL

    var remainingByteCount: Int64 { availableByteCount - requiredByteCount }
    var hasEnoughSpace: Bool { requiredByteCount <= availableByteCount }
}

struct BackedUpItem: Sendable {
    let sourceURL: URL
    let destinationURL: URL
}

struct BackupCopyReport: Sendable {
    let requestedCount: Int
    let copiedItems: [BackedUpItem]
    let failures: [FileOperationFailure]
    let wasCancelled: Bool
}

struct BackupCopyProgress: Sendable {
    let stage: String
    let completedFileCount: Int
    let totalFileCount: Int
    let copiedByteCount: Int64
    let totalByteCount: Int64
    let currentFileName: String
}

enum BackupCopyError: LocalizedError {
    case insufficientSpace(required: Int64, available: Int64)
    case sourceOutsideCard(URL)
    case destinationExists(URL)
    case unsafeDestination(URL)
    case cannotCreateTemporaryFile(URL)
    case verificationFailed(URL)

    var errorDescription: String? {
        switch self {
        case .insufficientSpace(let required, let available):
            return "The backup needs \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file)), but only \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) is available."
        case .sourceOutsideCard(let url):
            return "The source is outside the selected memory card: \(url.path)"
        case .destinationExists(let url):
            return "A different file already exists and was not overwritten: \(url.path)"
        case .unsafeDestination(let url):
            return "The destination contains a symbolic link and was not used: \(url.path)"
        case .cannotCreateTemporaryFile(let url):
            return "A temporary backup file could not be created: \(url.path)"
        case .verificationFailed(let url):
            return "The copied file did not pass SHA-256 verification: \(url.path)"
        }
    }
}

/// Copies missing media with one sequential stream. Each file is written to a
/// hidden temporary path, verified, then atomically renamed into place.
struct BackupCopyService: Sendable {
    func spacePlan(cameraCard: URL, backupFolder: URL, items: [BackupCheckItem]) throws -> BackupSpacePlan {
        let missing = items.filter { $0.status == .notFound }
        let values = try backupFolder.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ])
        // The regular value is actual free space. Some APFS system volumes
        // report zero for "important usage" even while usable space remains.
        let regularAvailable = Int64(values.volumeAvailableCapacity ?? 0)
        let available = regularAvailable > 0
            ? regularAvailable
            : (values.volumeAvailableCapacityForImportantUsage ?? 0)
        return .init(
            fileCount: missing.count,
            requiredByteCount: missing.reduce(0) { $0 + $1.byteCount },
            availableByteCount: max(0, available),
            destinationRoot: backupFolder.appendingPathComponent(cameraCard.lastPathComponent, isDirectory: true)
        )
    }

    func copyMissing(
        items: [BackupCheckItem],
        cameraCard: URL,
        backupFolder: URL,
        progress: @escaping @Sendable (BackupCopyProgress) -> Void
    ) async throws -> BackupCopyReport {
        let task = Task.detached(priority: .userInitiated) {
            try copySynchronously(items: items, cameraCard: cameraCard, backupFolder: backupFolder, progress: progress)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func copySynchronously(
        items: [BackupCheckItem],
        cameraCard: URL,
        backupFolder: URL,
        progress: @escaping @Sendable (BackupCopyProgress) -> Void
    ) throws -> BackupCopyReport {
        let missing = items.filter { $0.status == .notFound }
        let plan = try spacePlan(cameraCard: cameraCard, backupFolder: backupFolder, items: missing)
        guard plan.hasEnoughSpace else {
            throw BackupCopyError.insufficientSpace(required: plan.requiredByteCount, available: plan.availableByteCount)
        }

        var copied: [BackedUpItem] = []
        var failures: [FileOperationFailure] = []
        var completedBytes: Int64 = 0
        var wasCancelled = false

        for item in missing {
            do {
                try Task.checkCancellation()
                let destination = try destinationURL(
                    for: item.sourceURL,
                    cameraCard: cameraCard,
                    backupFolder: backupFolder
                )
                try prepareDirectory(destination.deletingLastPathComponent(), inside: backupFolder)
                guard !FileManager.default.fileExists(atPath: destination.path) else {
                    throw BackupCopyError.destinationExists(destination)
                }

                let temporary = destination.deletingLastPathComponent()
                    .appendingPathComponent(".cr3-companion-\(UUID().uuidString).partial")
                do {
                    let sourceDigest = try writeTemporaryCopy(
                        from: item.sourceURL,
                        to: temporary
                    ) { bytes in
                        progress(.init(
                            stage: "Copying",
                            completedFileCount: copied.count,
                            totalFileCount: missing.count,
                            copiedByteCount: completedBytes + bytes,
                            totalByteCount: plan.requiredByteCount,
                            currentFileName: item.sourceURL.lastPathComponent
                        ))
                    }
                    progress(.init(
                        stage: "Verifying",
                        completedFileCount: copied.count,
                        totalFileCount: missing.count,
                        copiedByteCount: completedBytes + item.byteCount,
                        totalByteCount: plan.requiredByteCount,
                        currentFileName: item.sourceURL.lastPathComponent
                    ))
                    guard sourceDigest == (try hash(of: temporary)) else {
                        throw BackupCopyError.verificationFailed(item.sourceURL)
                    }
                    try FileManager.default.moveItem(at: temporary, to: destination)
                    preserveDates(from: item.sourceURL, to: destination)
                    copied.append(.init(sourceURL: item.sourceURL, destinationURL: destination))
                    completedBytes += item.byteCount
                } catch {
                    // Only an app-created partial file is permanently removed.
                    try? FileManager.default.removeItem(at: temporary)
                    throw error
                }
            } catch is CancellationError {
                wasCancelled = true
                break
            } catch {
                failures.append(.init(url: item.sourceURL, reason: error.localizedDescription))
                if isOutOfSpace(error) { break }
            }
        }

        progress(.init(
            stage: wasCancelled ? "Cancelled" : "Complete — SHA-256 Verified",
            completedFileCount: copied.count,
            totalFileCount: missing.count,
            copiedByteCount: completedBytes,
            totalByteCount: plan.requiredByteCount,
            currentFileName: ""
        ))
        return .init(
            requestedCount: missing.count,
            copiedItems: copied,
            failures: failures,
            wasCancelled: wasCancelled
        )
    }

    private func destinationURL(for source: URL, cameraCard: URL, backupFolder: URL) throws -> URL {
        let sourceComponents = source.standardizedFileURL.pathComponents
        let rootComponents = cameraCard.standardizedFileURL.pathComponents
        guard sourceComponents.starts(with: rootComponents), sourceComponents.count > rootComponents.count else {
            throw BackupCopyError.sourceOutsideCard(source)
        }
        return sourceComponents.dropFirst(rootComponents.count).reduce(
            backupFolder.appendingPathComponent(cameraCard.lastPathComponent, isDirectory: true)
        ) { $0.appendingPathComponent($1) }
    }

    private func prepareDirectory(_ directory: URL, inside backupFolder: URL) throws {
        let root = backupFolder.standardizedFileURL
        let rootComponents = root.pathComponents
        let components = directory.standardizedFileURL.pathComponents
        guard components.starts(with: rootComponents) else { throw BackupCopyError.unsafeDestination(directory) }
        var cursor = root
        for component in components.dropFirst(rootComponents.count) {
            cursor.appendPathComponent(component, isDirectory: true)
            if FileManager.default.fileExists(atPath: cursor.path) {
                let values = try cursor.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                guard values.isSymbolicLink != true, values.isDirectory == true else {
                    throw BackupCopyError.unsafeDestination(cursor)
                }
            } else {
                try FileManager.default.createDirectory(at: cursor, withIntermediateDirectories: false)
            }
        }
    }

    private func writeTemporaryCopy(
        from source: URL,
        to temporary: URL,
        progress: (Int64) -> Void
    ) throws -> String {
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw BackupCopyError.cannotCreateTemporaryFile(temporary)
        }
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        _ = fcntl(output.fileDescriptor, F_NOCACHE, 1)
        var hasher = SHA256()
        var written: Int64 = 0
        try forEachFileChunk(at: source) { data in
            try output.write(contentsOf: data)
            hasher.update(data: data)
            written += Int64(data.count)
            progress(written)
        }
        try output.synchronize()
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func hash(of url: URL) throws -> String {
        try streamedSHA256(of: url)
    }

    private func preserveDates(from source: URL, to destination: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: source.path) else { return }
        var dates: [FileAttributeKey: Any] = [:]
        if let date = attributes[.creationDate] { dates[.creationDate] = date }
        if let date = attributes[.modificationDate] { dates[.modificationDate] = date }
        try? FileManager.default.setAttributes(dates, ofItemAtPath: destination.path)
    }

    private func isOutOfSpace(_ error: Error) -> Bool {
        let value = error as NSError
        return (value.domain == NSCocoaErrorDomain && value.code == CocoaError.fileWriteOutOfSpace.rawValue)
            || (value.domain == NSPOSIXErrorDomain && value.code == Int(ENOSPC))
    }
}

/// Read-only comparison between camera media and a backup library. Filename and
/// size create a cheap candidate set; SHA-256 confirms that contents are equal.
struct BackupCheckService: Sendable {
    private struct FileRecord: Sendable {
        let url: URL
        let byteCount: Int64
        let modificationTime: TimeInterval?
        let creationTime: TimeInterval?
        let fileIdentifier: String
        let volumeIdentifier: String
    }

    private struct HashCacheEntry: Codable {
        let byteCount: Int64
        let modificationTime: TimeInterval?
        let creationTime: TimeInterval?
        let fileIdentifier: String
        let volumeIdentifier: String
        let digest: String

        func matches(_ file: FileRecord) -> Bool {
            byteCount == file.byteCount
                && modificationTime == file.modificationTime
                && creationTime == file.creationTime
                && fileIdentifier == file.fileIdentifier
                && volumeIdentifier == file.volumeIdentifier
        }
    }

    private struct HashCacheFile: Codable {
        let version: Int
        let entries: [String: HashCacheEntry]
    }

    private struct HashStatistics {
        var cacheHits = 0
        var bytesRead: Int64 = 0
    }

    private let cacheFileURL: URL

    private struct MatchKey: Hashable, Sendable {
        let filename: String
        let byteCount: Int64
    }

    init(cacheFileURL: URL? = nil, fileManager: FileManager = .default) {
        let cacheRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.cacheFileURL = cacheFileURL ?? cacheRoot
            .appendingPathComponent("CR3 Companion Cleaner", isDirectory: true)
            .appendingPathComponent("last-backup-hashes.json")
    }

    func check(
        cameraCard: URL,
        backupFolder: URL,
        progress: @escaping @Sendable (BackupCheckProgress) -> Void
    ) async throws -> BackupCheckReport {
        let task = Task.detached(priority: .userInitiated) {
            try checkSynchronously(cameraCard: cameraCard, backupFolder: backupFolder, progress: progress)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func checkSynchronously(
        cameraCard: URL,
        backupFolder: URL,
        progress: @escaping @Sendable (BackupCheckProgress) -> Void
    ) throws -> BackupCheckReport {
        var errors: [FileOperationFailure] = []
        let cardFiles = try discoverFiles(in: cameraCard, stage: "Scanning camera card", errors: &errors, progress: progress)
        let backupFiles = try discoverFiles(in: backupFolder, stage: "Indexing backup folder", errors: &errors, progress: progress)

        let backupIndex = Dictionary(grouping: backupFiles) {
            MatchKey(filename: $0.url.lastPathComponent.lowercased(), byteCount: $0.byteCount)
        }
        let hashCache = loadHashCache()
        var usedHashCache: [String: HashCacheEntry] = [:]
        var hashStatistics = HashStatistics()
        var results: [BackupCheckItem] = []
        results.reserveCapacity(cardFiles.count)

        for (index, source) in cardFiles.enumerated() {
            try Task.checkCancellation()
            progress(.init(
                stage: "Confirming file contents",
                completedCount: index,
                totalCount: cardFiles.count,
                currentFileName: source.url.lastPathComponent
            ))
            let key = MatchKey(filename: source.url.lastPathComponent.lowercased(), byteCount: source.byteCount)
            var match: URL?
            if let candidates = backupIndex[key] {
                do {
                    let sourceHash = try digest(
                        of: source,
                        cache: hashCache,
                        usedCache: &usedHashCache,
                        statistics: &hashStatistics
                    )
                    for candidate in candidates {
                        try Task.checkCancellation()
                        do {
                            let candidateHash = try digest(
                                of: candidate,
                                cache: hashCache,
                                usedCache: &usedHashCache,
                                statistics: &hashStatistics
                            )
                            if sourceHash == candidateHash {
                                match = candidate.url
                                break
                            }
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            errors.append(.init(url: candidate.url, reason: error.localizedDescription))
                        }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    errors.append(.init(url: source.url, reason: error.localizedDescription))
                }
            }
            results.append(.init(sourceURL: source.url, backupURL: match, byteCount: source.byteCount))
        }

        // Write at most once, and only when this run computed a new digest.
        if hashStatistics.bytesRead > 0 { saveHashCache(usedHashCache) }
        progress(.init(stage: "Complete", completedCount: cardFiles.count, totalCount: cardFiles.count, currentFileName: ""))
        return .init(
            items: results.sorted { $0.sourceURL.path.localizedStandardCompare($1.sourceURL.path) == .orderedAscending },
            cardFileCount: cardFiles.count,
            backupFileCount: backupFiles.count,
            errors: errors,
            cachedHashCount: hashStatistics.cacheHits,
            hashedByteCount: hashStatistics.bytesRead
        )
    }

    /// Backups must not depend on a format whitelist: copy every visible,
    /// readable regular file so new camera and video formats are never missed.
    private func discoverFiles(
        in root: URL,
        stage: String,
        errors: inout [FileOperationFailure],
        progress: @escaping @Sendable (BackupCheckProgress) -> Void
    ) throws -> [FileRecord] {
        let values: URLResourceValues
        do {
            values = try root.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey])
        } catch {
            throw ScannerError.noPermission(root)
        }
        guard values.isDirectory == true else { throw ScannerError.notDirectory(root) }
        guard values.isReadable == true else { throw ScannerError.noPermission(root) }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isDirectoryKey, .isHiddenKey, .fileSizeKey, .isReadableKey,
            .contentModificationDateKey, .creationDateKey, .fileResourceIdentifierKey, .volumeUUIDStringKey
        ]
        var enumerationErrors: [FileOperationFailure] = []
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles],
            errorHandler: { url, error in
                enumerationErrors.append(.init(url: url, reason: error.localizedDescription))
                return true
            }
        ) else { throw ScannerError.cannotEnumerate(root) }

        var records: [FileRecord] = []
        var inspected = 0
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            if isIgnoredLocation(url) {
                enumerator.skipDescendants()
                continue
            }
            do {
                let value = try url.resourceValues(forKeys: keys)
                if value.isDirectory == true { continue }
                inspected += 1
                guard value.isRegularFile == true,
                      value.isHidden != true,
                      !url.lastPathComponent.hasPrefix("._") else { continue }
                guard value.isReadable == true else {
                    enumerationErrors.append(.init(url: url, reason: "The file cannot be read because access was denied."))
                    continue
                }
                records.append(.init(
                    url: url,
                    byteCount: Int64(value.fileSize ?? 0),
                    modificationTime: value.contentModificationDate?.timeIntervalSinceReferenceDate,
                    creationTime: value.creationDate?.timeIntervalSinceReferenceDate,
                    fileIdentifier: value.fileResourceIdentifier.map { String(describing: $0) } ?? "",
                    volumeIdentifier: value.volumeUUIDString ?? ""
                ))
                if inspected == 1 || inspected.isMultiple(of: 100) {
                    progress(.init(stage: stage, completedCount: inspected, totalCount: nil, currentFileName: url.lastPathComponent))
                }
            } catch {
                enumerationErrors.append(.init(url: url, reason: error.localizedDescription))
            }
        }
        errors.append(contentsOf: enumerationErrors)
        progress(.init(stage: stage, completedCount: inspected, totalCount: nil, currentFileName: root.lastPathComponent))
        return records
    }

    private func digest(
        of file: FileRecord,
        cache: [String: HashCacheEntry],
        usedCache: inout [String: HashCacheEntry],
        statistics: inout HashStatistics
    ) throws -> String {
        let key = file.url.standardizedFileURL.path
        if let cached = cache[key], cached.matches(file) {
            usedCache[key] = cached
            statistics.cacheHits += 1
            return cached.digest
        }

        let digest = try hash(of: file.url)
        statistics.bytesRead += file.byteCount
        usedCache[key] = .init(
            byteCount: file.byteCount,
            modificationTime: file.modificationTime,
            creationTime: file.creationTime,
            fileIdentifier: file.fileIdentifier,
            volumeIdentifier: file.volumeIdentifier,
            digest: digest
        )
        return digest
    }

    private func hash(of url: URL) throws -> String {
        try streamedSHA256(of: url)
    }

    private func loadHashCache() -> [String: HashCacheEntry] {
        guard let data = try? Data(contentsOf: cacheFileURL),
              let file = try? JSONDecoder().decode(HashCacheFile.self, from: data),
              file.version == 1 else { return [:] }
        return file.entries
    }

    private func saveHashCache(_ entries: [String: HashCacheEntry]) {
        guard !entries.isEmpty,
              let data = try? JSONEncoder().encode(HashCacheFile(version: 1, entries: entries)) else { return }
        do {
            try FileManager.default.createDirectory(
                at: cacheFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: cacheFileURL, options: .atomic)
        } catch {
            // A cache failure affects speed only; verification results remain valid.
        }
    }

    private func isIgnoredLocation(_ url: URL) -> Bool {
        url.pathComponents.contains {
            $0 == ".Trash" || $0 == ".Trashes"
                || $0.caseInsensitiveCompare("System Volume Information") == .orderedSame
        }
    }
}
