import AstfindFaceCore
import XCTest
@testable import FaceBenchmarkCore

final class VisionFacePreprocessorTests: XCTestCase {
    func testBlankImageReturnsNoFace() {
        let image = FaceTestImages.solid(width: 64, height: 64, red: 0, green: 0, blue: 0)
        XCTAssertThrowsError(try VisionFacePreprocessor().process(image: image)) {
            XCTAssertEqual($0 as? FaceAlignmentError, .noFace)
        }
    }

    func testAlignerReturns112SquareImage() throws {
        let image = FaceTestImages.solid(width: 112, height: 112, red: 20, green: 40, blue: 60)
        let aligned = try FaceAligner.aligned(
            image: image,
            source: .arcFaceDestination,
            context: CIContext())
        XCTAssertEqual(aligned.width, 112)
        XCTAssertEqual(aligned.height, 112)
    }
}
