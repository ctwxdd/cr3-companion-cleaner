import AppKit
import CoreImage
import ImageIO
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

private enum ResultMode: String, CaseIterable, Identifiable {
    case rawCleanup = "RAW Cleanup"
    case blurReview = "Blur Review"
    case browse = "Browse Photos"
    case backupCheck = "Backup Check"

    var id: Self { self }
}

private enum ReviewFilter: String, CaseIterable, Identifiable {
    case all = "All Flags"
    case strongBlur = "Strong Blur (75%+)"
    case anyBlur = "Any Blur Flag"
    case blink = "Closed Eye / Blink"
    case faceQuality = "Low Face Quality"
    case underexposed = "Severely Underexposed"
    case overexposed = "Severely Overexposed"
    case lowResolution = "Low Resolution (<2 MP)"
    case exactDuplicate = "Exact Duplicates"
    case burstBest = "Best of Each Burst"

    var id: Self { self }
}

struct ContentView: View {
    @Environment(\.undoManager) private var undoManager
    @StateObject private var model = CleanerViewModel()
    @StateObject private var quickLook = QuickLookPreviewController()
    @State private var isDropTargeted = false
    @State private var resultMode = ResultMode.rawCleanup
    @State private var selectedBlurCandidateIDs: Set<BlurCandidate.ID> = []
    @State private var activeBlurCandidateID: BlurCandidate.ID?
    @State private var groupsBursts = false
    @State private var reviewFilter = ReviewFilter.all
    @State private var showsReviewTrashConfirmation = false
    @State private var reviewTrashURLs: [URL] = []
    @State private var preferredNextReviewCandidateID: BlurCandidate.ID?
    @State private var showsWebRemote = false
    @State private var selectedBrowseURLs: Set<URL> = []
    @State private var activeBrowseURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted, perform: handleDrop)
        .sheet(isPresented: $model.showsConfirmation) {
            ConfirmationView(model: model)
        }
        .sheet(isPresented: $showsReviewTrashConfirmation) {
            ReviewTrashConfirmationView(
                urls: reviewTrashURLs,
                dryRun: model.dryRun,
                onConfirm: {
                    showsReviewTrashConfirmation = false
                    if !model.dryRun, resultMode == .blurReview { rememberNextReviewCandidate() }
                    model.trashReviewPhotos(reviewTrashURLs)
                }
            )
        }
        .sheet(isPresented: $showsWebRemote) {
            WebRemoteView(model: model)
        }
        .alert("Cannot Continue", isPresented: errorBinding) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
        .onChange(of: model.blurCandidates) { candidates in
            refreshReviewSelection(advanceAfterDeletion: true)
        }
        .onChange(of: model.burstPhotos) { _ in
            refreshReviewSelection(advanceAfterDeletion: true)
        }
        .onChange(of: groupsBursts) { _ in
            preferredNextReviewCandidateID = nil
            refreshReviewSelection()
        }
        .onChange(of: reviewFilter) { _ in
            preferredNextReviewCandidateID = nil
            refreshReviewSelection()
        }
        .onChange(of: model.reviewUndoVersion) { _ in registerReviewUndo() }
        .onChange(of: model.browsePhotoURLs) { urls in
            let available = Set(urls)
            selectedBrowseURLs.formIntersection(available)
            if activeBrowseURL.map({ available.contains($0) }) != true { activeBrowseURL = urls.first }
        }
        .onChange(of: model.selectedFolder) { _ in
            undoManager?.removeAllActions(withTarget: model)
        }
        .onChange(of: selectedBlurCandidateIDs) { ids in
            activeBlurCandidateID = ids.first(where: { $0 != activeBlurCandidateID }) ?? ids.first
            guard let candidate = selectedBlurCandidate else { return }
            quickLook.updateIfVisible(with: candidate.url)
        }
        .onChange(of: resultMode) { mode in
            if mode != .blurReview { quickLook.hide() }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "photo.stack")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("CR3 Companion Cleaner").font(.title2.bold())
                Text("Clean orphaned RAW files and review photo quality locally.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                if !model.isWebRemoteRunning { model.startWebRemote() }
                showsWebRemote = true
            } label: {
                Label(model.isWebRemoteRunning ? "Web Remote…" : "Start Web Remote", systemImage: "iphone.radiowaves.left.and.right")
            }
            .disabled(model.selectedFolder == nil)
            .help("Review analyzed photos from a phone on the same Wi-Fi network.")
            Toggle("Dry Run", isOn: $model.dryRun)
                .toggleStyle(.switch)
                .help("Dry Run lists results without moving any files.")
        }
        .padding(20)
    }

    @ViewBuilder private var content: some View {
        if model.selectedFolder == nil {
            dropZone
        } else {
            resultsView
        }
    }

    private var dropZone: some View {
        VStack(spacing: 18) {
            Image(systemName: isDropTargeted ? "folder.fill.badge.plus" : "folder.badge.plus")
                .font(.system(size: 64))
                .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
            Text("Drop a photo folder here").font(.title3.bold())
            Text("The folder and all of its subfolders will be scanned.")
                .foregroundStyle(.secondary)
            Button("Choose Folder…") { model.chooseFolder() }
                .controlSize(.large)
                .keyboardShortcut("o", modifiers: .command)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(isDropTargeted ? Color.accentColor : .secondary.opacity(0.35), style: .init(lineWidth: 2, dash: [8]))
                .padding(28)
        }
    }

    private var resultsView: some View {
        VStack(spacing: 0) {
            HStack {
                Label(model.selectedFolder?.lastPathComponent ?? "", systemImage: "folder.fill")
                    .fontWeight(.medium)
                Text(model.selectedFolder?.path ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let cachedRunDate = model.cachedRunDate {
                    Label(
                        "Cached \(cachedRunDate.formatted(date: .omitted, time: .shortened))",
                        systemImage: "bolt.horizontal.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.green)
                }
                Spacer()
                Button("Up", systemImage: "arrow.up") { model.goToParentFolder() }
                    .disabled(!model.canGoToParentFolder || model.isBusy)
                Button("Choose Subfolder…", systemImage: "folder") { model.chooseSubfolder() }
                    .disabled(model.isBusy)
                Picker("Results", selection: $resultMode) {
                    ForEach(ResultMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 500)
            }
            .padding(12)
            Divider()

            if resultMode == .rawCleanup {
                orphanedResultsView
            } else if resultMode == .blurReview {
                blurResultsView
            } else if resultMode == .browse {
                DesktopBrowseView(
                    model: model,
                    selectedURLs: $selectedBrowseURLs,
                    activeURL: $activeBrowseURL,
                    onTrash: requestBrowseTrash
                )
            } else {
                BackupCheckView(model: model)
            }
        }
    }

    private var orphanedResultsView: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.phase == .ready ? "RAW Companion Scan" : "\(model.orphanedFiles.count) orphaned CR3 files")
                        .font(.headline)
                    Text(model.phase == .ready
                         ? "Recursively find CR3 files without a same-name JPG or JPEG."
                         : "\(model.xmpSidecarCount) matching XMP sidecars • Total size: \(model.totalByteCount.formattedFileSize)")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.phase == .ready {
                    Button("Scan RAW") { model.scan() }
                        .buttonStyle(.borderedProminent)
                } else if model.phase == .scanning {
                    Button("Cancel Scan", role: .cancel) { model.cancelOperation() }
                } else {
                    Button("Reveal All in Finder") { model.revealAll() }
                        .disabled(model.orphanedFiles.isEmpty)
                }
            }
            .padding()

            if model.phase == .scanning {
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text("Scanned \(model.inspectedFileCount.formatted()) files — \(model.currentFolderName)")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.phase == .ready {
                VStack(spacing: 12) {
                    Image(systemName: "externaldrive.badge.magnifyingglass")
                        .font(.system(size: 46))
                        .foregroundStyle(.tint)
                    Text("Ready to Scan RAW").font(.title3.bold())
                    Text("You can switch to Blur Review and analyze photos without running this scan.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.orphanedFiles.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 46))
                        .foregroundStyle(.green)
                    Text("No Orphaned CR3 Files").font(.title3.bold())
                    Text("Every scanned CR3 has a same-name JPG or JPEG companion.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(model.orphanedFiles) {
                    TableColumn("File") { file in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.url.lastPathComponent).fontWeight(.medium)
                            if !file.xmpSidecars.isEmpty {
                                Text("Includes \(file.xmpSidecars.count) matching XMP sidecar(s)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(file.url.deletingLastPathComponent().path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .contextMenu {
                            Button("Reveal in Finder") { model.reveal(file) }
                        }
                    }
                    TableColumn("Size") { file in
                        Text(file.totalByteCount.formattedFileSize)
                    }
                    .width(90)
                    TableColumn("") { file in
                        Button("Reveal", systemImage: "magnifyingglass") { model.reveal(file) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Reveal in Finder")
                    }
                    .width(36)
                }
            }

            if !model.scanErrors.isEmpty {
                Text("\(model.scanErrors.count) item(s) could not be read. They were not included.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(8)
            }

            if let report = model.cleanupReport {
                VStack(alignment: .leading, spacing: 4) {
                    Text(report.dryRun ? "Dry Run Complete" : "Cleanup Complete").fontWeight(.semibold)
                    Text(report.dryRun
                         ? "\(report.requestedCount) files reviewed; nothing was moved."
                         : "Moved to Trash: \(report.movedCount) • Failed: \(report.failures.count)")
                    if report.wasCancelled { Text("Cancelled; remaining files were left untouched.") }
                    ForEach(report.failures) { failure in
                        Text("\(failure.url.lastPathComponent): \(failure.reason)")
                    }
                }
                .font(.caption)
                .foregroundStyle(report.failures.isEmpty ? Color.secondary : .orange)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
    }

    private var blurResultsView: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                    Text("Local Photo Review").font(.headline)
                    Text("Analyzed \(model.blurAnalyzedCount) photos • \(model.blurCandidates.count) review flags • \(model.burstGroupCount) burst groups")
                        .foregroundStyle(.secondary)
                    if !displayedReviewPhotos.isEmpty {
                        Text("Select photos; Space opens Quick Look, ↑/↓ browses, Delete moves selected photos to Trash.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    }
                    Spacer()
                    if model.blurAnalysisCompleted {
                        Button("Analyze Again") { model.analyzeBlur() }
                    }
                }

                HStack {
                    Picker("Filter", selection: $reviewFilter) {
                        ForEach(ReviewFilter.allCases) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .frame(width: 165)
                    .disabled(groupsBursts || !model.blurAnalysisCompleted)
                    Toggle("Group Bursts", isOn: $groupsBursts)
                        .toggleStyle(.button)
                        .disabled(!model.blurAnalysisCompleted)
                    Spacer()
                    Button("Quick Look", systemImage: "eye") { toggleQuickLook() }
                        .keyboardShortcut(.space, modifiers: [])
                        .disabled(selectedBlurCandidate == nil)
                        .help("Press Space to open or close Quick Look")
                    Button("Undo Trash", systemImage: "arrow.uturn.backward") {
                        undoManager?.removeAllActions(withTarget: model)
                        model.undoLastReviewTrash()
                    }
                    .disabled(!model.canUndoReviewTrash)
                    .help("Restore the most recent batch from Trash (⌘Z)")
                    Button(model.dryRun ? "Review Dry Run…" : "Move Selected to Trash…", systemImage: "trash") {
                        requestReviewTrash()
                    }
                    .disabled(selectedBlurCandidateIDs.isEmpty || model.isTrashingReviewPhotos)
                }
            }
            .padding()

            if model.isAnalyzingBlur {
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text("Analyzing \(model.blurCurrentFileName)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Using up to \(model.blurWorkerCount) parallel photo workers. Core ML can use CPU, GPU, and Neural Engine; all inference stays on this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Cancel Analysis", role: .cancel) { model.cancelBlurAnalysis() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !model.blurAnalysisCompleted {
                VStack(spacing: 14) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 46))
                        .foregroundStyle(.tint)
                    Text("Find Blur, Face Issues, and Bursts").font(.title3.bold())
                    Text("Uses bundled Core ML plus Apple Vision locally. Nothing moves to Trash until you select it and confirm.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                    Button("Analyze JPG/JPEG Photos") { model.analyzeBlur() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(model.isBusy)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if displayedReviewPhotos.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 46))
                        .foregroundStyle(.green)
                    Text(groupsBursts ? "No Burst Groups" : "No Review Candidates").font(.title3.bold())
                    Text(groupsBursts
                         ? "No photos were taken close enough together to form a burst group."
                         : "No photos match the selected review filter.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(displayedReviewPhotos, selection: $selectedBlurCandidateIDs) {
                    TableColumn("Photo") { candidate in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.url.lastPathComponent).fontWeight(.medium)
                            Text(candidate.url.deletingLastPathComponent().path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .contextMenu {
                            Button("Quick Look") {
                                selectedBlurCandidateIDs = [candidate.id]
                                activeBlurCandidateID = candidate.id
                                quickLook.show(candidate.url)
                            }
                            Button("Move to Trash…", role: .destructive) {
                                selectedBlurCandidateIDs = [candidate.id]
                                requestReviewTrash()
                            }
                            Button("Reveal in Finder") { model.reveal(candidate) }
                        }
                    }
                    TableColumn("Assessment") { candidate in
                        Text(assessment(for: candidate))
                            .foregroundStyle(candidate.needsReview ? Color.orange : .secondary)
                    }
                    .width(min: 150, ideal: 190)
                    TableColumn("Blur Probability") { candidate in
                        Text(candidate.prediction.blurredProbability.formatted(
                            .percent.precision(.fractionLength(0))
                        ))
                    }
                    .width(110)
                    TableColumn("Groups") { candidate in
                        Text(groupLabel(for: candidate))
                    }
                    .width(120)
                    TableColumn("") { candidate in
                        Button("Reveal", systemImage: "magnifyingglass") { model.reveal(candidate) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Reveal in Finder")
                    }
                    .width(36)
                }
                .onDeleteCommand { requestReviewTrash() }
            }

            if model.isTrashingReviewPhotos {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Moving selected photos to Trash…")
                }
                .font(.caption)
                .padding(8)
            } else if model.isRestoringReviewPhotos {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Restoring the last batch from Trash…")
                }
                .font(.caption)
                .padding(8)
            } else if let report = model.restoreReport {
                Text(restoreSummary(report))
                    .font(.caption)
                    .foregroundStyle(report.failures.isEmpty ? Color.secondary : .orange)
                    .padding(8)
            } else if let report = model.reviewTrashReport {
                Text(reviewTrashSummary(report))
                    .font(.caption)
                    .foregroundStyle(report.failures.isEmpty ? Color.secondary : .orange)
                    .padding(8)
            }

            if !model.blurErrors.isEmpty {
                Text("\(model.blurErrors.count) photo(s) could not be analyzed.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(8)
            }
        }
        .onAppear {
            refreshReviewSelection()
        }
    }

    private var footer: some View {
        HStack {
            if model.selectedFolder != nil {
                Button("Choose Another Folder…") { model.chooseFolder() }
                    .disabled(model.isBusy)
            }
            if model.phase == .scanned || model.phase == .finished {
                Button("Scan RAW Again") { model.scan() }
                    .disabled(model.isBusy)
            }
            Spacer()
            if model.phase == .cleaning {
                ProgressView().controlSize(.small)
                Button("Cancel", role: .cancel) { model.cancelOperation() }
            } else if model.isTrashingReviewPhotos {
                ProgressView().controlSize(.small)
                Button("Cancel", role: .cancel) { model.cancelBlurAnalysis() }
            } else if model.isRestoringReviewPhotos {
                ProgressView().controlSize(.small)
            } else if model.isAnalyzingBlur {
                ProgressView().controlSize(.small)
                Button("Cancel Analysis", role: .cancel) { model.cancelBlurAnalysis() }
            } else if model.isCheckingBackup {
                ProgressView().controlSize(.small)
                Button("Cancel Backup Check", role: .cancel) { model.cancelBackupCheck() }
            } else if model.isBackingUpMissing {
                ProgressView().controlSize(.small)
                Button("Cancel Backup", role: .cancel) { model.cancelBackupCopy() }
            } else if model.phase == .scanned && resultMode == .rawCleanup {
                Button(model.dryRun ? "Review Dry Run…" : "Move to Trash…") {
                    model.requestCleanup()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.orphanedFiles.isEmpty)
            }
        }
        .padding(12)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    private var displayedReviewPhotos: [BlurCandidate] {
        guard !groupsBursts else { return model.burstPhotos }
        switch reviewFilter {
        case .all:
            return model.blurCandidates
        case .strongBlur:
            return model.blurCandidates.filter { $0.prediction.blurredProbability >= 0.75 }
        case .anyBlur:
            return model.blurCandidates.filter { $0.prediction.label != .sharp }
        case .blink:
            return model.blurCandidates.filter { $0.faceIssues.contains(.possibleBlink) }
        case .faceQuality:
            return model.blurCandidates.filter { $0.faceIssues.contains(.lowFaceQuality) }
        case .underexposed:
            return model.blurCandidates.filter { $0.qualityIssues.contains(.underexposed) }
        case .overexposed:
            return model.blurCandidates.filter { $0.qualityIssues.contains(.overexposed) }
        case .lowResolution:
            return model.blurCandidates.filter { $0.qualityIssues.contains(.lowResolution) }
        case .exactDuplicate:
            return model.blurCandidates.filter { $0.qualityIssues.contains(.exactDuplicate) }
        case .burstBest:
            return model.burstPhotos.filter { $0.burstRank == 1 }
        }
    }

    private var selectedBlurCandidate: BlurCandidate? {
        displayedReviewPhotos.first { $0.id == activeBlurCandidateID }
            ?? displayedReviewPhotos.first { selectedBlurCandidateIDs.contains($0.id) }
    }

    private func toggleQuickLook() {
        guard let candidate = selectedBlurCandidate else { return }
        quickLook.toggle(candidate.url)
    }

    private func refreshReviewSelection(advanceAfterDeletion: Bool = false) {
        let available = Set(displayedReviewPhotos.map(\.id))
        let selectedItemWasRemoved = !selectedBlurCandidateIDs.isSubset(of: available)
        selectedBlurCandidateIDs.formIntersection(available)
        if advanceAfterDeletion, selectedItemWasRemoved,
           let preferredNextReviewCandidateID,
           available.contains(preferredNextReviewCandidateID) {
            selectedBlurCandidateIDs = [preferredNextReviewCandidateID]
            activeBlurCandidateID = preferredNextReviewCandidateID
            self.preferredNextReviewCandidateID = nil
        }
        if selectedBlurCandidateIDs.isEmpty, let first = displayedReviewPhotos.first?.id {
            selectedBlurCandidateIDs = [first]
        }
        if activeBlurCandidateID.map({ available.contains($0) }) != true {
            activeBlurCandidateID = selectedBlurCandidateIDs.first
        }
    }

    private func rememberNextReviewCandidate() {
        preferredNextReviewCandidateID = ReviewSelection.preferredNextID(
            in: displayedReviewPhotos,
            selected: selectedBlurCandidateIDs
        )
    }

    private func requestReviewTrash() {
        reviewTrashURLs = displayedReviewPhotos
            .filter { selectedBlurCandidateIDs.contains($0.id) }
            .map(\.url)
        showsReviewTrashConfirmation = !reviewTrashURLs.isEmpty
    }

    private func requestBrowseTrash() {
        reviewTrashURLs = model.browsePhotoURLs.filter { selectedBrowseURLs.contains($0) }
        showsReviewTrashConfirmation = !reviewTrashURLs.isEmpty
    }

    private func assessment(for candidate: BlurCandidate) -> String {
        var labels = candidate.faceIssues.map(\.rawValue) + candidate.qualityIssues.map(\.rawValue)
        if candidate.prediction.label == .blurred { labels.insert("Likely blurred", at: 0) }
        if candidate.prediction.label == .uncertain { labels.insert("Blur uncertain", at: 0) }
        return labels.isEmpty ? "Looks OK" : labels.joined(separator: " • ")
    }

    private func groupLabel(for candidate: BlurCandidate) -> String {
        var labels: [String] = []
        if let group = candidate.burstGroupID {
            labels.append(candidate.burstRank == 1 ? "Burst \(group) • Best" : "Burst \(group) • #\(candidate.burstRank ?? 0)")
        }
        if let group = candidate.duplicateGroupID { labels.append("Duplicate \(group)") }
        return labels.isEmpty ? "—" : labels.joined(separator: " / ")
    }

    private func reviewTrashSummary(_ report: CleanupReport) -> String {
        if report.dryRun { return "Dry Run: \(report.requestedCount) selected photo(s); nothing was moved." }
        let summary = "Moved to Trash: \(report.movedCount) • Failed: \(report.failures.count)"
        guard let failure = report.failures.first else { return summary }
        return summary + " • \(failure.url.lastPathComponent): \(failure.reason)"
    }

    private func restoreSummary(_ report: RestoreReport) -> String {
        let summary = "Restored: \(report.restoredCount) • Failed: \(report.failures.count)"
        guard let failure = report.failures.first else { return summary }
        return summary + " • \(failure.url.lastPathComponent): \(failure.reason)"
    }

    private func registerReviewUndo() {
        guard model.canUndoReviewTrash, let undoManager else { return }
        undoManager.removeAllActions(withTarget: model)
        undoManager.registerUndo(withTarget: model) { target in
            Task { @MainActor in target.undoLastReviewTrash() }
        }
        undoManager.setActionName("Restore Photos from Trash")
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
            guard let data,
                  let string = String(data: data, encoding: .utf8),
                  let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
            Task { @MainActor in model.selectFolder(url) }
        }
        return true
    }
}

private struct BackupCheckView: View {
    private enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case notFound = "Not Backed Up"
        case backedUp = "Backed Up"

        var id: Self { self }
    }

    @ObservedObject var model: CleanerViewModel
    @State private var filter = Filter.all
    @State private var showsBackupConfirmation = false

    private var displayedItems: [BackupCheckItem] {
        switch filter {
        case .all: return model.backupCheckItems
        case .notFound: return model.backupCheckItems.filter { $0.status == .notFound }
        case .backedUp: return model.backupCheckItems.filter { $0.status == .backedUp }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Camera Card Backup Check").font(.headline)
                    Text(model.backupCheckCompleted
                         ? "\(model.backedUpCount) confirmed backed up • \(model.notBackedUpCount) not found"
                         : "Compare camera media with your designated destination by filename, size, and SHA-256 contents.")
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Label("Card Read Only", systemImage: "lock.shield")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Memory Card…", systemImage: "sdcard") { model.chooseCameraCard() }
                        .disabled(model.isBusy)
                    Button("Destination…", systemImage: "externaldrive.badge.plus") {
                        model.chooseBackupDestination()
                    }
                    .disabled(model.isBusy)
                    Button(model.backupCheckCompleted ? "Check Again" : "Check Backup") {
                        model.checkCameraCardBackup()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.cameraCardFolder == nil || model.effectiveBackupFolder == nil || model.isBusy)
                    if model.notBackedUpCount > 0 {
                        Button("Back Up Missing…", systemImage: "square.and.arrow.down") {
                            model.refreshBackupSpacePlan(showError: true)
                            if model.backupSpacePlan != nil { showsBackupConfirmation = true }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy)
                    }
                }
            }
            .padding()

            HStack(spacing: 8) {
                Label(model.cameraCardFolder?.path ?? "No memory card selected", systemImage: "sdcard")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                Label(model.effectiveBackupFolder?.path ?? "No backup destination selected", systemImage: "externaldrive.fill")
                    .lineLimit(1)
                    .truncationMode(.middle)
                if model.backupDestinationFolder != nil {
                    Button("Use Photo Folder") { model.usePhotoFolderAsBackupDestination() }
                        .buttonStyle(.link)
                        .help("Clear the designated destination and use the selected photo folder")
                }
                Spacer()
                if model.backupCheckCompleted {
                    Picker("Show", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 330)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.bottom, 10)

            Divider()

            if model.isBackingUpMissing {
                VStack(spacing: 14) {
                    if let plan = model.backupSpacePlan, plan.requiredByteCount > 0 {
                        ProgressView(
                            value: Double(model.backupCopyByteCount),
                            total: Double(plan.requiredByteCount)
                        )
                        .frame(maxWidth: 460)
                    } else {
                        ProgressView().controlSize(.large)
                    }
                    Text("\(model.backupCopyStage) • \(model.backupCopyCompletedCount)/\(model.backupSpacePlan?.fileCount ?? 0)")
                        .font(.headline)
                    Text(model.backupCopyCurrentFileName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Copied \(model.backupCopyByteCount.formattedFileSize)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Cancel Backup", role: .cancel) { model.cancelBackupCopy() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.isCheckingBackup {
                VStack(spacing: 14) {
                    if let total = model.backupCheckTotalCount, total > 0 {
                        ProgressView(value: Double(model.backupCheckCompletedCount), total: Double(total))
                            .frame(maxWidth: 420)
                    } else {
                        ProgressView().controlSize(.large)
                    }
                    Text(model.backupCheckStage).font(.headline)
                    Text("\(model.backupCheckCompletedCount.formatted()) checked • \(model.backupCheckCurrentFileName)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Cancel", role: .cancel) { model.cancelBackupCheck() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !model.backupCheckCompleted {
                VStack(spacing: 12) {
                    Image(systemName: "sdcard.fill").font(.system(size: 48)).foregroundStyle(.tint)
                    Text("Choose the Mounted Memory Card").font(.title3.bold())
                    Text("Choose a destination, or use the selected photo folder as the backup library. The memory card is never modified.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 560)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.backupCheckItems.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "photo.badge.exclamationmark").font(.system(size: 46)).foregroundStyle(.secondary)
                    Text("No Files Found").font(.title3.bold())
                    Text("No visible, readable files were found on the selected memory card.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(displayedItems) {
                    TableColumn("Memory Card File") { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.sourceURL.lastPathComponent).fontWeight(.medium)
                            Text(item.sourceURL.deletingLastPathComponent().path)
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        .contextMenu {
                            Button("Reveal on Memory Card") { model.revealBackupCheckSource(item) }
                            if item.backupURL != nil {
                                Button("Reveal Backup Copy") { model.revealBackupMatch(item) }
                            }
                        }
                    }
                    TableColumn("Status") { item in
                        Label(
                            item.status.rawValue,
                            systemImage: item.status == .backedUp ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(item.status == .backedUp ? Color.green : Color.orange)
                    }
                    .width(min: 120, ideal: 140)
                    TableColumn("Size") { item in Text(item.byteCount.formattedFileSize) }
                        .width(90)
                    TableColumn("Backup Location") { item in
                        if let backupURL = item.backupURL {
                            Button(backupURL.deletingLastPathComponent().path) { model.revealBackupMatch(item) }
                                .buttonStyle(.link)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text("—").foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if model.backupCheckCompleted {
                VStack(alignment: .leading, spacing: 5) {
                    if let plan = model.backupSpacePlan, plan.fileCount > 0 {
                        HStack {
                            Label("Needed: \(plan.requiredByteCount.formattedFileSize)", systemImage: "internaldrive")
                            Text("Available: \(plan.availableByteCount.formattedFileSize)")
                            Text("After backup: \(max(0, plan.remainingByteCount).formattedFileSize)")
                                .foregroundStyle(plan.hasEnoughSpace ? Color.secondary : Color.red)
                        }
                        .fontWeight(.medium)
                    }
                    HStack {
                        Text("Card: \(model.backupCheckCardFileCount) • Backup index: \(model.backupCheckLibraryFileCount) • \(model.backupCheckCachedHashCount) cached hashes • Read: \(model.backupCheckHashedByteCount.formattedFileSize)")
                        Spacer()
                        if !model.backupCheckErrors.isEmpty {
                            Text("\(model.backupCheckErrors.count) item(s) could not be verified")
                                .foregroundStyle(.orange)
                                .help(model.backupCheckErrors.prefix(5).map { "\($0.url.lastPathComponent): \($0.reason)" }.joined(separator: "\n"))
                        }
                    }
                    if let report = model.backupCopyReport {
                        Text("Backup complete: \(report.copiedItems.count) copied and SHA-256 verified • \(report.failures.count) failed\(report.wasCancelled ? " • Cancelled" : "")")
                            .foregroundStyle(report.failures.isEmpty ? Color.green : Color.orange)
                        ForEach(report.failures.prefix(3)) { failure in
                            Text("\(failure.url.lastPathComponent): \(failure.reason)")
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .sheet(isPresented: $showsBackupConfirmation) {
            if let plan = model.backupSpacePlan {
                BackupCopyConfirmationView(
                    plan: plan,
                    onConfirm: {
                        showsBackupConfirmation = false
                        model.backUpMissingPhotos()
                    }
                )
            }
        }
    }
}

private struct BackupCopyConfirmationView: View {
    @Environment(\.dismiss) private var dismiss
    let plan: BackupSpacePlan
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Back Up Missing Photos", systemImage: "externaldrive.badge.plus")
                .font(.title2.bold())
            Text("\(plan.fileCount) file(s) will be copied. The memory card remains read-only.")
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow { Text("Required").foregroundStyle(.secondary); Text(plan.requiredByteCount.formattedFileSize).fontWeight(.semibold) }
                GridRow { Text("Available").foregroundStyle(.secondary); Text(plan.availableByteCount.formattedFileSize) }
                GridRow {
                    Text("Remaining after").foregroundStyle(.secondary)
                    Text(max(0, plan.remainingByteCount).formattedFileSize)
                        .foregroundStyle(plan.hasEnoughSpace ? Color.primary : Color.red)
                }
                GridRow {
                    Text("Destination").foregroundStyle(.secondary)
                    Text(plan.destinationRoot.path).lineLimit(2).truncationMode(.middle)
                }
            }
            Text("Folder structure and file dates are preserved. Existing files are never overwritten. Every copy is SHA-256 verified before it becomes visible at the final path.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !plan.hasEnoughSpace {
                Label("Not enough free space for this backup.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Back Up Now") { onConfirm() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!plan.hasEnoughSpace)
            }
        }
        .padding(24)
        .frame(width: 540)
    }
}

private struct DesktopBrowseView: View {
    @ObservedObject var model: CleanerViewModel
    @Binding var selectedURLs: Set<URL>
    @Binding var activeURL: URL?
    let onTrash: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Browse Photos").font(.headline)
                    Text(model.browseCompleted
                         ? "\(model.browsePhotoURLs.count) JPG/JPEG photos • no AI analysis"
                         : "Build a lightweight photo index without running AI.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.browseCompleted ? "Refresh" : "Browse Photos") { model.browsePhotos() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)
                Button("Undo Trash", systemImage: "arrow.uturn.backward") { model.undoLastReviewTrash() }
                    .disabled(!model.canUndoReviewTrash)
                Button(model.dryRun ? "Review Dry Run…" : "Move Selected to Trash…", systemImage: "trash") {
                    onTrash()
                }
                .disabled(selectedURLs.isEmpty || model.isBusy)
            }
            .padding()

            if model.isIndexingBrowse {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("Indexing… \(model.browseInspectedCount.formatted()) files checked")
                        .foregroundStyle(.secondary)
                    Button("Cancel", role: .cancel) { model.cancelOperation() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !model.browseCompleted {
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 46)).foregroundStyle(.tint)
                    Text("Browse Without AI").font(.title3.bold())
                    Text("Only filenames are indexed. Thumbnails load on demand.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.browsePhotoURLs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "photo").font(.system(size: 46)).foregroundStyle(.secondary)
                    Text("No JPG/JPEG Photos").font(.title3.bold())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 4)], spacing: 4) {
                            ForEach(model.browsePhotoURLs, id: \.self) { url in
                                ZStack(alignment: .topTrailing) {
                                    Button { activeURL = url } label: {
                                        LocalPhotoImage(url: url, maxPixel: 300)
                                            .frame(maxWidth: .infinity)
                                            .frame(height: 112)
                                            .background(.black)
                                            .overlay {
                                                RoundedRectangle(cornerRadius: 3)
                                                    .stroke(activeURL == url ? Color.accentColor : .clear, lineWidth: 3)
                                            }
                                    }
                                    .buttonStyle(.plain)
                                    Button {
                                        if selectedURLs.contains(url) { selectedURLs.remove(url) }
                                        else { selectedURLs.insert(url) }
                                        activeURL = url
                                    } label: {
                                        Image(systemName: selectedURLs.contains(url) ? "checkmark.circle.fill" : "circle")
                                            .font(.title3)
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, Color.accentColor)
                                            .shadow(radius: 2)
                                    }
                                    .buttonStyle(.plain)
                                    .padding(6)
                                }
                                .contextMenu {
                                    Button("Select") { selectedURLs.insert(url); activeURL = url }
                                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                }
                            }
                        }
                        .padding(4)
                    }
                    .frame(minWidth: 260, idealWidth: 360)

                    DesktopPhotoPreview(urls: model.browsePhotoURLs, activeURL: $activeURL)
                        .frame(minWidth: 360)
                }
                .onDeleteCommand { onTrash() }
            }
        }
    }
}

private struct DesktopPhotoPreview: View {
    let urls: [URL]
    @Binding var activeURL: URL?
    @State private var zoom: CGFloat = 1
    @State private var settledZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var settledOffset: CGSize = .zero

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                ZStack {
                    Color.black
                    if let activeURL {
                        LocalPhotoImage(url: activeURL, maxPixel: 2_400)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .scaleEffect(zoom)
                            .offset(offset)
                            .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.9), value: zoom)
                    }
                }
                .clipped()
                .contentShape(Rectangle())
                .gesture(MagnificationGesture()
                    .onChanged { value in zoom = min(6, max(1, settledZoom * value)) }
                    .onEnded { _ in
                        settledZoom = zoom
                        if zoom <= 1.01 { resetZoom() }
                    })
                .simultaneousGesture(DragGesture()
                    .onChanged { value in
                        guard zoom > 1 else { return }
                        offset = CGSize(
                            width: settledOffset.width + value.translation.width,
                            height: settledOffset.height + value.translation.height
                        )
                    }
                    .onEnded { _ in settledOffset = offset })
            }

            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 4) {
                        ForEach(urls, id: \.self) { url in
                            Button { activeURL = url } label: {
                                LocalPhotoImage(url: url, maxPixel: 180)
                                    .frame(width: 62, height: 66)
                                    .background(.black)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 3)
                                            .stroke(activeURL == url ? Color.white : .clear, lineWidth: 2)
                                    }
                            }
                            .buttonStyle(.plain)
                            .id(url)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .frame(height: 76)
                .background(Color(nsColor: .controlBackgroundColor))
                .onChange(of: activeURL) { url in
                    resetZoom()
                    if let url { withAnimation(.easeOut(duration: 0.16)) { reader.scrollTo(url, anchor: .center) } }
                }
            }
        }
        .focusable()
        .onMoveCommand { direction in
            if direction == .left { move(-1) }
            if direction == .right { move(1) }
        }
        .task(id: activeURL) {
            guard let activeURL, let index = urls.firstIndex(of: activeURL) else { return }
            let nearby = (-2...2).compactMap { offset -> URL? in
                guard offset != 0, urls.indices.contains(index + offset) else { return nil }
                return urls[index + offset]
            }
            await withTaskGroup(of: Void.self) { group in
                for url in nearby {
                    group.addTask { _ = await ImageThumbnailCache.shared.image(for: url, maxPixel: 2_400) }
                }
            }
        }
    }

    private func move(_ amount: Int) {
        guard !urls.isEmpty else { return }
        let index = activeURL.flatMap { urls.firstIndex(of: $0) } ?? 0
        activeURL = urls[(index + amount + urls.count) % urls.count]
    }

    private func resetZoom() {
        zoom = 1
        settledZoom = 1
        offset = .zero
        settledOffset = .zero
    }
}

private struct LocalPhotoImage: View {
    let url: URL
    let maxPixel: Int
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: url.path + "|\(maxPixel)") {
            let cgImage = await ImageThumbnailCache.shared.image(for: url, maxPixel: maxPixel)
            guard !Task.isCancelled, let cgImage else { return }
            image = NSImage(cgImage: cgImage, size: .zero)
        }
    }
}

