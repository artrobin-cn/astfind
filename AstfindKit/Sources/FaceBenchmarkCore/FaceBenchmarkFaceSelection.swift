import AstfindFaceCore
import CoreGraphics
import CoreImage
import Foundation
import Vision

public struct FaceBenchmarkFaceRegion: Equatable, Sendable {
    public let detectionIndex: Int
    public let boundingBox: CGRect
    public let confidence: Float
    public let pixelWidth: Double
    public let pixelHeight: Double

    public init(
        detectionIndex: Int,
        boundingBox: CGRect,
        confidence: Float,
        pixelWidth: Double,
        pixelHeight: Double
    ) {
        self.detectionIndex = detectionIndex
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    public var pixelSide: Double {
        min(pixelWidth, pixelHeight)
    }
}

public struct FaceBenchmarkFaceSelectionPolicy: Equatable, Sendable {
    public var minimumFaceSidePixels: Double
    public var minimumConfidence: Float
    public var maximumFacesPerAsset: Int

    public init(
        minimumFaceSidePixels: Double = 40,
        minimumConfidence: Float = 0.3,
        maximumFacesPerAsset: Int = 20
    ) {
        self.minimumFaceSidePixels = minimumFaceSidePixels
        self.minimumConfidence = minimumConfidence
        self.maximumFacesPerAsset = maximumFacesPerAsset
    }
}

public enum FaceBenchmarkFaceSelectionError: Error, Equatable {
    case selectedFaceOutOfRange(faceCount: Int)
}

public enum FaceBenchmarkFaceSelection {
    public static func ordered(
        _ regions: [FaceBenchmarkFaceRegion]
    ) -> [FaceBenchmarkFaceRegion] {
        regions.sorted {
            let leftArea = $0.boundingBox.width * $0.boundingBox.height
            let rightArea = $1.boundingBox.width * $1.boundingBox.height
            if leftArea != rightArea { return leftArea > rightArea }
            if $0.boundingBox.minX != $1.boundingBox.minX {
                return $0.boundingBox.minX < $1.boundingBox.minX
            }
            if $0.boundingBox.minY != $1.boundingBox.minY {
                return $0.boundingBox.minY < $1.boundingBox.minY
            }
            return $0.detectionIndex < $1.detectionIndex
        }
    }

    public static func accepted(
        _ regions: [FaceBenchmarkFaceRegion],
        policy: FaceBenchmarkFaceSelectionPolicy
    ) -> [FaceBenchmarkFaceRegion] {
        guard policy.maximumFacesPerAsset > 0 else { return [] }
        return ordered(regions)
            .filter {
                $0.confidence >= policy.minimumConfidence
                    && $0.pixelSide >= policy.minimumFaceSidePixels
            }
            .prefix(policy.maximumFacesPerAsset)
            .map { $0 }
    }

    public static func selected(
        at index: Int,
        from regions: [FaceBenchmarkFaceRegion],
        policy: FaceBenchmarkFaceSelectionPolicy
    ) throws -> FaceBenchmarkFaceRegion {
        let accepted = accepted(regions, policy: policy)
        guard index >= 0, index < accepted.count else {
            throw FaceBenchmarkFaceSelectionError.selectedFaceOutOfRange(faceCount: accepted.count)
        }
        return accepted[index]
    }
}

public struct FaceBenchmarkPreprocessedFace {
    public let region: FaceBenchmarkFaceRegion
    public let alignedImage: CGImage

    public init(region: FaceBenchmarkFaceRegion, alignedImage: CGImage) {
        self.region = region
        self.alignedImage = alignedImage
    }
}

public protocol FaceBenchmarkPreprocessing {
    func process(image: CGImage) throws -> [FaceBenchmarkPreprocessedFace]
}

public struct FaceBenchmarkSelectedFace {
    public let faceCount: Int
    public let region: FaceBenchmarkFaceRegion
    public let alignedImage: CGImage

    public init(faceCount: Int, region: FaceBenchmarkFaceRegion, alignedImage: CGImage) {
        self.faceCount = faceCount
        self.region = region
        self.alignedImage = alignedImage
    }
}

public protocol FaceBenchmarkQueryPreprocessing {
    func processSelected(
        image: CGImage,
        selectedFaceIndex: Int,
        policy: FaceBenchmarkFaceSelectionPolicy
    ) throws -> FaceBenchmarkSelectedFace
}

public struct VisionFaceBatchPreprocessor: FaceBenchmarkPreprocessing, FaceBenchmarkQueryPreprocessing {
    public let policy: FaceBenchmarkFaceSelectionPolicy

