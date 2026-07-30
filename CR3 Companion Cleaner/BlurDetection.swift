import CoreML
import CryptoKit
import Foundation
import ImageIO
import Vision

private final class CachedThumbnail: NSObject, @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

enum ThumbnailRequestPriority: Int, Sendable {
    case standard
    case nearby
    case active

    var queuePriority: Operation.QueuePriority {
        switch self {
        case .standard: .normal
        case .nearby: .high
        case .active: .veryHigh
        }
    }
}

private final class PendingThumbnailRequest: @unchecked Sendable {
    let task: Task<CGImage?, Never>
    let operation: BlockOperation
    let urlPath: String
    var priority: ThumbnailRequestPriority

    init(
        task: Task<CGImage?, Never>,
        operation: BlockOperation,
        urlPath: String,
        priority: ThumbnailRequestPriority
    ) {
        self.task = task
        self.operation = operation
        self.urlPath = urlPath
        self.priority = priority
    }
}

/// Coalesces duplicate decodes from the grid, main preview, and AI analyzers.
/// The bounded native queue prevents a fast scroll from creating an I/O storm.
actor ImageThumbnailCache {
    static let shared = ImageThumbnailCache()

    private nonisolated static let decodeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "CR3CompanionCleaner.ThumbnailDecode"
        queue.qualityOfService = .userInitiated
        let info = ProcessInfo.processInfo
        queue.maxConcurrentOperationCount = info.isLowPowerModeEnabled || info.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
            ? 2 : min(4, max(2, info.activeProcessorCount / 4))
        return queue
    }()

    private let cache = NSCache<NSString, CachedThumbnail>()
    private var pending: [String: PendingThumbnailRequest] = [:]
    private var focusedURLPath: String?
    private var focusGeneration = 0

    init() {
        let memory = ProcessInfo.processInfo.physicalMemory
        let minimum = UInt64(64 * 1_024 * 1_024)
        let maximum = UInt64(256 * 1_024 * 1_024)
        cache.totalCostLimit = Int(min(maximum, max(minimum, memory / 64)))
        cache.countLimit = 600
    }

    func image(
        for url: URL,
        maxPixel: Int,
        priority: ThumbnailRequestPriority = .standard,
        focusGeneration requestGeneration: Int? = nil
    ) async -> CGImage? {
        if let requestGeneration, requestGeneration != focusGeneration { return nil }
        let urlPath = url.standardizedFileURL.path
        if priority == .active { focus(onPath: urlPath) }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = "\(urlPath)|\(values?.fileSize ?? 0)|\(values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0)|\(maxPixel)"
        if let cached = cache.object(forKey: key as NSString) { return cached.image }
        if let request = pending[key] {
            if priority.rawValue > request.priority.rawValue {
                request.priority = priority
                request.operation.queuePriority = priority.queuePriority
            }
            return await request.task.value
        }

        let operation = BlockOperation()
        operation.queuePriority = priority.queuePriority
        let task = Task.detached(priority: .utility) { () -> CGImage? in
            await withCheckedContinuation { continuation in
                operation.addExecutionBlock {
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                        kCGImageSourceShouldCacheImmediately: false
                    ] as CFDictionary)
                    continuation.resume(returning: image)
                }
                Self.decodeQueue.addOperation(operation)
            }
        }
        pending[key] = PendingThumbnailRequest(
            task: task,
            operation: operation,
            urlPath: urlPath,
            priority: priority
        )
        let image = await task.value
        pending[key] = nil
        if let image {
            cache.setObject(CachedThumbnail(image), forKey: key as NSString, cost: image.bytesPerRow * image.height)
        }
        return image
    }

    @discardableResult
    func focus(on url: URL) -> Int {
        focus(onPath: url.standardizedFileURL.path)
        return focusGeneration
    }

    private func focus(onPath path: String) {
        guard focusedURLPath != path else { return }
        focusedURLPath = path
        focusGeneration &+= 1
        for request in pending.values
            where request.urlPath != path && request.priority != .standard {
            request.priority = .standard
            request.operation.queuePriority = ThumbnailRequestPriority.standard.queuePriority
        }
    }
}

