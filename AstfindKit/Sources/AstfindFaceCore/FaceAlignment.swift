import CoreGraphics
import Foundation

public struct FacePoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public enum FaceAlignmentError: Error, Equatable {
    case invalidPointCount
    case nonFinitePoint
    case degenerateSource
    case missingLandmarks
    case noFace
    case imageRenderingFailed
}

public struct FaceFivePoints: Equatable, Sendable {
    public let points: [FacePoint]

    public init(points: [FacePoint]) throws {
        guard points.count == 5 else { throw FaceAlignmentError.invalidPointCount }
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw FaceAlignmentError.nonFinitePoint
        }
        self.points = points
    }

    public static let arcFaceDestination = try! FaceFivePoints(points: [
        FacePoint(x: 38.2946, y: 51.6963),
        FacePoint(x: 73.5318, y: 51.5014),
        FacePoint(x: 56.0252, y: 71.7366),
        FacePoint(x: 41.5493, y: 92.3655),
        FacePoint(x: 70.7299, y: 92.2041)
    ])
}

public struct FaceSimilarityTransform: Equatable, Sendable {
    public let a: Double
    public let b: Double
    public let tx: Double
    public let ty: Double

    public init(a: Double, b: Double, tx: Double, ty: Double) {
        self.a = a
        self.b = b
        self.tx = tx
        self.ty = ty
    }

    public init(source: FaceFivePoints, destination: FaceFivePoints) throws {
        let sourceMean = Self.mean(source.points)
        let destinationMean = Self.mean(destination.points)
        var denominator = 0.0
        var aNumerator = 0.0
        var bNumerator = 0.0
        for (sourcePoint, destinationPoint) in zip(source.points, destination.points) {
            let x = sourcePoint.x - sourceMean.x
            let y = sourcePoint.y - sourceMean.y
            let dx = destinationPoint.x - destinationMean.x
            let dy = destinationPoint.y - destinationMean.y
            denominator += x * x + y * y
            aNumerator += x * dx + y * dy
            bNumerator += x * dy - y * dx
        }
        guard denominator > 0.000_000_001 else { throw FaceAlignmentError.degenerateSource }
        let a = aNumerator / denominator
        let b = bNumerator / denominator
        self.init(
            a: a,
            b: b,
            tx: destinationMean.x - a * sourceMean.x + b * sourceMean.y,
            ty: destinationMean.y - b * sourceMean.x - a * sourceMean.y)
    }

    public func apply(_ point: FacePoint) -> FacePoint {
        FacePoint(
            x: a * point.x - b * point.y + tx,
            y: b * point.x + a * point.y + ty)
    }

    private static func mean(_ points: [FacePoint]) -> FacePoint {
        let total = points.reduce(FacePoint(x: 0, y: 0)) {
            FacePoint(x: $0.x + $1.x, y: $0.y + $1.y)
        }
        return FacePoint(x: total.x / Double(points.count), y: total.y / Double(points.count))
    }
}

public enum FaceLandmarkGeometry {
    public static func fivePoints(
        imageSize: CGSize,
        boundingBox: CGRect,
        rightEye: [CGPoint],
        leftEye: [CGPoint],
        nose: [CGPoint],
        outerLips: [CGPoint]
    ) throws -> FaceFivePoints {
        guard !rightEye.isEmpty, !leftEye.isEmpty, !nose.isEmpty, outerLips.count >= 2 else {
            throw FaceAlignmentError.missingLandmarks
        }
        func pixel(_ point: CGPoint) -> FacePoint {
            FacePoint(
                x: (boundingBox.origin.x + point.x * boundingBox.width) * imageSize.width,
                y: ((1 - boundingBox.origin.y - boundingBox.height)
                    + (1 - point.y) * boundingBox.height) * imageSize.height)
        }
        func center(_ points: [CGPoint]) -> FacePoint {
            let total = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            return pixel(CGPoint(x: total.x / CGFloat(points.count), y: total.y / CGFloat(points.count)))
        }
        let eyes = [center(rightEye), center(leftEye)].sorted { $0.x < $1.x }
        let nosePoints = nose.map(pixel)
        guard let noseTip = nosePoints.max(by: { $0.y < $1.y }) else {
            throw FaceAlignmentError.missingLandmarks
        }
        let mouth = outerLips.map(pixel).sorted { $0.x < $1.x }
        guard let leftMouth = mouth.first, let rightMouth = mouth.last else {
            throw FaceAlignmentError.missingLandmarks
        }
        return try FaceFivePoints(points: [eyes[0], eyes[1], noseTip, leftMouth, rightMouth])
    }
}
