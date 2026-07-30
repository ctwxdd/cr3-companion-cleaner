import AppKit
import CryptoKit
import Foundation

@MainActor
final class CleanerViewModel: ObservableObject {
    enum Phase: Equatable {
        case ready
        case scanning
        case scanned
        case cleaning
        case finished
    }

    @Published private(set) var selectedFolder: URL?
    @Published private(set) var orphanedFiles: [OrphanedCR3] = []
    @Published private(set) var scanErrors: [FileOperationFailure] = []
    @Published private(set) var inspectedFileCount = 0
    @Published private(set) var currentFolderName = ""
    @Published private(set) var phase: Phase = .ready
    @Published private(set) var cleanupReport: CleanupReport?
    @Published private(set) var blurCandidates: [BlurCandidate] = []
    @Published private(set) var burstPhotos: [BlurCandidate] = []
    @Published private(set) var burstGroupCount = 0
    @Published private(set) var blurErrors: [FileOperationFailure] = []
    @Published private(set) var blurAnalyzedCount = 0
    @Published private(set) var blurCurrentFileName = ""
    @Published private(set) var blurWorkerCount = AnalysisPerformancePolicy.current.workerCount
    @Published private(set) var isAnalyzingBlur = false
    @Published private(set) var blurAnalysisCompleted = false
    @Published private(set) var browsePhotoURLs: [URL] = []
    @Published private(set) var isIndexingBrowse = false
    @Published private(set) var browseCompleted = false
    @Published private(set) var browseInspectedCount = 0
    @Published private(set) var cameraCardFolder: URL?
    @Published private(set) var backupDestinationFolder: URL?
    @Published private(set) var backupCheckItems: [BackupCheckItem] = []
    @Published private(set) var backupCheckErrors: [FileOperationFailure] = []
    @Published private(set) var backupCheckCardFileCount = 0
    @Published private(set) var backupCheckLibraryFileCount = 0
    @Published private(set) var backupCheckCachedHashCount = 0
    @Published private(set) var backupCheckHashedByteCount: Int64 = 0
    @Published private(set) var backupCheckStage = ""
    @Published private(set) var backupCheckCompletedCount = 0
    @Published private(set) var backupCheckTotalCount: Int?
    @Published private(set) var backupCheckCurrentFileName = ""
    @Published private(set) var isCheckingBackup = false
    @Published private(set) var backupCheckCompleted = false
    @Published private(set) var backupSpacePlan: BackupSpacePlan?
    @Published private(set) var isBackingUpMissing = false
    @Published private(set) var backupCopyStage = ""
    @Published private(set) var backupCopyCompletedCount = 0
    @Published private(set) var backupCopyByteCount: Int64 = 0
    @Published private(set) var backupCopyCurrentFileName = ""
    @Published private(set) var backupCopyReport: BackupCopyReport?
    @Published private(set) var isTrashingReviewPhotos = false
    @Published private(set) var reviewTrashReport: CleanupReport?
    @Published private(set) var isRestoringReviewPhotos = false
    @Published private(set) var restoreReport: RestoreReport?
    @Published private(set) var reviewUndoVersion = 0
    @Published private(set) var webRemoteURL: String?
    @Published private(set) var webRemotePIN: String?
    @Published private(set) var webRemoteError: String?
    @Published private(set) var cachedRunDate: Date?
    @Published var dryRun = true
    @Published var errorMessage: String?
    @Published var showsConfirmation = false

    private let scanner = PhotoScanner()
    private let cleanupService = CleanupService()
    private let resultCache = LastRunCache()
    private let backupCheckService = BackupCheckService()
    private let backupCopyService = BackupCopyService()
    private var operationTask: Task<Void, Never>?
    private var blurTask: Task<Void, Never>?
    private var browseTask: Task<Void, Never>?
    private var cacheTask: Task<Void, Never>?
    private var backupCheckTask: Task<Void, Never>?
    private var backupCopyTask: Task<Void, Never>?
    private var isUsingSecurityScope = false
    private var isUsingCameraCardSecurityScope = false
    private var isUsingBackupDestinationSecurityScope = false
    private var authorizedRootFolder: URL?
    private var undoTrashItems: [TrashedItem] = []
    private var undoReviewCandidates: [BlurCandidate] = []
    private var undoBrowseURLs: [URL] = []
    private lazy var webRemoteServer = WebRemoteServer(
        stateProvider: { [weak self] in self?.makeWebRemoteState() ?? .empty },
        photoURLProvider: { [weak self] id in self?.webPhotoURL(for: id) },
        rawURLProvider: { [weak self] id in self?.webRawFile(for: id)?.url },
        scanRawAction: { [weak self] in self?.scan() },
        browseAction: { [weak self] in self?.browsePhotos() },
        analyzeAction: { [weak self] in self?.analyzeBlur() },
        cancelAction: { [weak self] in self?.cancelOperation() },
        trashAction: { [weak self] ids in
            guard let self else { return }
            self.trashReviewPhotos(self.webPhotoURLs(for: ids))
        },
        trashRawAction: { [weak self] ids in self?.trashRemoteRaw(ids) },
        undoAction: { [weak self] in self?.undoLastReviewTrash() },
        dryRunAction: { [weak self] value in self?.dryRun = value },
        selectFolderAction: { [weak self] path in self?.selectRemoteFolder(path) },
        backupCheckAction: { [weak self] in self?.checkCameraCardBackup() },
        backupAction: { [weak self] in self?.backUpMissingPhotos() },
        statusHandler: { [weak self] url, pin, error in
            self?.webRemoteURL = url
            self?.webRemotePIN = pin
            self?.webRemoteError = error
        }
    )