enum BlurLabel: String, Hashable, Sendable, Codable {
    case sharp
    case blurred
    case uncertain
}

struct BlurPrediction: Hashable, Sendable, Codable {
    let label: BlurLabel
    let sharpProbability: Double
    let blurredProbability: Double

    var confidence: Double { max(sharpProbability, blurredProbability) }
}

struct BlurCandidate: Identifiable, Hashable, Sendable, Codable {
    let url: URL
    let prediction: BlurPrediction
    let faceIssues: [FaceReviewIssue]
    let qualityIssues: [PhotoQualityIssue]
    let captureDate: Date
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int64
    let burstGroupID: Int?
    let burstRank: Int?
    let duplicateGroupID: Int?

    init(
        url: URL,
        prediction: BlurPrediction,
        faceIssues: [FaceReviewIssue] = [],
        qualityIssues: [PhotoQualityIssue] = [],
        captureDate: Date = .distantPast,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0,
        byteCount: Int64 = 0,
        burstGroupID: Int? = nil,
        burstRank: Int? = nil,
        duplicateGroupID: Int? = nil
    ) {
        self.url = url
        self.prediction = prediction
        self.faceIssues = faceIssues
        self.qualityIssues = qualityIssues
        self.captureDate = captureDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteCount = byteCount
        self.burstGroupID = burstGroupID
        self.burstRank = burstRank
        self.duplicateGroupID = duplicateGroupID
    }

    var id: URL { url }
    var needsReview: Bool {
        prediction.label != .sharp || !faceIssues.isEmpty || !qualityIssues.isEmpty
    }

    var burstSelectionScore: Double {
        var score = prediction.sharpProbability
        if faceIssues.contains(.possibleBlink) { score -= 0.45 }
        if faceIssues.contains(.lowFaceQuality) { score -= 0.25 }
        if qualityIssues.contains(.underexposed) || qualityIssues.contains(.overexposed) { score -= 0.20 }
        if qualityIssues.contains(.lowResolution) { score -= 0.15 }
        return score
    }

    func grouped(as groupID: Int?, rank: Int?) -> Self {
        .init(
            url: url,
            prediction: prediction,
            faceIssues: faceIssues,
            qualityIssues: qualityIssues,
            captureDate: captureDate,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            byteCount: byteCount,
            burstGroupID: groupID,
            burstRank: rank,
            duplicateGroupID: duplicateGroupID
        )
    }

    func markedDuplicate(groupID: Int) -> Self {
        .init(
            url: url,
            prediction: prediction,
            faceIssues: faceIssues,
            qualityIssues: qualityIssues + (qualityIssues.contains(.exactDuplicate) ? [] : [.exactDuplicate]),
            captureDate: captureDate,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            byteCount: byteCount,
            burstGroupID: burstGroupID,
            burstRank: burstRank,
            duplicateGroupID: groupID
        )
    }
}

enum FaceReviewIssue: String, Hashable, Sendable, Codable {
    case possibleBlink = "Possible closed eye / blink"
    case lowFaceQuality = "Low face / expression quality"
}

enum PhotoQualityIssue: String, Hashable, Sendable, Codable {
    case underexposed = "Severely underexposed"
    case overexposed = "Severely overexposed"
    case lowResolution = "Low resolution (<2 MP)"
    case exactDuplicate = "Exact duplicate"
}

struct BlurAnalysisReport: Sendable, Codable {
    let candidates: [BlurCandidate]
    let burstPhotos: [BlurCandidate]
    let burstGroupCount: Int
    let analyzedCount: Int
    let errors: [FileOperationFailure]
}

struct AnalysisPerformancePolicy: Sendable {
    let workerCount: Int

    static var current: Self {
        let info = ProcessInfo.processInfo
        return .init(workerCount: workerCount(
            logicalCores: info.activeProcessorCount,
            physicalMemory: info.physicalMemory,
            lowPowerMode: info.isLowPowerModeEnabled,
            thermalState: info.thermalState
        ))
    }

