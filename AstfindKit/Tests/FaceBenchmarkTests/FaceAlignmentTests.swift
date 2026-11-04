import AstfindFaceCore
import XCTest
@testable import FaceBenchmarkCore

final class FaceAlignmentTests: XCTestCase {
    private let source = [
        FacePoint(x: 0, y: 0), FacePoint(x: 1, y: 0), FacePoint(x: 0, y: 1),
        FacePoint(x: -1, y: 0), FacePoint(x: 0, y: -1)
    ]

    func testArcFaceDestinationUsesOfficialFivePointOrder() {
        XCTAssertEqual(FaceFivePoints.arcFaceDestination.points, [
            FacePoint(x: 38.2946, y: 51.6963),
            FacePoint(x: 73.5318, y: 51.5014),
            FacePoint(x: 56.0252, y: 71.7366),
            FacePoint(x: 41.5493, y: 92.3655),
            FacePoint(x: 70.7299, y: 92.2041)
        ])
    }

    func testRecoversTranslation() throws {
        let transform = FaceSimilarityTransform(a: 1, b: 0, tx: 10, ty: 20)
        let destination = try FaceFivePoints(points: source.map(transform.apply))
        let estimated = try FaceSimilarityTransform(
            source: FaceFivePoints(points: source), destination: destination)
        XCTAssertEqual(estimated.a, 1, accuracy: 0.000_001)
        XCTAssertEqual(estimated.b, 0, accuracy: 0.000_001)
        XCTAssertEqual(estimated.tx, 10, accuracy: 0.000_001)
        XCTAssertEqual(estimated.ty, 20, accuracy: 0.000_001)
    }

    func testRecoversScaleAndRotation() throws {
        let transform = FaceSimilarityTransform(a: 0, b: 2, tx: -3, ty: 7)
        let destination = try FaceFivePoints(points: source.map(transform.apply))
        let estimated = try FaceSimilarityTransform(
            source: FaceFivePoints(points: source), destination: destination)
        for (input, expected) in zip(source, destination.points) {
            let actual = estimated.apply(input)
            XCTAssertEqual(actual.x, expected.x, accuracy: 0.000_001)
            XCTAssertEqual(actual.y, expected.y, accuracy: 0.000_001)
        }
    }

    func testRejectsInvalidPointCountsAndDegenerateSource() {
        XCTAssertThrowsError(try FaceFivePoints(points: Array(source.prefix(4)))) {
            XCTAssertEqual($0 as? FaceAlignmentError, .invalidPointCount)
        }
        XCTAssertThrowsError(try FaceSimilarityTransform(
            source: FaceFivePoints(points: Array(repeating: FacePoint(x: 1, y: 1), count: 5)),
            destination: FaceFivePoints.arcFaceDestination)) {
            XCTAssertEqual($0 as? FaceAlignmentError, .degenerateSource)
        }
    }

    func testRejectsNonFinitePoints() {
        XCTAssertThrowsError(try FaceFivePoints(points: [
            FacePoint(x: .nan, y: 0), FacePoint(x: 1, y: 0), FacePoint(x: 0, y: 1),
            FacePoint(x: -1, y: 0), FacePoint(x: 0, y: -1)
        ])) {
            XCTAssertEqual($0 as? FaceAlignmentError, .nonFinitePoint)
        }
    }

    func testMapsVisionCoordinatesToTopLeftAndImageLeftRightOrder() throws {
        let points = try FaceLandmarkGeometry.fivePoints(
            imageSize: CGSize(width: 200, height: 100),
            boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.5),
            rightEye: [CGPoint(x: 0.25, y: 0.5)],
            leftEye: [CGPoint(x: 0.5, y: 0.5)],
            nose: [CGPoint(x: 0.4, y: 0.4), CGPoint(x: 0.4, y: 0.6)],
            outerLips: [CGPoint(x: 0.25, y: 0.8), CGPoint(x: 0.75, y: 0.8)])
        XCTAssertEqual(points.points[0].x, 40, accuracy: 0.000_001)
        XCTAssertEqual(points.points[1].x, 60, accuracy: 0.000_001)
        XCTAssertEqual(points.points[0].y, 55, accuracy: 0.000_001)
        XCTAssertEqual(points.points[2].y, 60, accuracy: 0.000_001)
        XCTAssertEqual(points.points[3].x, 40, accuracy: 0.000_001)
        XCTAssertEqual(points.points[4].x, 80, accuracy: 0.000_001)
        XCTAssertEqual(points.points[3].y, 40, accuracy: 0.000_001)
    }
}