    public init(policy: FaceBenchmarkFaceSelectionPolicy = FaceBenchmarkFaceSelectionPolicy()) {
        self.policy = policy
    }

    public func process(image: CGImage) throws -> [FaceBenchmarkPreprocessedFace] {
        let request = VNDetectFaceLandmarksRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let observations = request.results ?? []
        guard !observations.isEmpty else { throw FaceAlignmentError.noFace }

        let regions = observations.enumerated().map { offset, observation in
            FaceBenchmarkFaceRegion(
                detectionIndex: offset,
                boundingBox: observation.boundingBox,
                confidence: observation.confidence,
                pixelWidth: Double(observation.boundingBox.width) * Double(image.width),
                pixelHeight: Double(observation.boundingBox.height) * Double(image.height))
        }
        let regionsByIndex = Dictionary(uniqueKeysWithValues: regions.map { ($0.detectionIndex, $0) })
        let context = CIContext()
        var processed: [FaceBenchmarkPreprocessedFace] = []
        for region in FaceBenchmarkFaceSelection.ordered(regions) {
            let observation = observations[region.detectionIndex]
            guard let landmarks = observation.landmarks else { continue }
            let source = try? FaceLandmarkGeometry.fivePoints(
                imageSize: CGSize(width: image.width, height: image.height),
                boundingBox: observation.boundingBox,
                rightEye: landmarks.rightEye?.normalizedPoints ?? [],
                leftEye: landmarks.leftEye?.normalizedPoints ?? [],
                nose: landmarks.nose?.normalizedPoints ?? [],
                outerLips: landmarks.outerLips?.normalizedPoints ?? [])
            guard let source,
                  let aligned = try? FaceAligner.aligned(image: image, source: source, context: context)
            else { continue }
            let orderedRegion = regionsByIndex[region.detectionIndex] ?? region
            processed.append(FaceBenchmarkPreprocessedFace(
                region: orderedRegion,
                alignedImage: aligned))
        }
        guard !processed.isEmpty else { throw FaceAlignmentError.missingLandmarks }
        return processed
    }

    public func processAccepted(image: CGImage) throws -> [FaceBenchmarkPreprocessedFace] {
        let processed = try process(image: image)
        let accepted = Set(
            FaceBenchmarkFaceSelection.accepted(processed.map(\.region), policy: policy)
                .map(\.detectionIndex))
        return processed.filter { accepted.contains($0.region.detectionIndex) }
    }

    public func processSelected(
        image: CGImage,
        selectedFaceIndex: Int,
        policy: FaceBenchmarkFaceSelectionPolicy
    ) throws -> FaceBenchmarkSelectedFace {
        let request = VNDetectFaceLandmarksRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let observations = request.results ?? []
        guard !observations.isEmpty else { throw FaceAlignmentError.noFace }
        let regions = observations.enumerated().map { offset, observation in
            FaceBenchmarkFaceRegion(
                detectionIndex: offset,
                boundingBox: observation.boundingBox,
                confidence: observation.confidence,
                pixelWidth: Double(observation.boundingBox.width) * Double(image.width),
                pixelHeight: Double(observation.boundingBox.height) * Double(image.height))
        }
        let accepted = FaceBenchmarkFaceSelection.accepted(regions, policy: policy)
        guard selectedFaceIndex >= 0, selectedFaceIndex < accepted.count else {
            throw FaceBenchmarkFaceSelectionError.selectedFaceOutOfRange(faceCount: accepted.count)
        }
        let region = accepted[selectedFaceIndex]
        let observation = observations[region.detectionIndex]
        guard let landmarks = observation.landmarks else {
            throw FaceAlignmentError.missingLandmarks
        }
        let source = try FaceLandmarkGeometry.fivePoints(
            imageSize: CGSize(width: image.width, height: image.height),
            boundingBox: observation.boundingBox,
            rightEye: landmarks.rightEye?.normalizedPoints ?? [],
            leftEye: landmarks.leftEye?.normalizedPoints ?? [],
            nose: landmarks.nose?.normalizedPoints ?? [],
            outerLips: landmarks.outerLips?.normalizedPoints ?? [])
        let aligned = try FaceAligner.aligned(
            image: image,
            source: source,
            context: CIContext())
        return FaceBenchmarkSelectedFace(
            faceCount: accepted.count,
            region: region,
            alignedImage: aligned)
    }
}
