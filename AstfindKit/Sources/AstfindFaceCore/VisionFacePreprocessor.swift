import CoreGraphics
import CoreImage
import Vision

public struct FacePreprocessResult: Sendable {
    public let faceCount: Int
    public let selectedFaceIndex: Int
    public let alignedImage: CGImage
    /// Vision 归一化坐标（原点左下）；生产索引落库用，benchmark 可忽略。
    public let boundingBox: CGRect?
    public let quality: Double?

    public init(faceCount: Int, selectedFaceIndex: Int, alignedImage: CGImage,
                boundingBox: CGRect? = nil, quality: Double? = nil) {
        self.faceCount = faceCount
        self.selectedFaceIndex = selectedFaceIndex
        self.alignedImage = alignedImage
        self.boundingBox = boundingBox
        self.quality = quality
    }
}

/// 参考图多脸候选：按面积降序，index 为稳定选择序号。
public struct FaceCandidate: Sendable {
    public let index: Int
    public let alignedImage: CGImage
    public let boundingBox: CGRect
    public let quality: Double

    public init(index: Int, alignedImage: CGImage, boundingBox: CGRect, quality: Double) {
        self.index = index
        self.alignedImage = alignedImage
        self.boundingBox = boundingBox
        self.quality = quality
    }
}

public enum FaceAligner {
    public static func aligned(
        image: CGImage,
        source: FaceFivePoints,
        context: CIContext
    ) throws -> CGImage {
        let height = Double(image.height)
        let sourceCI = try FaceFivePoints(points: source.points.map {
            FacePoint(x: $0.x, y: height - $0.y)
        })
        let destinationCI = try FaceFivePoints(points: FaceFivePoints.arcFaceDestination.points.map {
            FacePoint(x: $0.x, y: 112 - $0.y)
        })
        let transform = try FaceSimilarityTransform(source: sourceCI, destination: destinationCI)
        let affine = CGAffineTransform(
            a: transform.a,
            b: transform.b,
            c: -transform.b,
            d: transform.a,
            tx: transform.tx,
            ty: transform.ty)
        let output = CIImage(cgImage: image).transformed(by: affine)
        guard let image = context.createCGImage(output, from: CGRect(x: 0, y: 0, width: 112, height: 112)) else {
            throw FaceAlignmentError.imageRenderingFailed
        }
        return image
    }
}

public struct VisionFacePreprocessor: Sendable {
    public init() {}

    /// 检测全部可用人脸并按面积降序对齐；合影 v1 用它提供候选主脸。
    public func candidates(image: CGImage) throws -> [FaceCandidate] {
        let request = VNDetectFaceLandmarksRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let observations = (request.results ?? []).enumerated()
            .sorted {
                let left = $0.element.boundingBox.width * $0.element.boundingBox.height
                let right = $1.element.boundingBox.width * $1.element.boundingBox.height
                if left != right { return left > right }
                return $0.offset < $1.offset
            }
            .map(\.element)
        guard !observations.isEmpty else { throw FaceAlignmentError.noFace }
        var result: [FaceCandidate] = []
        for (index, observation) in observations.enumerated() {
            guard let landmarks = observation.landmarks else { continue }
            let source: FaceFivePoints
            do {
                source = try FaceLandmarkGeometry.fivePoints(
                    imageSize: CGSize(width: image.width, height: image.height),
                    boundingBox: observation.boundingBox,
                    rightEye: landmarks.rightEye?.normalizedPoints ?? [],
                    leftEye: landmarks.leftEye?.normalizedPoints ?? [],
                    nose: landmarks.nose?.normalizedPoints ?? [],
                    outerLips: landmarks.outerLips?.normalizedPoints ?? [])
                let aligned = try FaceAligner.aligned(image: image, source: source, context: CIContext())
                result.append(FaceCandidate(
                    index: index, alignedImage: aligned,
                    boundingBox: observation.boundingBox,
                    quality: Double(observation.confidence)))
            } catch {
                continue
            }
        }
        guard !result.isEmpty else { throw FaceAlignmentError.missingLandmarks }
        return result
    }

    public func process(image: CGImage) throws -> FacePreprocessResult {
        let request = VNDetectFaceLandmarksRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let observations = request.results ?? []
        guard let selected = observations.enumerated().max(by: {
            $0.element.boundingBox.width * $0.element.boundingBox.height
                < $1.element.boundingBox.width * $1.element.boundingBox.height
        }) else {
            throw FaceAlignmentError.noFace
        }
        let observation = selected.element
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
        return FacePreprocessResult(
            faceCount: observations.count,
            selectedFaceIndex: selected.offset,
            alignedImage: aligned,
            boundingBox: observation.boundingBox,
            quality: Double(observation.confidence))
    }
}
