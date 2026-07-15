import Foundation

/// Shared pairing rules used both during scanning and immediately before cleanup.
enum PhotoPairing {
    static let rawFolderNames: Set<String> = ["raw", "cr3", "arw"]

    static func jpgSearchFolders(for cr3: URL) -> [URL] {
        let folder = cr3.deletingLastPathComponent()
        guard rawFolderNames.contains(folder.lastPathComponent.lowercased()) else {
            return [folder]
        }
        return [folder, folder.deletingLastPathComponent()]
    }

    static func isMatchingJPG(_ candidate: URL, for cr3: URL) -> Bool {
        let ext = candidate.pathExtension.lowercased()
        return (ext == "jpg" || ext == "jpeg")
            && candidate.deletingPathExtension().lastPathComponent
                == cr3.deletingPathExtension().lastPathComponent
    }

    /// A removed JPG can expose a CR3 beside it or in a conventional RAW child folder.
    static func cr3SearchFolders(forRemovedJPG jpg: URL) -> [URL] {
        let folder = jpg.deletingLastPathComponent()
        let children = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return [folder] + children.filter { url in
            rawFolderNames.contains(url.lastPathComponent.lowercased())
                && (try? url.resourceValues(forKeys: [.isDirectoryKey, .isHiddenKey]))?.isDirectory == true
        }
    }
}

struct XMPSidecar: Identifiable, Hashable, Sendable, Codable {
    let url: URL
    let byteCount: Int64

    var id: URL { url }
}

/// A Canon RAW file that had no same-name JPG/JPEG beside it when scanned.
struct OrphanedCR3: Identifiable, Hashable, Sendable, Codable {
    let url: URL
    let byteCount: Int64
    let xmpSidecars: [XMPSidecar]

    init(url: URL, byteCount: Int64, xmpSidecars: [XMPSidecar] = []) {
        self.url = url
        self.byteCount = byteCount
        self.xmpSidecars = xmpSidecars
    }

    var id: URL { url }
    var totalByteCount: Int64 { byteCount + xmpSidecars.reduce(0) { $0 + $1.byteCount } }
    var cleanupFileCount: Int { 1 + xmpSidecars.count }
}

struct ScanProgress: Sendable {
    let inspectedFileCount: Int
    let currentFolderName: String
}

struct ScanReport: Sendable, Codable {
    let orphanedFiles: [OrphanedCR3]
    let inspectedFileCount: Int
    let errors: [FileOperationFailure]
}

struct FileOperationFailure: Identifiable, Hashable, Sendable, Codable {
    let url: URL
    let reason: String

    var id: String { url.path + reason }
}

struct TrashedItem: Hashable, Sendable {
    let originalURL: URL
    let trashURL: URL
}

struct CleanupReport: Sendable {
    let requestedCount: Int
    let movedCount: Int
    let failures: [FileOperationFailure]
    let wasCancelled: Bool
    let dryRun: Bool
    let trashedItems: [TrashedItem]

    init(
        requestedCount: Int,
        movedCount: Int,
        failures: [FileOperationFailure],
        wasCancelled: Bool,
        dryRun: Bool,
        trashedItems: [TrashedItem] = []
    ) {
        self.requestedCount = requestedCount
        self.movedCount = movedCount
        self.failures = failures
        self.wasCancelled = wasCancelled
        self.dryRun = dryRun
        self.trashedItems = trashedItems
    }
}

struct RestoreReport: Sendable {
    let restoredCount: Int
    let failures: [FileOperationFailure]
}

extension Int64 {
    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}

/// Stores only the most recent folder's scan and analysis. Cached results are
/// advisory: cleanup still re-checks JPG companions immediately before Trash.
struct CachedRun: Codable, Sendable {
    static let formatVersion = 1

    let version: Int
    let folderPath: String
    var scan: ScanReport?
    var analysis: BlurAnalysisReport?
    var savedAt: Date
}

actor LastRunCache {
    private let fileURL: URL

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        if let fileURL {
            self.fileURL = fileURL
            return
        }
        let directory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.fileURL = directory
            .appendingPathComponent("CR3 Companion Cleaner", isDirectory: true)
            .appendingPathComponent("last-run.json")
    }

    func load(for folder: URL) -> CachedRun? {
        guard let data = try? Data(contentsOf: fileURL),
              let cached = try? JSONDecoder().decode(CachedRun.self, from: data),
              cached.version == CachedRun.formatVersion,
              cached.folderPath == folder.standardizedFileURL.path else { return nil }
        return cached
    }

    func save(scan: ScanReport, for folder: URL) {
        var cached = load(for: folder) ?? emptyRun(for: folder)
        cached.scan = scan
        cached.savedAt = Date()
        write(cached)
    }

    func save(analysis: BlurAnalysisReport, for folder: URL) {
        var cached = load(for: folder) ?? emptyRun(for: folder)
        cached.analysis = analysis
        cached.savedAt = Date()
        write(cached)
    }

    private func emptyRun(for folder: URL) -> CachedRun {
        CachedRun(
            version: CachedRun.formatVersion,
            folderPath: folder.standardizedFileURL.path,
            scan: nil,
            analysis: nil,
            savedAt: Date()
        )
    }

    private func write(_ cached: CachedRun) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(cached).write(to: fileURL, options: .atomic)
        } catch {
            // Cache failure must never block scanning, analysis, or cleanup.
        }
    }
}
