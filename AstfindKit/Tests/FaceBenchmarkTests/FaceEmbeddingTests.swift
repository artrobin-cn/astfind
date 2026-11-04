import AstfindFaceCore
import CoreML
import XCTest
@testable import FaceBenchmarkCore

final class FaceEmbeddingTests: XCTestCase {
    func testRedPixelBecomesPositiveRedAndNegativeGreenBlueCHW() throws {
        let image = FaceTestImages.solid(width: 112, height: 112, red: 255, green: 0, blue: 0)
        let tensor = try FaceInputTensor.make112(image: image)
        XCTAssertEqual(tensor.shape, [1, 3, 112, 112])
        XCTAssertEqual(tensor[0].doubleValue, 1, accuracy: 0.000_001)
        XCTAssertEqual(tensor[112 * 112].doubleValue, -1, accuracy: 0.000_001)
        XCTAssertEqual(tensor[2 * 112 * 112].doubleValue, -1, accuracy: 0.000_001)
        XCTAssertEqual(tensor[111].doubleValue, 1, accuracy: 0.000_001)
        XCTAssertEqual(tensor[112 * 112 + 111].doubleValue, -1, accuracy: 0.000_001)
    }

    func testColor127UsesInsightFaceNormalization() throws {
        let image = FaceTestImages.solid(width: 112, height: 112, red: 0, green: 127, blue: 255)
        let tensor = try FaceInputTensor.make112(image: image)
        XCTAssertEqual(tensor[0].doubleValue, -1, accuracy: 0.000_001)
        XCTAssertEqual(tensor[112 * 112].doubleValue, -1.0 / 255.0, accuracy: 0.000_01)
        XCTAssertEqual(tensor[2 * 112 * 112].doubleValue, 1, accuracy: 0.000_001)
    }

    func testRejectsNon112Image() {
        let image = FaceTestImages.solid(width: 1, height: 1, red: 0, green: 0, blue: 0)
        XCTAssertThrowsError(try FaceInputTensor.make112(image: image)) {
            XCTAssertEqual($0 as? FaceEmbeddingError, .invalidImageSize)
        }
    }

    func testL2NormalizesValidOutput() throws {
        let output = try FaceEmbeddingValidator.normalized([3, 4], dimension: 2)
        XCTAssertEqual(output[0], 0.6, accuracy: 0.000_001)
        XCTAssertEqual(output[1], 0.8, accuracy: 0.000_001)
    }

    func testRejectsWrongDimensionNonFiniteAndZeroOutput() {
        XCTAssertThrowsError(try FaceEmbeddingValidator.normalized([1, 2], dimension: 3)) {
            XCTAssertEqual($0 as? FaceEmbeddingError, .invalidOutputDimension)
        }
        XCTAssertThrowsError(try FaceEmbeddingValidator.normalized([.nan, 0], dimension: 2)) {
            XCTAssertEqual($0 as? FaceEmbeddingError, .nonFiniteOutput)
        }
        XCTAssertThrowsError(try FaceEmbeddingValidator.normalized([0, 0], dimension: 2)) {
            XCTAssertEqual($0 as? FaceEmbeddingError, .zeroNorm)
        }
    }
}
