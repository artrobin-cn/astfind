import AstfindFaceCore
import CoreGraphics
import XCTest
@testable import FaceBenchmarkCore

final class FaceBenchmarkFaceSelectionTests: XCTestCase {
    private func region(
        detectionIndex: Int,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        confidence: Float = 0.9
    ) -> FaceBenchmarkFaceRegion {
        FaceBenchmarkFaceRegion(
            detectionIndex: detectionIndex,
            boundingBox: CGRect(x: x, y: y, width: width, height: height),
            confidence: confidence,
            pixelWidth: Double(width) * 1_000,
            pixelHeight: Double(height) * 1_000)
    }

    func testOrdersFacesByAreaThenPositionThenDetectionIndex() {
        let regions = [
            region(detectionIndex: 3, x: 0.6, y: 0.1, width: 0.2, height: 0.2),
            region(detectionIndex: 2, x: 0.1, y: 0.5, width: 0.3, height: 0.3),
            region(detectionIndex: 1, x: 0.1, y: 0.2, width: 0.3, height: 0.3),
            region(detectionIndex: 0, x: 0.1, y: 0.2, width: 0.3, height: 0.3)
        ]
        XCTAssertEqual(
            FaceBenchmarkFaceSelection.ordered(regions).map(\.detectionIndex),
            [0, 1, 2, 3])
    }

    func testPolicyFiltersSmallLowConfidenceAndCapsFaceCount() throws {
        let policy = FaceBenchmarkFaceSelectionPolicy(
            minimumFaceSidePixels: 100,
            minimumConfidence: 0.5,
            maximumFacesPerAsset: 2)
        let regions = [
            region(detectionIndex: 0, x: 0.1, y: 0.1, width: 0.5, height: 0.5, confidence: 0.9),
            region(detectionIndex: 1, x: 0.1, y: 0.1, width: 0.5, height: 0.5, confidence: 0.9),
            region(detectionIndex: 2, x: 0.1, y: 0.1, width: 0.5, height: 0.5, confidence: 0.2),
            region(detectionIndex: 3, x: 0.9, y: 0.9, width: 0.01, height: 0.01, confidence: 0.9),
            region(detectionIndex: 4, x: 0.2, y: 0.2, width: 0.3, height: 0.3, confidence: 0.9)
        ]
        let accepted = FaceBenchmarkFaceSelection.accepted(regions, policy: policy)
        XCTAssertEqual(accepted.map(\.detectionIndex), [0, 1])
    }

    func testSelectedFaceIndexResolvesAfterFiltering() throws {
        let policy = FaceBenchmarkFaceSelectionPolicy(
            minimumFaceSidePixels: 100,
            minimumConfidence: 0.5,
            maximumFacesPerAsset: 20)
        let regions = [
            region(detectionIndex: 0, x: 0.1, y: 0.1, width: 0.5, height: 0.5, confidence: 0.9),
            region(detectionIndex: 1, x: 0.9, y: 0.9, width: 0.01, height: 0.01, confidence: 0.9),
            region(detectionIndex: 2, x: 0.2, y: 0.2, width: 0.3, height: 0.3, confidence: 0.9)
        ]
        let selected = try FaceBenchmarkFaceSelection.selected(
            at: 1,
            from: regions,
            policy: policy)
        XCTAssertEqual(selected.detectionIndex, 2)
    }

    func testSelectedFaceOutOfRangeFailsInsteadOfFallingBack() {
        let policy = FaceBenchmarkFaceSelectionPolicy()
        let regions = [region(detectionIndex: 0, x: 0.1, y: 0.1, width: 0.5, height: 0.5)]
        XCTAssertThrowsError(
            try FaceBenchmarkFaceSelection.selected(at: 3, from: regions, policy: policy)
        ) {
            XCTAssertEqual(
                $0 as? FaceBenchmarkFaceSelectionError,
                .selectedFaceOutOfRange(faceCount: 1))
        }
    }

    func testBlankImageStillReportsNoFaceThroughBatchPreprocessor() {
        let image = FaceTestImages.solid(width: 64, height: 64, red: 0, green: 0, blue: 0)
        XCTAssertThrowsError(
            try VisionFaceBatchPreprocessor(policy: FaceBenchmarkFaceSelectionPolicy()).process(image: image)
        ) {
            XCTAssertEqual($0 as? FaceAlignmentError, .noFace)
        }
    }
}