    static func workerCount(
        logicalCores: Int,
        physicalMemory: UInt64,
        lowPowerMode: Bool,
        thermalState: ProcessInfo.ThermalState
    ) -> Int {
        let memoryGiB = max(1, Int(physicalMemory / 1_073_741_824))
        var workers = min(12, max(2, logicalCores - 2), max(2, memoryGiB / 2))
        if lowPowerMode || thermalState == .serious { workers = max(2, workers / 2) }
        if thermalState == .critical { workers = 2 }
        return workers
    }
}

/// The only configuration that normally changes when swapping compatible models.
struct BlurModelConfiguration: Sendable {
    let resourceName: String
    let outputName: String
    let confidenceThreshold: Double
    let blurredProbabilityThreshold: Double

    static let bundled = BlurModelConfiguration(
        resourceName: "BlurDetector",
        outputName: "probabilities",
        confidenceThreshold: 0.60,
        blurredProbabilityThreshold: 0.50
    )

    func prediction(sharp: Double, blurred: Double) -> BlurPrediction {
        let confidence = max(sharp, blurred)
        let label: BlurLabel = confidence < confidenceThreshold
            ? .uncertain
            : (blurred >= blurredProbabilityThreshold ? .blurred : .sharp)
        return BlurPrediction(label: label, sharpProbability: sharp, blurredProbability: blurred)
    }
}

/// Model adapters conform to this small boundary; scanning and UI do not know model details.
protocol BlurDetecting: Sendable {
    func predict(imageAt url: URL) async throws -> BlurPrediction
}

protocol FaceReviewAnalyzing: Sendable {
    func analyze(imageAt url: URL) async throws -> [FaceReviewIssue]
}

protocol PhotoQualityAnalyzing: Sendable {
    func analyze(imageAt url: URL) async throws -> PhotoQualityResult
}

enum BlurDetectionError: LocalizedError {
    case modelMissing(String)
    case imageUnreadable(URL)
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case .modelMissing(let name):
            return "The local blur model \(name).mlmodelc is missing from the app bundle."
        case .imageUnreadable(let url):
            return "The image could not be decoded: \(url.path)"
        case .invalidOutput(let name):
            return "The local blur model returned an invalid \(name) output."
        }
    }
}

/// Adapter for any Core ML image model that returns [sharp, blurred] probabilities.
final class CoreMLBlurDetector: @unchecked Sendable, BlurDetecting {
    private let configuration: BlurModelConfiguration
    private let visionModel: VNCoreMLModel

    init(configuration: BlurModelConfiguration = .bundled) throws {
        self.configuration = configuration
        guard let url = Bundle.main.url(
            forResource: configuration.resourceName,
            withExtension: "mlmodelc"
        ) else {
            throw BlurDetectionError.modelMissing(configuration.resourceName)
        }
        let modelConfiguration = MLModelConfiguration()
        modelConfiguration.computeUnits = .all
        visionModel = try VNCoreMLModel(for: MLModel(contentsOf: url, configuration: modelConfiguration))
    }

    func predict(imageAt url: URL) async throws -> BlurPrediction {
        guard let image = await ImageThumbnailCache.shared.image(for: url, maxPixel: 1024) else {
            throw BlurDetectionError.imageUnreadable(url)
        }

        let request = VNCoreMLRequest(model: visionModel)
        request.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(cgImage: image).perform([request])

        let observations = request.results?.compactMap { $0 as? VNCoreMLFeatureValueObservation }
        guard let probabilities = observations?
            .first(where: { $0.featureName == configuration.outputName })?
            .featureValue.multiArrayValue,
              probabilities.count >= 2 else {
            throw BlurDetectionError.invalidOutput(configuration.outputName)
        }

        return configuration.prediction(
            sharp: probabilities[0].doubleValue,
            blurred: probabilities[1].doubleValue
        )
    }
}

private enum PhotoAnalysisOutcome: Sendable {
    case success(BlurCandidate)
    case failure(FileOperationFailure)
}