private struct WebRemoteView: View {
    @ObservedObject var model: CleanerViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.system(size: 42))
                .foregroundStyle(.tint)
            Text("Web Remote").font(.title2.bold())

            if let url = model.webRemoteURL, let pin = model.webRemotePIN {
                if let image = qrCode(for: url) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 190, height: 190)
                        .accessibilityLabel("QR code for Web Remote")
                }
                Text(url)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Text("PIN  \(pin)")
                    .font(.system(size: 26, weight: .bold, design: .monospaced))
                    .textSelection(.enabled)
                Text("Pair once on the same Wi-Fi, then bookmark this stable .local address. This phone stays signed in across normal App restarts. You can also check and run SHA-256 verified camera-card backups after selecting the card and destination on the Mac. Choosing Stop Web Remote revokes the saved pairing.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                HStack {
                    Button("Copy Address") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url, forType: .string) }
                    Button("Stop Web Remote", role: .destructive) { model.stopWebRemote() }
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            } else {
                if let error = model.webRemoteError {
                    Text(error).foregroundStyle(.red).multilineTextAlignment(.center)
                } else {
                    ProgressView("Starting secure local session…")
                }
                HStack {
                    Button("Try Again") { model.startWebRemote() }
                    Button("Close") { dismiss() }
                }
            }
        }
        .padding(28)
        .frame(minWidth: 520, minHeight: 360)
    }

    private func qrCode(for text: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: .init(scaleX: 9, y: 9)) else { return nil }
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}