    var totalByteCount: Int64 { orphanedFiles.reduce(0) { $0 + $1.totalByteCount } }
    var xmpSidecarCount: Int { orphanedFiles.reduce(0) { $0 + $1.xmpSidecars.count } }
    var cleanupFileCount: Int { orphanedFiles.count + xmpSidecarCount }
    var isBusy: Bool { phase == .scanning || phase == .cleaning || isAnalyzingBlur || isIndexingBrowse || isTrashingReviewPhotos || isRestoringReviewPhotos || isCheckingBackup || isBackingUpMissing }
    var canUndoReviewTrash: Bool { !undoTrashItems.isEmpty && !isRestoringReviewPhotos }
    var isWebRemoteRunning: Bool { webRemoteURL != nil }
    var backedUpCount: Int { backupCheckItems.lazy.filter { $0.status == .backedUp }.count }
    var notBackedUpCount: Int { backupCheckItems.count - backedUpCount }
    /// An explicitly chosen destination wins; the photo folder remains a convenient fallback.
    var effectiveBackupFolder: URL? { backupDestinationFolder ?? selectedFolder }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a photo folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectFolder(url)
    }

    /// The source picker is intentionally read-only and points at the mounted camera card.
    func chooseCameraCard() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose camera memory card"
        panel.prompt = "Use Memory Card"
        panel.directoryURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let folder = url.standardizedFileURL
        if isUsingCameraCardSecurityScope { cameraCardFolder?.stopAccessingSecurityScopedResource() }
        isUsingCameraCardSecurityScope = folder.startAccessingSecurityScopedResource()
        cameraCardFolder = folder
        resetBackupCheckResults()
    }

    func chooseBackupDestination() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose backup destination"
        panel.prompt = "Use as Backup Destination"
        panel.directoryURL = effectiveBackupFolder
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let folder = url.standardizedFileURL
        guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            errorMessage = "The backup destination must be an accessible folder."
            return
        }
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            errorMessage = "The backup destination is not writable. Check its permissions and available storage."
            return
        }

        stopBackupDestinationSecurityScope()
        isUsingBackupDestinationSecurityScope = folder.startAccessingSecurityScopedResource()
        backupDestinationFolder = folder
        resetBackupCheckResults()
        errorMessage = nil
    }

    func usePhotoFolderAsBackupDestination() {
        guard !isBusy else { return }
        stopBackupDestinationSecurityScope()
        resetBackupCheckResults()
    }

    func checkCameraCardBackup() {
        guard let cameraCardFolder, let backupFolder = effectiveBackupFolder, !isBusy else { return }
        let cardPath = cameraCardFolder.standardizedFileURL.path
        let backupPath = backupFolder.standardizedFileURL.path
        let cardPrefix = cardPath.hasSuffix("/") ? cardPath : cardPath + "/"
        let backupPrefix = backupPath.hasSuffix("/") ? backupPath : backupPath + "/"
        guard cardPath != backupPath,
              !cardPath.hasPrefix(backupPrefix),
              !backupPath.hasPrefix(cardPrefix) else {
            errorMessage = "The camera card and backup folder must be separate folders."
            return
        }

        resetBackupCheckResults()
        isCheckingBackup = true
        backupCheckTask = Task {
            do {
                let report = try await withIdleSleepDisabled(reason: "Checking camera card backups") {
                    try await backupCheckService.check(
                        cameraCard: cameraCardFolder,
                        backupFolder: backupFolder
                    ) { [weak self] update in
                        Task { @MainActor in
                            self?.backupCheckStage = update.stage
                            self?.backupCheckCompletedCount = update.completedCount
                            self?.backupCheckTotalCount = update.totalCount
                            self?.backupCheckCurrentFileName = update.currentFileName
                        }
                    }
                }
                guard !Task.isCancelled else { isCheckingBackup = false; return }
                backupCheckItems = report.items
                backupCheckErrors = report.errors
                backupCheckCardFileCount = report.cardFileCount
                backupCheckLibraryFileCount = report.backupFileCount
                backupCheckCachedHashCount = report.cachedHashCount
                backupCheckHashedByteCount = report.hashedByteCount
                backupCheckCompleted = true
                isCheckingBackup = false
                refreshBackupSpacePlan()
            } catch is CancellationError {
                isCheckingBackup = false
            } catch {
                errorMessage = error.localizedDescription
                isCheckingBackup = false
            }
        }
    }

    func cancelBackupCheck() {
        backupCheckTask?.cancel()
    }

    func refreshBackupSpacePlan(showError: Bool = false) {
        guard let cameraCardFolder, let backupFolder = effectiveBackupFolder, backupCheckCompleted else {
            backupSpacePlan = nil
            return
        }
        do {
            backupSpacePlan = try backupCopyService.spacePlan(
                cameraCard: cameraCardFolder,
                backupFolder: backupFolder,
                items: backupCheckItems
            )
        } catch {
            backupSpacePlan = nil
            if showError { errorMessage = "Available capacity could not be read: \(error.localizedDescription)" }
        }
    }

    func backUpMissingPhotos() {
        guard let cameraCardFolder, let backupFolder = effectiveBackupFolder, !isBusy else { return }
        refreshBackupSpacePlan(showError: true)
        guard let plan = backupSpacePlan, plan.fileCount > 0 else { return }
        guard plan.hasEnoughSpace else {
            errorMessage = BackupCopyError.insufficientSpace(
                required: plan.requiredByteCount,
                available: plan.availableByteCount
            ).localizedDescription
            return
        }

        isBackingUpMissing = true
        backupCopyReport = nil
        backupCopyStage = "Preparing"
        backupCopyCompletedCount = 0
        backupCopyByteCount = 0
        backupCopyCurrentFileName = ""
        backupCopyTask = Task {
            do {
                let report = try await withIdleSleepDisabled(reason: "Backing up camera card") {
                    try await backupCopyService.copyMissing(
                        items: backupCheckItems,
                        cameraCard: cameraCardFolder,
                        backupFolder: backupFolder
                    ) { [weak self] update in
                        Task { @MainActor in
                            self?.backupCopyStage = update.stage
                            self?.backupCopyCompletedCount = update.completedFileCount
                            self?.backupCopyByteCount = update.copiedByteCount
                            self?.backupCopyCurrentFileName = update.currentFileName
                        }
                    }
                }
                guard self.effectiveBackupFolder == backupFolder,
                      self.cameraCardFolder == cameraCardFolder else { return }
                let destinations = Dictionary(
                    uniqueKeysWithValues: report.copiedItems.map { ($0.sourceURL, $0.destinationURL) }
                )
                backupCheckItems = backupCheckItems.map { item in
                    guard let destination = destinations[item.sourceURL] else { return item }
                    return .init(sourceURL: item.sourceURL, backupURL: destination, byteCount: item.byteCount)
                }
                backupCheckLibraryFileCount += report.copiedItems.count
                backupCopyReport = report
                isBackingUpMissing = false
                refreshBackupSpacePlan()
            } catch is CancellationError {
                isBackingUpMissing = false
            } catch {
                errorMessage = error.localizedDescription
                isBackingUpMissing = false
                refreshBackupSpacePlan()
            }
        }
    }

    func cancelBackupCopy() {
        backupCopyTask?.cancel()
    }

    func revealBackupCheckSource(_ item: BackupCheckItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.sourceURL])
    }

    func revealBackupMatch(_ item: BackupCheckItem) {
        guard let url = item.backupURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func chooseSubfolder() {
        guard let root = authorizedRootFolder, let selectedFolder, !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a subfolder"
        panel.prompt = "Use Subfolder"
        panel.directoryURL = selectedFolder
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let candidate = url.standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path == root.path || candidate.path.hasPrefix(prefix) else {
            errorMessage = "Choose a subfolder inside the authorized root: \(root.path)"
            return
        }
        self.selectedFolder = candidate
        resetForFolderSelection()
        restoreCachedRun(for: candidate)
    }

    var canGoToParentFolder: Bool {
        guard let root = authorizedRootFolder, let selectedFolder else { return false }
        return selectedFolder.path != root.path
    }

    func goToParentFolder() {
        guard canGoToParentFolder, let root = authorizedRootFolder, let selectedFolder, !isBusy else { return }
        let parent = selectedFolder.deletingLastPathComponent().standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard parent.path == root.path || parent.path.hasPrefix(prefix) else { return }
        self.selectedFolder = parent
        resetForFolderSelection()
        restoreCachedRun(for: parent)
    }

    func startWebRemote() {
        guard selectedFolder != nil else {
            webRemoteError = "Choose a photo folder on the Mac before starting Web Remote."
            return
        }
        webRemoteError = nil
        do {
            try webRemoteServer.start()
        } catch {
            webRemoteError = error.localizedDescription
        }
    }

    func stopWebRemote() {
        webRemoteServer.stop()
    }

    func selectFolder(_ url: URL) {
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                errorMessage = "Please choose or drop a folder, not a file."
                return
            }
        } catch {
            errorMessage = "The selected folder cannot be accessed: \(error.localizedDescription)"
            return
        }

        let folder = url.standardizedFileURL
        if let selectedFolder, selectedFolder != folder,
           phase != .ready || blurAnalysisCompleted || browseCompleted || !blurCandidates.isEmpty || !burstPhotos.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Switch Photo Folder?"
            alert.informativeText = "Current scan and photo review results will be cleared. Files already moved to Trash are not affected."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Switch Folder")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        stopSecurityScope()
        isUsingSecurityScope = folder.startAccessingSecurityScopedResource()
        authorizedRootFolder = folder
        selectedFolder = folder
        resetForFolderSelection()
        restoreCachedRun(for: folder)
    }

    private func resetForFolderSelection() {
        operationTask?.cancel()
        browseTask?.cancel()
        orphanedFiles = []
        scanErrors = []
        cleanupReport = nil
        inspectedFileCount = 0
        cachedRunDate = nil
        browsePhotoURLs = []
        isIndexingBrowse = false
        browseCompleted = false
        browseInspectedCount = 0
        undoBrowseURLs = []
        resetBackupCheckResults()
        resetBlurAnalysis()
        phase = .ready
        errorMessage = nil
    }

    func scan() {
        guard let selectedFolder, phase != .scanning, !isAnalyzingBlur else { return }
        operationTask?.cancel()
        phase = .scanning
        orphanedFiles = []
        scanErrors = []
        cleanupReport = nil
        inspectedFileCount = 0
        errorMessage = nil

        operationTask = Task {
            do {
                let report = try await withIdleSleepDisabled(reason: "Scanning RAW photos") {
                    try await scanner.scan(folder: selectedFolder) { [weak self] update in
                        Task { @MainActor in
                            self?.inspectedFileCount = update.inspectedFileCount
                            self?.currentFolderName = update.currentFolderName
                        }
                    }
                }
                guard !Task.isCancelled else {
                    phase = .ready
                    restoreCachedRun(for: selectedFolder)
                    return
                }
                orphanedFiles = report.orphanedFiles
                scanErrors = report.errors
                inspectedFileCount = report.inspectedFileCount
                phase = .scanned
                await resultCache.save(scan: report, for: selectedFolder)
            } catch is CancellationError {
                phase = .ready
                restoreCachedRun(for: selectedFolder)
            } catch {
                errorMessage = error.localizedDescription
                phase = .ready
            }
        }
    }

    func requestCleanup() {
        guard !orphanedFiles.isEmpty else { return }
        showsConfirmation = true
    }

    func analyzeBlur() {
        guard let selectedFolder, !isAnalyzingBlur, phase != .scanning else { return }
        blurTask?.cancel()
        blurCandidates = []
        burstPhotos = []
        burstGroupCount = 0
        blurErrors = []
        blurAnalyzedCount = 0
        blurCurrentFileName = ""
        blurAnalysisCompleted = false
        reviewTrashReport = nil
        let performance = AnalysisPerformancePolicy.current
        blurWorkerCount = performance.workerCount
        isAnalyzingBlur = true
        errorMessage = nil

        blurTask = Task {
            do {
                let detector = try await Task.detached(priority: .userInitiated) {
                    try CoreMLBlurDetector()
                }.value
                let report = try await withIdleSleepDisabled(reason: "Analyzing photo quality") {
                    try await BlurAnalysisService(detector: detector).analyze(
                        folder: selectedFolder,
                        workerCount: performance.workerCount
                    ) { [weak self] count, fileName in
                        Task { @MainActor in
                            self?.blurAnalyzedCount = count
                            self?.blurCurrentFileName = fileName
                        }
                    }
                }
                guard !Task.isCancelled else {
                    isAnalyzingBlur = false
                    restoreCachedRun(for: selectedFolder)
                    return
                }
                blurCandidates = report.candidates
                burstPhotos = report.burstPhotos
                burstGroupCount = report.burstGroupCount
                blurErrors = report.errors
                blurAnalyzedCount = report.analyzedCount
                blurAnalysisCompleted = true
                isAnalyzingBlur = false
                await resultCache.save(analysis: report, for: selectedFolder)
            } catch is CancellationError {
                isAnalyzingBlur = false
                restoreCachedRun(for: selectedFolder)
            } catch {
                errorMessage = error.localizedDescription
                isAnalyzingBlur = false
            }
        }
    }

    func cancelBlurAnalysis() {
        blurTask?.cancel()
    }

    func browsePhotos() {
        guard let selectedFolder, !isBusy else { return }
        browseTask?.cancel()
        browsePhotoURLs = []
        browseCompleted = false
        browseInspectedCount = 0
        isIndexingBrowse = true
        errorMessage = nil
        browseTask = Task {
            do {
                let urls = try await withIdleSleepDisabled(reason: "Indexing photos") {
                    try await scanner.discoverJPGs(folder: selectedFolder) { [weak self] update in
                        Task { @MainActor in self?.browseInspectedCount = update.inspectedFileCount }
                    }
                }
                guard !Task.isCancelled else { isIndexingBrowse = false; return }
                browsePhotoURLs = urls
                browseCompleted = true
                isIndexingBrowse = false
            } catch is CancellationError {
                isIndexingBrowse = false
            } catch {
                errorMessage = error.localizedDescription
                isIndexingBrowse = false
            }
        }
    }

    func trashReviewPhotos(_ urls: [URL]) {
        guard !urls.isEmpty, !isTrashingReviewPhotos else { return }
        let candidatesByURL = Dictionary(
            (blurCandidates + burstPhotos).map { ($0.url, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let candidates = urls.compactMap { candidatesByURL[$0] }
        isTrashingReviewPhotos = true
        reviewTrashReport = nil
        restoreReport = nil

        blurTask = Task {
            let report = await withIdleSleepDisabled(reason: "Moving photos to Trash") {
                await cleanupService.trash(urls, dryRun: dryRun)
            }
            reviewTrashReport = report
            if !report.dryRun {
                let remaining = Set(urls.filter { FileManager.default.fileExists(atPath: $0.path) })
                let movedURLs = Set(report.trashedItems.map(\.originalURL))
                if !movedURLs.isEmpty {
                    undoTrashItems = report.trashedItems
                    undoReviewCandidates = candidates.filter { movedURLs.contains($0.url) }
                    undoBrowseURLs = browsePhotoURLs.filter { movedURLs.contains($0) }
                    reviewUndoVersion += 1
                }
                // Update the visible library as soon as macOS confirms the
                // Trash move; RAW companion reconciliation can finish after.
                blurCandidates.removeAll { !remaining.contains($0.url) && urls.contains($0.url) }
                burstPhotos.removeAll { !remaining.contains($0.url) && urls.contains($0.url) }
                browsePhotoURLs.removeAll { !remaining.contains($0) && urls.contains($0) }
                if !movedURLs.isEmpty {
                    let newOrphans = await scanner.newlyOrphanedCR3s(afterRemovingJPGs: Array(movedURLs))
                    for orphan in newOrphans where !orphanedFiles.contains(where: { $0.url == orphan.url }) {
                        orphanedFiles.append(orphan)
                    }
                    orphanedFiles.sort { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
                    if !newOrphans.isEmpty, phase == .ready { phase = .scanned }
                }
                await cacheCurrentAnalysis()
                if let selectedFolder, !report.trashedItems.isEmpty {
                    await cacheCurrentScan(for: selectedFolder)
                }
            }
            isTrashingReviewPhotos = false
        }
    }

    func undoLastReviewTrash() {
        guard canUndoReviewTrash else { return }
        let items = undoTrashItems
        let candidates = undoReviewCandidates
        let browseURLs = undoBrowseURLs
        isRestoringReviewPhotos = true
        restoreReport = nil

        blurTask = Task {
            let report = await cleanupService.restore(items)
            let failedURLs = Set(report.failures.map(\.url))
            let restoredCandidates = candidates.filter { !failedURLs.contains($0.url) }
            let restoredBrowseURLs = browseURLs.filter { !failedURLs.contains($0) }
            for candidate in restoredCandidates {
                if candidate.needsReview, !blurCandidates.contains(where: { $0.url == candidate.url }) {
                    blurCandidates.append(candidate)
                }
                if candidate.burstGroupID != nil, !burstPhotos.contains(where: { $0.url == candidate.url }) {
                    burstPhotos.append(candidate)
                }
            }
            for url in restoredBrowseURLs where !browsePhotoURLs.contains(url) {
                browsePhotoURLs.append(url)
            }
            browsePhotoURLs.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            let restoredJPGs = Set(restoredCandidates.map(\.url) + restoredBrowseURLs)
            orphanedFiles.removeAll { orphan in
                restoredJPGs.contains { jpg in
                    PhotoPairing.jpgSearchFolders(for: orphan.url).contains(jpg.deletingLastPathComponent())
                        && PhotoPairing.isMatchingJPG(jpg, for: orphan.url)
                }
            }
            blurCandidates.sort { $0.prediction.blurredProbability > $1.prediction.blurredProbability }
            burstPhotos.sort {
                ($0.burstGroupID ?? 0, $0.captureDate) < ($1.burstGroupID ?? 0, $1.captureDate)
            }
            undoTrashItems = items.filter { failedURLs.contains($0.originalURL) }
            undoReviewCandidates = candidates.filter { failedURLs.contains($0.url) }
            undoBrowseURLs = browseURLs.filter { failedURLs.contains($0) }
            restoreReport = report
            if !report.failures.isEmpty { reviewUndoVersion += 1 }
            await cacheCurrentAnalysis()
            if let selectedFolder { await cacheCurrentScan(for: selectedFolder) }
            isRestoringReviewPhotos = false
        }
    }

    func confirmCleanup() {
        showsConfirmation = false
        cleanRawFiles(orphanedFiles)
    }

    private func trashRemoteRaw(_ ids: [String]) {
        let wanted = Set(ids)
        cleanRawFiles(orphanedFiles.filter { wanted.contains(webPhotoID(for: $0.url)) })
    }

    private func cleanRawFiles(_ files: [OrphanedCR3]) {
        guard let selectedFolder, !files.isEmpty, !isBusy else { return }
        phase = .cleaning

        operationTask = Task {
            let report = await withIdleSleepDisabled(reason: "Cleaning RAW photos") {
                await cleanupService.clean(files, dryRun: dryRun)
            }
            cleanupReport = report
            if !report.dryRun {
                let requested = Set(files.map(\.url))
                // Unselected RAWs and any requested file still on disk remain visible.
                orphanedFiles.removeAll {
                    requested.contains($0.url) && !FileManager.default.fileExists(atPath: $0.url.path)
                }
                await resultCache.save(
                    scan: .init(
                        orphanedFiles: orphanedFiles,
                        inspectedFileCount: inspectedFileCount,
                        errors: scanErrors
                    ),
                    for: selectedFolder
                )
            }
            phase = .finished
        }
    }

    func cancelOperation() {
        operationTask?.cancel()
        blurTask?.cancel()
        browseTask?.cancel()
        backupCheckTask?.cancel()
        backupCopyTask?.cancel()
    }

    func reveal(_ file: OrphanedCR3) {
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }

    func reveal(_ candidate: BlurCandidate) {
        NSWorkspace.shared.activateFileViewerSelecting([candidate.url])
    }

    func revealAll() {
        NSWorkspace.shared.activateFileViewerSelecting(
            orphanedFiles.flatMap { [$0.url] + $0.xmpSidecars.map(\.url) }
        )
    }

    private func makeWebRemoteState() -> WebRemoteState {
        let photos = uniqueWebCandidates().map { candidate in
            var issues = candidate.faceIssues.map(\.rawValue) + candidate.qualityIssues.map(\.rawValue)
            var flags: [String] = []
            if candidate.prediction.label != .sharp {
                flags.append("blur")
                issues.insert(candidate.prediction.label == .blurred ? "Likely blurred" : "Blur uncertain", at: 0)
            }
            if candidate.faceIssues.contains(.possibleBlink) { flags.append("blink") }
            if candidate.faceIssues.contains(.lowFaceQuality) { flags.append("faceQuality") }
            if candidate.qualityIssues.contains(.underexposed) { flags.append("underexposed") }
            if candidate.qualityIssues.contains(.overexposed) { flags.append("overexposed") }
            if candidate.qualityIssues.contains(.lowResolution) { flags.append("lowResolution") }
            if candidate.qualityIssues.contains(.exactDuplicate) { flags.append("duplicate") }
            return WebRemotePhoto(
                id: webPhotoID(for: candidate.url),
                name: candidate.url.lastPathComponent,
                folder: candidate.url.deletingLastPathComponent().lastPathComponent,
                blurProbability: candidate.prediction.blurredProbability,
                issues: issues,
                flags: flags,
                needsReview: candidate.needsReview,
                burstGroup: candidate.burstGroupID,
                burstRank: candidate.burstRank,
                duplicateGroup: candidate.duplicateGroupID
            )
        }
        let remoteBackupFailures = (backupCopyReport?.failures ?? backupCheckErrors).map {
            "\($0.url.lastPathComponent): \($0.reason)"
        }
        let remoteBackup = WebRemoteBackupState(
            cameraCardPath: cameraCardFolder?.path,
            destinationPath: effectiveBackupFolder?.path,
            checking: isCheckingBackup,
            checkCompleted: backupCheckCompleted,
            copying: isBackingUpMissing,
            stage: isBackingUpMissing ? backupCopyStage : backupCheckStage,
            completedCount: isBackingUpMissing ? backupCopyCompletedCount : backupCheckCompletedCount,
            totalCount: isBackingUpMissing ? backupSpacePlan?.fileCount : backupCheckTotalCount,
            copiedBytes: backupCopyByteCount,
            backedUpCount: backedUpCount,
            missingCount: notBackedUpCount,
            requiredBytes: backupSpacePlan?.requiredByteCount ?? 0,
            availableBytes: backupSpacePlan?.availableByteCount ?? 0,
            hasEnoughSpace: backupSpacePlan?.hasEnoughSpace ?? false,
            verifiedCount: backupCopyReport?.copiedItems.count ?? 0,
            failureMessages: remoteBackupFailures
        )
        return WebRemoteState(
            folderName: selectedFolder?.lastPathComponent,
            dryRun: dryRun,
            analyzing: isAnalyzingBlur,
            analysisCompleted: blurAnalysisCompleted,
            analyzedCount: blurAnalyzedCount,
            currentFile: blurCurrentFileName,
            canUndo: canUndoReviewTrash,
            photos: photos,
            browsing: isIndexingBrowse,
            browseCompleted: browseCompleted,
            browseInspectedCount: browseInspectedCount,
            browsePhotos: browsePhotoURLs.map {
                WebRemotePhoto(
                    id: webPhotoID(for: $0),
                    name: $0.lastPathComponent,
                    folder: $0.deletingLastPathComponent().lastPathComponent,
                    blurProbability: 0,
                    issues: [],
                    flags: [],
                    needsReview: false,
                    burstGroup: nil,
                    burstRank: nil,
                    duplicateGroup: nil
                )
            },
            rawScanning: phase == .scanning,
            rawScanCompleted: phase == .scanned || phase == .cleaning || phase == .finished,
            rawInspectedCount: inspectedFileCount,
            rawCurrentFolder: currentFolderName,
            rawTotalBytes: totalByteCount,
            rawFiles: orphanedFiles.map {
                WebRemoteRawFile(
                    id: webPhotoID(for: $0.url),
                    name: $0.url.lastPathComponent,
                    folder: $0.url.deletingLastPathComponent().lastPathComponent,
                    byteCount: $0.totalByteCount,
                    xmpCount: $0.xmpSidecars.count
                )
            },
            rawCleaning: phase == .cleaning,
            rawCleanupMessage: rawCleanupMessage,
            rootFolderName: authorizedRootFolder?.lastPathComponent,
            selectedRelativePath: selectedRelativeFolderPath,
            canGoUp: !selectedRelativeFolderPath.isEmpty,
            folders: remoteChildFolders,
            backup: remoteBackup
        )
    }

    private var selectedRelativeFolderPath: String {
        guard let root = authorizedRootFolder, let selectedFolder,
              selectedFolder.path != root.path else { return "" }
        return String(selectedFolder.path.dropFirst(root.path.count + 1))
    }

    private var remoteChildFolders: [WebRemoteFolder] {
        guard let selectedFolder else { return [] }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isHiddenKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: selectedFolder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isDirectory == true, values.isHidden != true,
                  !url.lastPathComponent.hasPrefix(".") else { return nil }
            let relative = selectedRelativeFolderPath
            return WebRemoteFolder(
                path: relative.isEmpty ? url.lastPathComponent : relative + "/" + url.lastPathComponent,
                name: url.lastPathComponent
            )
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func selectRemoteFolder(_ relativePath: String) {
        guard let root = authorizedRootFolder, !isBusy else { return }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard components.allSatisfy({ $0 != "." && $0 != ".." && !$0.hasPrefix(".") }) else { return }
        let candidate = components.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }.standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path == root.path || candidate.path.hasPrefix(rootPrefix),
              (try? candidate.resourceValues(forKeys: [.isDirectoryKey, .isHiddenKey]))?.isDirectory == true else { return }
        selectedFolder = candidate
        resetForFolderSelection()
        restoreCachedRun(for: candidate)
    }

    private func uniqueWebCandidates() -> [BlurCandidate] {
        Array(Dictionary(
            (blurCandidates + burstPhotos).map { ($0.url, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values).sorted { $0.url.path < $1.url.path }
    }

    private func webPhotoURL(for id: String) -> URL? {
        uniqueWebCandidates().first { webPhotoID(for: $0.url) == id }?.url
            ?? browsePhotoURLs.first { webPhotoID(for: $0) == id }
    }

    private func webPhotoURLs(for ids: [String]) -> [URL] {
        let wanted = Set(ids)
        return Array(Set(
            uniqueWebCandidates().map(\.url) + browsePhotoURLs
        )).filter { wanted.contains(webPhotoID(for: $0)) }
    }

    private func webRawFile(for id: String) -> OrphanedCR3? {
        orphanedFiles.first { webPhotoID(for: $0.url) == id }
    }

    private var rawCleanupMessage: String? {
        guard let report = cleanupReport else { return nil }
        if report.dryRun { return "Dry Run reviewed \(report.requestedCount) RAW/XMP files; nothing moved." }
        var value = "Moved to Trash: \(report.movedCount) • Failed: \(report.failures.count)"
        if let failure = report.failures.first {
            value += " • \(failure.url.lastPathComponent): \(failure.reason)"
        }
        return value
    }

    private func cacheCurrentScan(for folder: URL) async {
        await resultCache.save(
            scan: .init(orphanedFiles: orphanedFiles, inspectedFileCount: inspectedFileCount, errors: scanErrors),
            for: folder
        )
    }

    private func webPhotoID(for url: URL) -> String {
        SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func stopSecurityScope() {
        if isUsingSecurityScope { authorizedRootFolder?.stopAccessingSecurityScopedResource() }
        isUsingSecurityScope = false
        authorizedRootFolder = nil
    }

    private func stopBackupDestinationSecurityScope() {
        if isUsingBackupDestinationSecurityScope {
            backupDestinationFolder?.stopAccessingSecurityScopedResource()
        }
        isUsingBackupDestinationSecurityScope = false
        backupDestinationFolder = nil
    }

    private func resetBackupCheckResults() {
        backupCheckTask?.cancel()
        backupCopyTask?.cancel()
        backupCheckItems = []
        backupCheckErrors = []
        backupCheckCardFileCount = 0
        backupCheckLibraryFileCount = 0
        backupCheckCachedHashCount = 0
        backupCheckHashedByteCount = 0
        backupCheckStage = ""
        backupCheckCompletedCount = 0
        backupCheckTotalCount = nil
        backupCheckCurrentFileName = ""
        isCheckingBackup = false
        backupCheckCompleted = false
        backupSpacePlan = nil
        isBackingUpMissing = false
        backupCopyStage = ""
        backupCopyCompletedCount = 0
        backupCopyByteCount = 0
        backupCopyCurrentFileName = ""
        backupCopyReport = nil
    }

    private func resetBlurAnalysis() {
        blurTask?.cancel()
        blurCandidates = []
        burstPhotos = []
        burstGroupCount = 0
        blurErrors = []
        blurAnalyzedCount = 0
        blurCurrentFileName = ""
        isAnalyzingBlur = false
        blurAnalysisCompleted = false
        isTrashingReviewPhotos = false
        reviewTrashReport = nil
        isRestoringReviewPhotos = false
        restoreReport = nil
        undoTrashItems = []
        undoReviewCandidates = []
    }

    private func restoreCachedRun(for folder: URL) {
        cacheTask?.cancel()
        cacheTask = Task {
            guard let cached = await resultCache.load(for: folder),
                  !Task.isCancelled, selectedFolder == folder else { return }

            if let scan = cached.scan {
                orphanedFiles = scan.orphanedFiles.filter {
                    FileManager.default.fileExists(atPath: $0.url.path)
                }
                scanErrors = scan.errors
                inspectedFileCount = scan.inspectedFileCount
                phase = .scanned
            }
            if let analysis = cached.analysis {
                blurCandidates = analysis.candidates.filter {
                    FileManager.default.fileExists(atPath: $0.url.path)
                }
                burstPhotos = analysis.burstPhotos.filter {
                    FileManager.default.fileExists(atPath: $0.url.path)
                }
                burstGroupCount = analysis.burstGroupCount
                blurErrors = analysis.errors
                blurAnalyzedCount = analysis.analyzedCount
                blurAnalysisCompleted = true
            }
            cachedRunDate = cached.savedAt
        }
    }

    private func cacheCurrentAnalysis() async {
        guard blurAnalysisCompleted, let selectedFolder else { return }
        await resultCache.save(
            analysis: .init(
                candidates: blurCandidates,
                burstPhotos: burstPhotos,
                burstGroupCount: burstGroupCount,
                analyzedCount: blurAnalyzedCount,
                errors: blurErrors
            ),
            for: selectedFolder
        )
    }

    private func withIdleSleepDisabled<T>(
        reason: String,
        operation: () async throws -> T
    ) async rethrows -> T {
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: reason
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }
        return try await operation()
    }

    deinit {
        operationTask?.cancel()
        blurTask?.cancel()
        cacheTask?.cancel()
        backupCheckTask?.cancel()
        backupCopyTask?.cancel()
    }
}