/// Recursively analyzes JPG/JPEG previews. It never modifies any photo.
actor BlurAnalysisService {
    private let detector: any BlurDetecting
    private let faceAnalyzer: any FaceReviewAnalyzing
    private let qualityAnalyzer: any PhotoQualityAnalyzing

    init(
        detector: any BlurDetecting,
        faceAnalyzer: any FaceReviewAnalyzing = FaceReviewAnalyzer(),
        qualityAnalyzer: any PhotoQualityAnalyzing = PhotoQualityAnalyzer()
    ) {
        self.detector = detector
        self.faceAnalyzer = faceAnalyzer
        self.qualityAnalyzer = qualityAnalyzer
    }

    func analyze(
        folder root: URL,
        workerCount: Int = AnalysisPerformancePolicy.current.workerCount,
        progress: @escaping @Sendable (Int, String) -> Void
    ) async throws -> BlurAnalysisReport {
        let discovery = try discoverImages(in: root)
        var errors = discovery.errors
        var photos: [BlurCandidate] = []
        var analyzed = 0
        let detector = self.detector
        let faceAnalyzer = self.faceAnalyzer
        let qualityAnalyzer = self.qualityAnalyzer
        let workerCount = max(1, workerCount)

        try await withThrowingTaskGroup(of: PhotoAnalysisOutcome.self) { group in
            var iterator = discovery.urls.makeIterator()
            for _ in 0..<workerCount {
                guard let url = iterator.next() else { break }
                group.addTask {
                    try await Self.analyzePhoto(url, detector: detector, faceAnalyzer: faceAnalyzer, qualityAnalyzer: qualityAnalyzer)
                }
            }

            while let outcome = try await group.next() {
                switch outcome {
                case .success(let candidate):
                    photos.append(candidate)
                    analyzed += 1
                    progress(analyzed, candidate.url.lastPathComponent)
                case .failure(let failure):
                    errors.append(failure)
                }
                if let url = iterator.next() {
                    group.addTask {
                        try await Self.analyzePhoto(url, detector: detector, faceAnalyzer: faceAnalyzer, qualityAnalyzer: qualityAnalyzer)
                    }
                }
            }
        }

        progress(analyzed, "Checking exact duplicates…")
        let duplicatesMarked = ExactDuplicateDetector.markDuplicates(in: photos)
        let grouped = BurstGrouping.assignGroups(to: duplicatesMarked)
        return BlurAnalysisReport(
            candidates: grouped.photos.filter(\.needsReview).sorted {
                $0.prediction.blurredProbability > $1.prediction.blurredProbability
            },
            burstPhotos: grouped.photos.filter { $0.burstGroupID != nil }.sorted {
                ($0.burstGroupID ?? 0, $0.captureDate) < ($1.burstGroupID ?? 0, $1.captureDate)
            },
            burstGroupCount: grouped.groupCount,
            analyzedCount: analyzed,
            errors: errors
        )
    }

    private nonisolated static func analyzePhoto(
        _ url: URL,
        detector: any BlurDetecting,
        faceAnalyzer: any FaceReviewAnalyzing,
        qualityAnalyzer: any PhotoQualityAnalyzing
    ) async throws -> PhotoAnalysisOutcome {
        try Task.checkCancellation()
        do {
            async let prediction = detector.predict(imageAt: url)
            async let faceIssues = faceAnalyzer.analyze(imageAt: url)
            async let quality = qualityAnalyzer.analyze(imageAt: url)
            let qualityResult = try await quality
            return .success(.init(
                url: url,
                prediction: try await prediction,
                faceIssues: try await faceIssues,
                qualityIssues: qualityResult.issues,
                captureDate: PhotoMetadata.captureDate(for: url),
                pixelWidth: qualityResult.pixelWidth,
                pixelHeight: qualityResult.pixelHeight,
                byteCount: qualityResult.byteCount
            ))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failure(.init(url: url, reason: error.localizedDescription))
        }
    }

    private func discoverImages(in root: URL) throws -> (
        urls: [URL],
        errors: [FileOperationFailure]
    ) {
        var errors: [FileOperationFailure] = []
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
            options: [.skipsHiddenFiles],
            errorHandler: { url, error in
                errors.append(.init(url: url, reason: error.localizedDescription))
                return true
            }
        ) else {
            throw ScannerError.cannotEnumerate(root)
        }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            if url.pathComponents.contains(where: { $0 == ".Trash" || $0 == ".Trashes" }) {
                enumerator.skipDescendants()
                continue
            }
            let ext = url.pathExtension.lowercased()
            guard ext == "jpg" || ext == "jpeg" else { continue }

            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isHiddenKey])
                guard values.isRegularFile == true, values.isHidden != true,
                      !url.lastPathComponent.hasPrefix("._") else { continue }
                urls.append(url)
            } catch {
                errors.append(.init(url: url, reason: error.localizedDescription))
            }
        }
        return (urls, errors)
    }
}