private struct ReviewTrashConfirmationView: View {
    let urls: [URL]
    let dryRun: Bool
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(
                dryRun ? "Confirm Photo Dry Run" : "Move Selected Photos to Trash?",
                systemImage: dryRun ? "eye" : "trash"
            )
            .font(.title2.bold())

            Text("\(urls.count) selected JPG/JPEG photo(s)").font(.headline)
            Text(dryRun
                 ? "Dry Run is on. No photos will be moved."
                 : "Only the photos listed below will be moved using the macOS Trash. This does not permanently delete them.")
                .foregroundStyle(.secondary)

            List(urls, id: \.self) { url in
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent)
                    Text(url.path).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 220)

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(dryRun ? "Complete Dry Run" : "Move to Trash", role: dryRun ? nil : .destructive) {
                    onConfirm()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 640, height: 440)
    }
}

/// Owns the system Quick Look panel. Keeping it non-key lets the Table retain
/// keyboard focus, so Up/Down changes selection while the preview stays open.
@MainActor
private final class QuickLookPreviewController: NSObject, ObservableObject, @preconcurrency QLPreviewPanelDataSource {
    private var previewURL: URL?

    func show(_ url: URL) {
        previewURL = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.currentPreviewItemIndex = 0
        panel.reloadData()
        panel.orderFrontRegardless()
    }

