import AppKit
import Foundation

/// Moves files with the official macOS trash API. It never permanently deletes files.
struct CleanupService: Sendable {
    /// Moves only the explicitly selected review photos to Trash.
    func trash(_ urls: [URL], dryRun: Bool) async -> CleanupReport {
        if dryRun {
            return CleanupReport(
                requestedCount: urls.count,
                movedCount: 0,
                failures: [],
                wasCancelled: false,
                dryRun: true
            )
        }

        var failures: [FileOperationFailure] = []
        var trashedItems: [TrashedItem] = []
        for url in urls {
            if Task.isCancelled { break }
            guard FileManager.default.fileExists(atPath: url.path) else {
                failures.append(.init(url: url, reason: "The photo no longer exists."))
                continue
            }
            do {
                let trashURL = try await recycle(url)
                trashedItems.append(.init(originalURL: url, trashURL: trashURL))
            } catch {
                failures.append(.init(url: url, reason: error.localizedDescription))
            }
        }
        return CleanupReport(
            requestedCount: urls.count,
            movedCount: trashedItems.count,
            failures: failures,
            wasCancelled: Task.isCancelled,
            dryRun: false,
            trashedItems: trashedItems
        )
    }

    /// Restores the last explicitly trashed review batch without overwriting files.
    func restore(_ items: [TrashedItem]) async -> RestoreReport {
        await Task.detached(priority: .userInitiated) {
            var restored = 0
            var failures: [FileOperationFailure] = []
            for item in items.reversed() {
                guard !FileManager.default.fileExists(atPath: item.originalURL.path) else {
                    failures.append(.init(
                        url: item.originalURL,
                        reason: "A file already exists at the original location."
                    ))
                    continue
                }
                guard FileManager.default.fileExists(atPath: item.trashURL.path) else {
                    failures.append(.init(
                        url: item.originalURL,
                        reason: "The item is no longer available in Trash."
                    ))
                    continue
                }
                do {
                    try FileManager.default.moveItem(at: item.trashURL, to: item.originalURL)
                    restored += 1
                } catch {
                    failures.append(.init(url: item.originalURL, reason: error.localizedDescription))
                }
            }
            return RestoreReport(restoredCount: restored, failures: failures)
        }.value
    }

    private func recycle(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.recycle([url]) { newURLs, error in
                if let trashURL = newURLs.values.first {
                    continuation.resume(returning: trashURL)
                } else {
                    continuation.resume(throwing: error ?? NSError(
                        domain: "CR3CompanionCleaner",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "macOS did not return the item's Trash location."]
                    ))
                }
            }
        }
    }

    func clean(_ files: [OrphanedCR3], dryRun: Bool) async -> CleanupReport {
        let task = Task.detached(priority: .userInitiated) {
            if dryRun {
                return CleanupReport(
                    requestedCount: files.reduce(0) { $0 + $1.cleanupFileCount },
                    movedCount: 0,
                    failures: [],
                    wasCancelled: false,
                    dryRun: true
                )
            }

            var moved = 0
            var failures: [FileOperationFailure] = []
            var cancelled = false

            fileLoop: for file in files {
                if Task.isCancelled {
                    cancelled = true
                    break
                }

                // Re-check the pairing immediately before trashing to prevent stale scan results
                // from removing a CR3 after a matching JPG has appeared.
                do {
                    if try matchingJPGExists(for: file.url) {
                        failures.append(.init(
                            url: file.url,
                            reason: "Skipped because a matching JPG/JPEG now exists."
                        ))
                        continue
                    }
                } catch {
                    failures.append(.init(
                        url: file.url,
                        reason: "Could not safely verify companion files: \(error.localizedDescription)"
                    ))
                    continue
                }

                guard FileManager.default.fileExists(atPath: file.url.path) else {
                    failures.append(.init(url: file.url, reason: "The CR3 no longer exists."))
                    continue
                }

                do {
                    var resultingURL: NSURL?
                    try FileManager.default.trashItem(at: file.url, resultingItemURL: &resultingURL)
                    moved += 1
                } catch {
                    failures.append(.init(url: file.url, reason: error.localizedDescription))
                    // Keep the XMP when its RAW file could not be moved.
                    continue
                }

                for sidecar in file.xmpSidecars {
                    if Task.isCancelled {
                        cancelled = true
                        break fileLoop
                    }
                    guard FileManager.default.fileExists(atPath: sidecar.url.path) else { continue }
                    do {
                        var resultingURL: NSURL?
                        try FileManager.default.trashItem(at: sidecar.url, resultingItemURL: &resultingURL)
                        moved += 1
                    } catch {
                        failures.append(.init(url: sidecar.url, reason: error.localizedDescription))
                    }
                }
            }

            return CleanupReport(
                requestedCount: files.reduce(0) { $0 + $1.cleanupFileCount },
                movedCount: moved,
                failures: failures,
                wasCancelled: cancelled,
                dryRun: false
            )
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func matchingJPGExists(for cr3: URL) throws -> Bool {
        let candidates = try PhotoPairing.jpgSearchFolders(for: cr3).flatMap { folder in
            try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
                options: [.skipsHiddenFiles]
            )
        }

        return candidates.contains { PhotoPairing.isMatchingJPG($0, for: cr3) }
    }
}