/// Uses Apple Vision only; results are review hints and never trigger deletion.
struct FaceReviewAnalyzer: FaceReviewAnalyzing {
    struct Configuration: Sendable {
        let minimumFaceArea: CGFloat
        let minimumConfidence: VNConfidence
        let minimumLandmarkConfidence: VNConfidence
        let lowQualityThreshold: Float

        static let conservative = Configuration(
            minimumFaceArea: 0.04,
            minimumConfidence: 0.90,
            minimumLandmarkConfidence: 0.80,
            lowQualityThreshold: 0.20
        )
    }

    private let configuration: Configuration

    init(configuration: Configuration = .conservative) {
        self.configuration = configuration
    }

    func analyze(imageAt url: URL) async throws -> [FaceReviewIssue] {
        guard let image = await ImageThumbnailCache.shared.image(for: url, maxPixel: 1024) else {
            throw BlurDetectionError.imageUnreadable(url)
        }

        let landmarksRequest = VNDetectFaceLandmarksRequest()
        let qualityRequest = VNDetectFaceCaptureQualityRequest()
        try VNImageRequestHandler(cgImage: image).perform([landmarksRequest, qualityRequest])

        let faces = (landmarksRequest.results ?? []).filter {
            Self.isReviewableFace($0.boundingBox, confidence: $0.confidence, configuration: configuration)
        }
        var issues: [FaceReviewIssue] = []
        if faces.contains(where: { face in
            guard let landmarks = face.landmarks,
                  landmarks.confidence >= configuration.minimumLandmarkConfidence else { return false }
            return Self.eyeLooksClosed(landmarks.leftEye) || Self.eyeLooksClosed(landmarks.rightEye)
        }) {
            issues.append(.possibleBlink)
        }
        if (qualityRequest.results ?? []).contains(where: {
            Self.isReviewableFace($0.boundingBox, confidence: $0.confidence, configuration: configuration)
                && ($0.faceCaptureQuality ?? 1) < configuration.lowQualityThreshold
        }) {
            issues.append(.lowFaceQuality)
        }
        return issues
    }

    static func isReviewableFace(
        _ box: CGRect,
        confidence: VNConfidence,
        configuration: Configuration = .conservative
    ) -> Bool {
        box.width * box.height >= configuration.minimumFaceArea
            && confidence >= configuration.minimumConfidence
    }

    // ponytail: Vision has no closed-eye label; replace this aspect-ratio heuristic
    // with a dedicated model if false positives become material.
    static func eyeAspectRatio(_ points: [CGPoint]) -> CGFloat? {
        guard points.count >= 4,
              let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max(),
              maxX > minX else { return nil }
        return (maxY - minY) / (maxX - minX)
    }

    private static func eyeLooksClosed(_ region: VNFaceLandmarkRegion2D?) -> Bool {
        guard let region else { return false }
        let points = (0..<region.pointCount).map { region.normalizedPoints[$0] }
        return (eyeAspectRatio(points) ?? 1) < 0.16
    }
}

