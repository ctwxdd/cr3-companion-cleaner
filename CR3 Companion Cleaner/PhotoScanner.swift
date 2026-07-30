import Foundation

enum ScannerError: LocalizedError {
    case notDirectory(URL)
    case noPermission(URL)
    case cannotEnumerate(URL)

    var errorDescription: String? {
        switch self {
        case .notDirectory(let url):
            return "The selected item is not a folder: \(url.path)"
        case .noPermission(let url):
            return "Photo Sift does not have permission to read this folder: \(url.path)"
        case .cannotEnumerate(let url):
            return "The folder could not be scanned: \(url.path)"
        }
    }
}

/// Performs all filesystem discovery off the main actor.
struct PhotoScanner: Sendable {
    typealias ReadabilityChecker = @Sendable (String) -> Bool

    private let readabilityChecker: ReadabilityChecker

    init(readabilityChecker: @escaping ReadabilityChecker = FileManager.default.isReadableFile(atPath:)) {
        self.readabilityChecker = readabilityChecker
    }

    func scan(
        folder root: URL,
        progress: @escaping @Sendable (ScanProgress) -> Void
    ) async throws -> ScanReport {
        let task = Task.detached(priority: .userInitiated) {
            try scanSynchronously(folder: root, progress: progress)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Rechecks only folders affected by JPGs that were just moved, avoiding a full rescan.
    func newlyOrphanedCR3s(afterRemovingJPGs jpgs: [URL]) async -> [OrphanedCR3] {
        await Task.detached(priority: .utility) {
            let manager = FileManager.default
            let stems = Set(jpgs.map { $0.deletingPathExtension().lastPathComponent })
            let folders = Set(jpgs.flatMap(PhotoPairing.cr3SearchFolders(forRemovedJPG:)))
            var results: [OrphanedCR3] = []

            for folder in folders {
                guard let files = try? manager.contentsOfDirectory(
                    at: folder,
                    includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey, .fileSizeKey, .isReadableKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for cr3 in files where cr3.pathExtension.caseInsensitiveCompare("cr3") == .orderedSame
                    && stems.contains(cr3.deletingPathExtension().lastPathComponent) {
                    let companions = PhotoPairing.jpgSearchFolders(for: cr3).flatMap {
                        (try? manager.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                    }
                    guard !companions.contains(where: { PhotoPairing.isMatchingJPG($0, for: cr3) }),
                          let values = try? cr3.resourceValues(forKeys: [.fileSizeKey, .isReadableKey]),
                          values.isReadable == true else { continue }
                    let stem = cr3.deletingPathExtension().lastPathComponent
                    let sidecars = files.compactMap { file -> XMPSidecar? in
                        guard file.pathExtension.caseInsensitiveCompare("xmp") == .orderedSame,
                              file.deletingPathExtension().lastPathComponent == stem else { return nil }
                        let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize
                        return .init(url: file, byteCount: Int64(size ?? 0))
                    }
                    results.append(.init(url: cr3, byteCount: Int64(values.fileSize ?? 0), xmpSidecars: sidecars))
                }
            }
            return Array(Dictionary(results.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first }).values)
                .sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
        }.value
    }

    /// Lightweight browse index: discovers JPG/JPEG files without running AI analysis.
    func discoverJPGs(
        folder root: URL,
        progress: @escaping @Sendable (ScanProgress) -> Void
    ) async throws -> [URL] {
        try await Task.detached(priority: .userInitiated) {
            try discoverJPGsSynchronously(folder: root, progress: progress)
        }.value
    }

    private func discoverJPGsSynchronously(
        folder root: URL,
        progress: @escaping @Sendable (ScanProgress) -> Void
    ) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        ) else { throw ScannerError.cannotEnumerate(root) }
        var urls: [URL] = []
        var inspected = 0
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            if url.pathComponents.contains(where: { $0 == ".Trash" || $0 == ".Trashes" }) {
                enumerator.skipDescendants()
                continue
            }
            inspected += 1
            let ext = url.pathExtension.lowercased()
            guard ext == "jpg" || ext == "jpeg",
                  !url.lastPathComponent.hasPrefix("._"),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isHiddenKey]),
                  values.isRegularFile == true, values.isHidden != true else { continue }
            urls.append(url)
            if urls.count == 1 || urls.count.isMultiple(of: 50) {
                progress(.init(
                    inspectedFileCount: inspected,
                    currentFolderName: url.deletingLastPathComponent().lastPathComponent
                ))
            }
        }
        progress(.init(inspectedFileCount: inspected, currentFolderName: root.lastPathComponent))
        return urls.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func scanSynchronously(
        folder root: URL,
        progress: @escaping @Sendable (ScanProgress) -> Void
    ) throws -> ScanReport {
        let rootValues: URLResourceValues
        do {
            rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey])
        } catch {
            throw ScannerError.noPermission(root)
        }
        guard rootValues.isDirectory == true else { throw ScannerError.notDirectory(root) }
        guard rootValues.isReadable == true, readabilityChecker(root.path) else {
            throw ScannerError.noPermission(root)
        }

        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isDirectoryKey, .isHiddenKey, .fileSizeKey, .isReadableKey
        ]
        var enumerationErrors: [FileOperationFailure] = []
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: { url, error in
                enumerationErrors.append(.init(url: url, reason: error.localizedDescription))
                return true
            }
        ) else {
            throw ScannerError.cannotEnumerate(root)
        }

        var filesByFolder: [URL: [URL]] = [:]
        var inspected = 0

        for case let url as URL in enumerator {
            try Task.checkCancellation()

            if isTrashLocation(url) {
                enumerator.skipDescendants()
                continue
            }

            do {
                let values = try url.resourceValues(forKeys: Set(keys))
                if values.isDirectory == true { continue }
                guard values.isRegularFile == true, values.isHidden != true else { continue }
                guard !url.lastPathComponent.hasPrefix("._") else { continue }

                inspected += 1
                filesByFolder[url.deletingLastPathComponent(), default: []].append(url)
                if inspected == 1 || inspected.isMultiple(of: 25) {
                    progress(.init(
                        inspectedFileCount: inspected,
                        currentFolderName: url.deletingLastPathComponent().lastPathComponent
                    ))
                }
            } catch {
                enumerationErrors.append(.init(url: url, reason: error.localizedDescription))
            }
        }

        var orphans: [OrphanedCR3] = []
        for (_, files) in filesByFolder {
            try Task.checkCancellation()

            for cr3 in files where cr3.pathExtension.caseInsensitiveCompare("cr3") == .orderedSame {
                let stem = cr3.deletingPathExtension().lastPathComponent
                let jpgCandidates = PhotoPairing.jpgSearchFolders(for: cr3)
                    .flatMap { filesByFolder[$0] ?? [] }
                guard !jpgCandidates.contains(where: { PhotoPairing.isMatchingJPG($0, for: cr3) }) else {
                    continue
                }

                let xmpSidecars = files.compactMap { candidate -> XMPSidecar? in
                    guard candidate.pathExtension.caseInsensitiveCompare("xmp") == .orderedSame,
                          candidate.deletingPathExtension().lastPathComponent == stem else { return nil }
                    let size = try? candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize
                    return XMPSidecar(url: candidate, byteCount: Int64(size ?? 0))
                }

                do {
                    let values = try cr3.resourceValues(forKeys: [.fileSizeKey, .isReadableKey])
                    guard values.isReadable == true, readabilityChecker(cr3.path) else {
                        enumerationErrors.append(.init(
                            url: cr3,
                            reason: "The file cannot be read because access was denied."
                        ))
                        continue
                    }
                    orphans.append(.init(
                        url: cr3,
                        byteCount: Int64(values.fileSize ?? 0),
                        xmpSidecars: xmpSidecars.sorted {
                            $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
                        }
                    ))
                } catch {
                    enumerationErrors.append(.init(url: cr3, reason: error.localizedDescription))
                }
            }
        }

        progress(.init(inspectedFileCount: inspected, currentFolderName: root.lastPathComponent))
        return ScanReport(
            orphanedFiles: orphans.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending },
            inspectedFileCount: inspected,
            errors: enumerationErrors
        )
    }

    private func isTrashLocation(_ url: URL) -> Bool {
        url.pathComponents.contains { component in
            component == ".Trash" || component == ".Trashes"
        }
    }
}
