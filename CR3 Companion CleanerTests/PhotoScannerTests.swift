import XCTest
@testable import CR3_Companion_Cleaner

final class PhotoScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCR3WithMatchingJPGIsNotOrphaned() async throws {
        try makeFile("IMG_1234.CR3")
        try makeFile("IMG_1234.JPG")
        let report = try await scan()
        XCTAssertTrue(report.orphanedFiles.isEmpty)
    }

    func testCR3WithoutJPGIsOrphaned() async throws {
        let raw = try makeFile("IMG_1234.CR3")
        let report = try await scan()
        XCTAssertEqual(report.orphanedFiles.map(\.url), [raw])
    }

    func testJPGExtensionMatchingIsCaseInsensitive() async throws {
        for (index, ext) in ["JPG", "JPEG", "jpg", "jpeg", "JpG", "jPeG"].enumerated() {
            try makeFile("IMG_\(index).CR3")
            try makeFile("IMG_\(index).\(ext)")
        }
        let report = try await scan()
        XCTAssertTrue(report.orphanedFiles.isEmpty)
    }

    func testSpacesAndChineseCharactersInNames() async throws {
        try makeFile("旅行 照片 01.cr3")
        try makeFile("旅行 照片 01.jpeg")
        let orphan = try makeFile("只有 RAW.cr3")
        let report = try await scan()
        XCTAssertEqual(report.orphanedFiles.map(\.url), [orphan])
    }

    func testSubfoldersAreScanned() async throws {
        let nested = root.appendingPathComponent("2026/旅行", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let orphan = try makeFile("nested.CR3", in: nested)
        let report = try await scan()
        XCTAssertEqual(report.orphanedFiles.map(\.url), [orphan])
    }

    func testBrowseDiscoveryFindsJPGsWithoutAnalysis() async throws {
        let nested = root.appendingPathComponent("旅行", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let first = try makeFile("A.JPG")
        let second = try makeFile("中文 照片.jpeg", in: nested)
        try makeFile("ignored.CR3")

        let found = try await PhotoScanner().discoverJPGs(folder: root) { _ in }
        XCTAssertEqual(Set(found), Set([first, second]))
    }

    func testRawNamedSubfoldersMatchJPGInParentCaseInsensitively() async throws {
        for (index, folderName) in ["raw", "RAW", "Cr3", "aRw"].enumerated() {
            let parent = root.appendingPathComponent("Case\(index)", isDirectory: true)
            let rawFolder = parent.appendingPathComponent(folderName, isDirectory: true)
            try FileManager.default.createDirectory(at: rawFolder, withIntermediateDirectories: true)
            try makeFile("IMG_\(index).CR3", in: rawFolder)
            try makeFile("IMG_\(index).JpEg", in: parent)
        }

        let report = try await scan()
        XCTAssertTrue(report.orphanedFiles.isEmpty)
    }

    func testBothJPGAndJPEGStillProtectCR3() async throws {
        try makeFile("IMG_42.CR3")
        try makeFile("IMG_42.JPG")
        try makeFile("IMG_42.jpeg")
        let report = try await scan()
        XCTAssertTrue(report.orphanedFiles.isEmpty)
    }

    func testRemovingJPGFindsNewOrphanWithoutFullRescan() async throws {
        let rawFolder = root.appendingPathComponent("RAW", isDirectory: true)
        try FileManager.default.createDirectory(at: rawFolder, withIntermediateDirectories: true)
        let raw = try makeFile("IMG_99.CR3", in: rawFolder)
        let jpg = try makeFile("IMG_99.JPG")
        try FileManager.default.removeItem(at: jpg)

        let orphans = await PhotoScanner().newlyOrphanedCR3s(afterRemovingJPGs: [jpg])
        XCTAssertEqual(orphans.map(\.url), [raw])
    }

    func testUnreadableCR3IsReportedAndNotOfferedForCleanup() async throws {
        let raw = try makeFile("private.CR3")
        let scanner = PhotoScanner(readabilityChecker: { $0 != raw.path })
        let report = try await scanner.scan(folder: root) { _ in }
        XCTAssertTrue(report.orphanedFiles.isEmpty)
        XCTAssertEqual(report.errors.first?.url, raw)
        XCTAssertTrue(report.errors.first?.reason.contains("access was denied") == true)
    }

    func testMatchingXMPSidecarsAreIncludedForOrphanedCR3() async throws {
        try makeFile("旅行 照片.CR3")
        try makeFile("旅行 照片.XmP")
        try makeFile("different.xmp")

        let report = try await scan()
        XCTAssertEqual(report.orphanedFiles.first?.xmpSidecars.map(\.url.lastPathComponent), ["旅行 照片.XmP"])
    }

    func testBlurModelThresholdMappingIsIndependentOfModelAdapter() {
        let configuration = BlurModelConfiguration.bundled
        XCTAssertEqual(configuration.prediction(sharp: 0.9, blurred: 0.1).label, .sharp)
        XCTAssertEqual(configuration.prediction(sharp: 0.1, blurred: 0.9).label, .blurred)
        XCTAssertEqual(configuration.prediction(sharp: 0.55, blurred: 0.45).label, .uncertain)
    }

    func testBurstGroupingUsesCaptureTimeAndFolder() {
        let prediction = BlurPrediction(label: .sharp, sharpProbability: 0.9, blurredProbability: 0.1)
        let start = Date(timeIntervalSince1970: 1_000)
        let photos = [
            BlurCandidate(url: root.appendingPathComponent("A.JPG"), prediction: prediction, captureDate: start),
            BlurCandidate(url: root.appendingPathComponent("B.JPG"), prediction: prediction, captureDate: start.addingTimeInterval(0.4)),
            BlurCandidate(url: root.appendingPathComponent("C.JPG"), prediction: prediction, captureDate: start.addingTimeInterval(5))
        ]

        let grouped = BurstGrouping.assignGroups(to: photos)
        XCTAssertEqual(grouped.groupCount, 1)
        XCTAssertNotNil(grouped.photos[0].burstGroupID)
        XCTAssertEqual(grouped.photos[0].burstGroupID, grouped.photos[1].burstGroupID)
        XCTAssertNil(grouped.photos[2].burstGroupID)
    }

    func testEyeAspectRatioDistinguishesFlatEyeShape() {
        let open = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 0.3), CGPoint(x: 0, y: 0.3)]
        let flat = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 0.05), CGPoint(x: 0, y: 0.05)]
        XCTAssertGreaterThan(FaceReviewAnalyzer.eyeAspectRatio(open) ?? 0, 0.16)
        XCTAssertLessThan(FaceReviewAnalyzer.eyeAspectRatio(flat) ?? 1, 0.16)
    }

    func testFaceQualityIgnoresSmallAndLowConfidenceFaces() {
        XCTAssertTrue(FaceReviewAnalyzer.isReviewableFace(
            CGRect(x: 0, y: 0, width: 0.3, height: 0.3), confidence: 0.95
        ))
        XCTAssertFalse(FaceReviewAnalyzer.isReviewableFace(
            CGRect(x: 0, y: 0, width: 0.1, height: 0.1), confidence: 0.95
        ))
        XCTAssertFalse(FaceReviewAnalyzer.isReviewableFace(
            CGRect(x: 0, y: 0, width: 0.3, height: 0.3), confidence: 0.5
        ))
    }

    func testReviewSelectionAdvancesAndFallsBack() {
        let prediction = BlurPrediction(label: .sharp, sharpProbability: 1, blurredProbability: 0)
        let photos = ["A", "B", "C"].map {
            BlurCandidate(url: root.appendingPathComponent("\($0).JPG"), prediction: prediction)
        }
        XCTAssertEqual(
            ReviewSelection.preferredNextID(in: photos, selected: [photos[1].id]),
            photos[2].id
        )
        XCTAssertEqual(
            ReviewSelection.preferredNextID(in: photos, selected: [photos[2].id]),
            photos[1].id
        )
    }

    func testExposureAndResolutionClassification() {
        let dark = PhotoQualityAnalyzer.classify(
            pixelWidth: 1000,
            pixelHeight: 1000,
            luminances: [UInt8](repeating: 0, count: 100)
        )
        XCTAssertTrue(dark.contains(.underexposed))
        XCTAssertTrue(dark.contains(.lowResolution))

        let bright = PhotoQualityAnalyzer.classify(
            pixelWidth: 4000,
            pixelHeight: 3000,
            luminances: [UInt8](repeating: 255, count: 100)
        )
        XCTAssertTrue(bright.contains(.overexposed))
        XCTAssertFalse(bright.contains(.lowResolution))
    }

    func testExactDuplicateDetectionHashesOnlySameSizeCandidates() throws {
        let first = try makeFile("first.JPG")
        let second = try makeFile("second.JPG")
        let prediction = BlurPrediction(label: .sharp, sharpProbability: 1, blurredProbability: 0)
        let results = ExactDuplicateDetector.markDuplicates(in: [
            .init(url: first, prediction: prediction, byteCount: 4),
            .init(url: second, prediction: prediction, byteCount: 4)
        ])
        XCTAssertEqual(results[0].duplicateGroupID, results[1].duplicateGroupID)
        XCTAssertTrue(results.allSatisfy { $0.qualityIssues.contains(.exactDuplicate) })
    }

    func testAnalysisParallelismAdaptsToHardwareAndPower() {
        XCTAssertEqual(AnalysisPerformancePolicy.workerCount(
            logicalCores: 8,
            physicalMemory: 16 * 1_073_741_824,
            lowPowerMode: false,
            thermalState: .nominal
        ), 6)
        XCTAssertEqual(AnalysisPerformancePolicy.workerCount(
            logicalCores: 16,
            physicalMemory: 64 * 1_073_741_824,
            lowPowerMode: true,
            thermalState: .nominal
        ), 6)
        XCTAssertEqual(AnalysisPerformancePolicy.workerCount(
            logicalCores: 16,
            physicalMemory: 64 * 1_073_741_824,
            lowPowerMode: false,
            thermalState: .critical
        ), 2)
    }

    func testLastRunCacheRestoresOnlyTheSameFolder() async {
        let cache = LastRunCache(fileURL: root.appendingPathComponent("cache/last-run.json"))
        let report = ScanReport(orphanedFiles: [], inspectedFileCount: 42, errors: [])
        await cache.save(scan: report, for: root)

        let restored = await cache.load(for: root)
        XCTAssertEqual(restored?.scan?.inspectedFileCount, 42)
        let other = root.appendingPathComponent("other", isDirectory: true)
        let otherResult = await cache.load(for: other)
        XCTAssertNil(otherResult)
    }

    func testBackupCheckConfirmsIdenticalNestedCopy() async throws {
        let card = root.appendingPathComponent("CARD/DCIM/100CANON", isDirectory: true)
        let backup = root.appendingPathComponent("LIBRARY/2026/Trip", isDirectory: true)
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let source = try makeFile("IMG_9001.CR3", in: card, contents: "raw bytes")
        let copy = try makeFile("img_9001.cr3", in: backup, contents: "raw bytes")

        let report = try await BackupCheckService(cacheFileURL: root.appendingPathComponent("cache-1.json")).check(
            cameraCard: root.appendingPathComponent("CARD"),
            backupFolder: root.appendingPathComponent("LIBRARY")
        ) { _ in }

        XCTAssertEqual(report.items.count, 1)
        XCTAssertEqual(report.items.first?.sourceURL, source)
        XCTAssertEqual(report.items.first?.backupURL, copy)
        XCTAssertEqual(report.items.first?.status, .backedUp)
    }

    func testBackupCheckRejectsSameNameAndSizeWithDifferentContents() async throws {
        let card = root.appendingPathComponent("CARD", isDirectory: true)
        let backup = root.appendingPathComponent("LIBRARY", isDirectory: true)
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try makeFile("IMG_9002.JPG", in: card, contents: "AAAA")
        try makeFile("IMG_9002.JPG", in: backup, contents: "BBBB")

        let report = try await BackupCheckService(cacheFileURL: root.appendingPathComponent("cache-2.json"))
            .check(cameraCard: card, backupFolder: backup) { _ in }

        XCTAssertEqual(report.items.first?.status, .notFound)
        XCTAssertNil(report.items.first?.backupURL)
    }

    func testBackupCheckIncludesVideosAndExtensionlessFilesButSkipsSystemFiles() async throws {
        let card = root.appendingPathComponent("CARD", isDirectory: true)
        let backup = root.appendingPathComponent("LIBRARY", isDirectory: true)
        let trash = card.appendingPathComponent(".Trashes/501", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try makeFile("visible.JPEG", in: card)
        try makeFile("clip.MXF", in: card)
        try makeFile("._visible.JPEG", in: card)
        try makeFile("trashed.CR3", in: trash)
        try makeFile("CANONMSC", in: card)

        let report = try await BackupCheckService(cacheFileURL: root.appendingPathComponent("cache-3.json"))
            .check(cameraCard: card, backupFolder: backup) { _ in }

        XCTAssertEqual(
            Set(report.items.map(\.sourceURL.lastPathComponent)),
            ["CANONMSC", "clip.MXF", "visible.JPEG"]
        )
    }

    func testBackupHashCacheAvoidsRepeatReadsAndInvalidatesChangedFiles() async throws {
        let card = root.appendingPathComponent("CARD", isDirectory: true)
        let backup = root.appendingPathComponent("LIBRARY", isDirectory: true)
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let source = try makeFile("IMG_9003.CR3", in: card, contents: "AAAA")
        try makeFile("IMG_9003.CR3", in: backup, contents: "AAAA")
        let service = BackupCheckService(cacheFileURL: root.appendingPathComponent("hash-cache.json"))

        let first = try await service.check(cameraCard: card, backupFolder: backup) { _ in }
        let second = try await service.check(cameraCard: card, backupFolder: backup) { _ in }
        XCTAssertGreaterThan(first.hashedByteCount, 0)
        XCTAssertEqual(second.hashedByteCount, 0)
        XCTAssertEqual(second.cachedHashCount, 2)

        try Data("BBBB".utf8).write(to: source)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)],
            ofItemAtPath: source.path
        )
        let changed = try await service.check(cameraCard: card, backupFolder: backup) { _ in }
        XCTAssertGreaterThan(changed.hashedByteCount, 0)
        XCTAssertEqual(changed.items.first?.status, .notFound)
    }

    func testBackupCopyPreservesCardFoldersAndDoesNotOverwrite() async throws {
        let card = root.appendingPathComponent("EOS_CARD/DCIM/100CANON", isDirectory: true)
        let backup = root.appendingPathComponent("LIBRARY", isDirectory: true)
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let source = try makeFile("旅行 9004.CR3", in: card, contents: "raw data")
        let collisionFolder = backup.appendingPathComponent("EOS_CARD/DCIM/100CANON", isDirectory: true)
        try FileManager.default.createDirectory(at: collisionFolder, withIntermediateDirectories: true)
        let collision = try makeFile("旅行 9004.CR3", in: collisionFolder, contents: "keep me")
        let item = BackupCheckItem(sourceURL: source, backupURL: nil, byteCount: 8)

        let report = try await BackupCopyService().copyMissing(
            items: [item],
            cameraCard: root.appendingPathComponent("EOS_CARD"),
            backupFolder: backup
        ) { _ in }

        XCTAssertTrue(report.copiedItems.isEmpty)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(try String(contentsOf: collision), "keep me")
    }

    private func scan() async throws -> ScanReport {
        try await PhotoScanner().scan(folder: root) { _ in }
    }

    @discardableResult
    private func makeFile(_ name: String, in folder: URL? = nil, contents: String = "test") throws -> URL {
        let url = (folder ?? root).appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }
}