struct PhotoQualityResult: Sendable {
    let issues: [PhotoQualityIssue]
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int64
}

struct PhotoQualityAnalyzer: PhotoQualityAnalyzing {
    func analyze(imageAt url: URL) async throws -> PhotoQualityResult {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int,
              let image = await ImageThumbnailCache.shared.image(for: url, maxPixel: 256) else {
            throw BlurDetectionError.imageUnreadable(url)
        }

        let width = image.width
        let height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &rgba,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw BlurDetectionError.imageUnreadable(url)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var luminances: [UInt8] = []
        luminances.reserveCapacity(width * height)
        for index in stride(from: 0, to: rgba.count, by: 4) {
            let luminance = (54 * Int(rgba[index]) + 183 * Int(rgba[index + 1]) + 19 * Int(rgba[index + 2])) >> 8
            luminances.append(UInt8(luminance))
        }
        let byteCount = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map(Int64.init) ?? 0
        return .init(
            issues: Self.classify(pixelWidth: pixelWidth, pixelHeight: pixelHeight, luminances: luminances),
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            byteCount: byteCount
        )
    }

    static func classify(
        pixelWidth: Int,
        pixelHeight: Int,
        luminances: [UInt8]
    ) -> [PhotoQualityIssue] {
        var issues: [PhotoQualityIssue] = []
        if pixelWidth * pixelHeight < 2_000_000 { issues.append(.lowResolution) }
        guard !luminances.isEmpty else { return issues }

        let count = Double(luminances.count)
        let mean = Double(luminances.reduce(0) { $0 + Int($1) }) / count
        let darkFraction = Double(luminances.count(where: { $0 <= 12 })) / count
        let brightFraction = Double(luminances.count(where: { $0 >= 245 })) / count
        if mean < 55, darkFraction > 0.55 { issues.append(.underexposed) }
        if mean > 205, brightFraction > 0.45 { issues.append(.overexposed) }
        return issues
    }
}