    func toggle(_ url: URL) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            show(url)
        }
    }

    func updateIfVisible(with url: URL) {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              QLPreviewPanel.shared().isVisible else { return }
        show(url)
    }

    func hide() {
        guard QLPreviewPanel.sharedPreviewPanelExists() else { return }
        QLPreviewPanel.shared().orderOut(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURL as NSURL?
    }
}

private struct ConfirmationView: View {
    @ObservedObject var model: CleanerViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(
                model.dryRun ? "Confirm Dry Run" : "Move CR3 Files to Trash?",
                systemImage: model.dryRun ? "eye" : "trash"
            )
            .font(.title2.bold())

            Text("\(model.cleanupFileCount) files (\(model.orphanedFiles.count) CR3 + \(model.xmpSidecarCount) XMP) • \(model.totalByteCount.formattedFileSize)")
                .font(.headline)
            Text(model.dryRun
                 ? "Dry Run is on. No files will be moved."
                 : "Only the CR3 files and listed XMP sidecars below will be moved to the macOS Trash. No JPG files will be changed.")
                .foregroundStyle(.secondary)

            List(model.orphanedFiles) { file in
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.url.lastPathComponent)
                    Text(file.url.path).font(.caption).foregroundStyle(.secondary)
                    ForEach(file.xmpSidecars) { sidecar in
                        Label(sidecar.url.lastPathComponent, systemImage: "doc.text")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 12)
                    }
                }
            }
            .frame(minHeight: 240)

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(model.dryRun ? "Complete Dry Run" : "Move to Trash", role: model.dryRun ? nil : .destructive) {
                    model.confirmCleanup()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 640, height: 480)
    }
}