enum PhotoMetadata {
    static func captureDate(for url: URL) -> Date {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let value = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            if var date = formatter.date(from: value) {
                if let digits = exif[kCGImagePropertyExifSubsecTimeOriginal] as? String,
                   let fraction = Double("0." + digits.filter(\.isNumber)) {
                    date.addTimeInterval(fraction)
                }
                return date
            }
        }
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    static func details(for url: URL) -> PhotoEXIFMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return .init(rows: [])
        }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let auxiliary = properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        var rows: [PhotoMetadataRow] = []

        let camera = [
            tiff[kCGImagePropertyTIFFMake] as? String,
            tiff[kCGImagePropertyTIFFModel] as? String
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !camera.isEmpty { rows.append(.init(label: "Camera", value: camera)) }
        if let lens = auxiliary[kCGImagePropertyExifAuxLensModel] as? String, !lens.isEmpty {
            rows.append(.init(label: "Lens", value: lens))
        }
        if let exposure = number(in: exif, key: kCGImagePropertyExifExposureTime), exposure > 0 {
            rows.append(.init(label: "Shutter", value: formatExposureTime(exposure)))
        }
        if let aperture = number(in: exif, key: kCGImagePropertyExifFNumber), aperture > 0 {
            rows.append(.init(label: "Aperture", value: String(format: "f/%.1f", aperture)))
        }
        if let iso = number(in: exif, key: kCGImagePropertyExifISOSpeedRatings) {
            rows.append(.init(label: "ISO", value: String(Int(iso.rounded()))))
        }
        if let focalLength = number(in: exif, key: kCGImagePropertyExifFocalLength) {
            rows.append(.init(label: "Focal Length", value: String(format: "%.0f mm", focalLength)))
        }
        if let bias = number(in: exif, key: kCGImagePropertyExifExposureBiasValue) {
            rows.append(.init(label: "Exposure Bias", value: String(format: "%+.1f EV", bias)))
        }
        if let metering = number(in: exif, key: kCGImagePropertyExifMeteringMode) {
            rows.append(.init(label: "Metering", value: meteringMode(Int(metering))))
        }
        if let whiteBalance = number(in: exif, key: kCGImagePropertyExifWhiteBalance) {
            rows.append(.init(label: "White Balance", value: whiteBalance == 0 ? "Auto" : "Manual"))
        }
        if let flash = number(in: exif, key: kCGImagePropertyExifFlash) {
            rows.append(.init(label: "Flash", value: Int(flash) & 1 == 1 ? "Fired" : "Did not fire"))
        }
        if let latitude = number(in: gps, key: kCGImagePropertyGPSLatitude),
           let longitude = number(in: gps, key: kCGImagePropertyGPSLongitude) {
            let formatted = formatGPS(
                latitude: latitude,
                longitude: longitude,
                latitudeRef: gps[kCGImagePropertyGPSLatitudeRef] as? String,
                longitudeRef: gps[kCGImagePropertyGPSLongitudeRef] as? String
            )
            rows.append(.init(
                label: "GPS",
                value: formatted
            ))
        }
        if var altitude = number(in: gps, key: kCGImagePropertyGPSAltitude) {
            if number(in: gps, key: kCGImagePropertyGPSAltitudeRef) == 1 { altitude = -altitude }
            rows.append(.init(label: "Altitude", value: String(format: "%.1f m", altitude)))
        }
        if let date = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            rows.append(.init(label: "Captured", value: date))
        }
        if let width = number(in: properties, key: kCGImagePropertyPixelWidth),
           let height = number(in: properties, key: kCGImagePropertyPixelHeight) {
            rows.append(.init(label: "Dimensions", value: "\(Int(width)) × \(Int(height))"))
        }
        return .init(rows: rows)
    }

    static func formatExposureTime(_ seconds: Double) -> String {
        if seconds >= 0.5 { return String(format: seconds >= 10 ? "%.0f s" : "%.1f s", seconds) }
        return "1/\(max(1, Int((1 / seconds).rounded()))) s"
    }

    static func timelineSampleIndices(count: Int) -> [Int] {
        guard count > 0 else { return [] }
        var seen = Set<Int>()
        return [0.0, 0.25, 0.5, 0.75, 1.0].compactMap { fraction in
            let index = Int((Double(count - 1) * fraction).rounded())
            return seen.insert(index).inserted ? index : nil
        }
    }

    static func formatGPS(
        latitude: Double,
        longitude: Double,
        latitudeRef: String?,
        longitudeRef: String?
    ) -> String {
        let signedLatitude = latitudeRef?.uppercased() == "S" ? -latitude : latitude
        let signedLongitude = longitudeRef?.uppercased() == "W" ? -longitude : longitude
        return String(format: "%.6f, %.6f", signedLatitude, signedLongitude)
    }

    private static func number(in dictionary: [CFString: Any], key: CFString) -> Double? {
        if let number = dictionary[key] as? NSNumber { return number.doubleValue }
        if let numbers = dictionary[key] as? [NSNumber] { return numbers.first?.doubleValue }
        return nil
    }

    private static func meteringMode(_ value: Int) -> String {
        switch value {
        case 1: "Average"
        case 2: "Center-weighted"
        case 3: "Spot"
        case 5: "Pattern"
        case 6: "Partial"
        default: "Mode \(value)"
        }
    }
}

struct PhotoMetadataRow: Identifiable, Sendable {
    let label: String
    let value: String
    var id: String { label }
}

struct PhotoEXIFMetadata: Sendable {
    let rows: [PhotoMetadataRow]
}

private final class CachedEXIFMetadata: NSObject, @unchecked Sendable {
    let metadata: PhotoEXIFMetadata
    init(_ metadata: PhotoEXIFMetadata) { self.metadata = metadata }
}

actor PhotoEXIFMetadataCache {
    static let shared = PhotoEXIFMetadataCache()
    private let cache = NSCache<NSString, CachedEXIFMetadata>()

    init() {
        cache.countLimit = 200
    }

    func metadata(for url: URL) async -> PhotoEXIFMetadata {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = "\(url.standardizedFileURL.path)|\(values?.fileSize ?? 0)|\(values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0)"
        if let cached = cache.object(forKey: key as NSString) { return cached.metadata }
        let metadata = await Task.detached(priority: .userInitiated) {
            PhotoMetadata.details(for: url)
        }.value
        cache.setObject(CachedEXIFMetadata(metadata), forKey: key as NSString)
        return metadata
    }
}

enum ExactDuplicateDetector {
    static func markDuplicates(in photos: [BlurCandidate]) -> [BlurCandidate] {
        var groupByURL: [URL: Int] = [:]
        var nextGroup = 1
        let sameSizeGroups = Dictionary(grouping: photos.filter { $0.byteCount > 0 }, by: \.byteCount)

        for size in sameSizeGroups.keys.sorted() {
            let candidates = sameSizeGroups[size, default: []]
            guard candidates.count > 1 else { continue }
            var byDigest: [Data: [BlurCandidate]] = [:]
            for candidate in candidates {
                guard let digest = autoreleasepool(invoking: { () -> Data? in
                    guard let data = try? Data(contentsOf: candidate.url, options: .mappedIfSafe) else { return nil }
                    return Data(SHA256.hash(data: data))
                }) else { continue }
                byDigest[digest, default: []].append(candidate)
            }
            for duplicates in byDigest.values
                .filter({ $0.count > 1 })
                .sorted(by: { $0[0].url.path < $1[0].url.path }) {
                for photo in duplicates { groupByURL[photo.url] = nextGroup }
                nextGroup += 1
            }
        }
        return photos.map { photo in
            guard let groupID = groupByURL[photo.url] else { return photo }
            return photo.markedDuplicate(groupID: groupID)
        }
    }
}

enum BurstGrouping {
    static func assignGroups(
        to photos: [BlurCandidate],
        maximumGap: TimeInterval = 1.5
    ) -> (photos: [BlurCandidate], groupCount: Int) {
        var groupByURL: [URL: Int] = [:]
        var nextGroup = 1
        let folders = Dictionary(grouping: photos) { $0.url.deletingLastPathComponent() }

        for folder in folders.keys.sorted(by: { $0.path < $1.path }) {
            let sorted = folders[folder, default: []].sorted { $0.captureDate < $1.captureDate }
            var run: [BlurCandidate] = []

            func finishRun() {
                guard run.count > 1 else { run.removeAll(); return }
                for photo in run { groupByURL[photo.url] = nextGroup }
                nextGroup += 1
                run.removeAll()
            }

            for photo in sorted {
                if let previous = run.last,
                   photo.captureDate.timeIntervalSince(previous.captureDate) > maximumGap {
                    finishRun()
                }
                run.append(photo)
            }
            finishRun()
        }

        var rankByURL: [URL: Int] = [:]
        for groupID in 1..<nextGroup {
            let ranked = photos
                .filter { groupByURL[$0.url] == groupID }
                .sorted {
                    if $0.burstSelectionScore == $1.burstSelectionScore {
                        return $0.url.path < $1.url.path
                    }
                    return $0.burstSelectionScore > $1.burstSelectionScore
                }
            for (index, photo) in ranked.enumerated() { rankByURL[photo.url] = index + 1 }
        }
        return (
            photos.map {
                $0.grouped(as: groupByURL[$0.url], rank: rankByURL[$0.url])
            },
            groupCount: nextGroup - 1
        )
    }
}

enum ReviewSelection {
    static func preferredNextID(
        in photos: [BlurCandidate],
        selected: Set<BlurCandidate.ID>
    ) -> BlurCandidate.ID? {
        let indices = photos.indices.filter { selected.contains(photos[$0].id) }
        guard let first = indices.first, let last = indices.last else { return nil }
        let following = photos.indices.dropFirst(last + 1)
            .first { !selected.contains(photos[$0].id) }
        let preceding = photos.indices[..<first].reversed()
            .first { !selected.contains(photos[$0].id) }
        return (following ?? preceding).map { photos[$0].id }
    }
}
