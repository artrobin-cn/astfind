import XCTest
@testable import FaceBenchmarkCore

final class FaceBenchmarkCapacityTests: XCTestCase {
    func testSyntheticCapacityIsDeterministicAndLabeled() throws {
        let first = try FaceBenchmarkCapacityRunner.run(
            assetCount: 5,
            facesPerAsset: 2,
            dimension: 8,
            queryCount: 3)
        let second = try FaceBenchmarkCapacityRunner.run(
            assetCount: 5,
            facesPerAsset: 2,
            dimension: 8,
            queryCount: 3)
        XCTAssertEqual(first.dataSource, "synthetic_vectors")
        XCTAssertEqual(first.assetCount, 5)
        XCTAssertEqual(first.faceCount, 10)
        XCTAssertEqual(first.dimension, 8)
        XCTAssertGreaterThan(first.buildElapsedMs, 0)
        XCTAssertGreaterThan(first.storageBytes, 0)
        XCTAssertGreaterThan(first.peakResidentBytes, 0)
        XCTAssertGreaterThanOrEqual(first.queryP50Ms, 0)
        XCTAssertGreaterThanOrEqual(first.queryP95Ms, first.queryP50Ms)
        XCTAssertEqual(first.storageBytes, second.storageBytes)
    }

    func testRejectsInvalidCapacityInputs() {
        XCTAssertThrowsError(try FaceBenchmarkCapacityRunner.run(
            assetCount: 0,
            facesPerAsset: 1,
            dimension: 8,
            queryCount: 1)) {
            XCTAssertEqual($0 as? FaceBenchmarkCapacityError, .invalidInput)
        }
        XCTAssertThrowsError(try FaceBenchmarkCapacityRunner.run(
            assetCount: 1,
            facesPerAsset: 0,
            dimension: 8,
            queryCount: 1)) {
            XCTAssertEqual($0 as? FaceBenchmarkCapacityError, .invalidInput)
        }
        XCTAssertThrowsError(try FaceBenchmarkCapacityRunner.run(
            assetCount: 1,
            facesPerAsset: 1,
            dimension: 0,
            queryCount: 1)) {
            XCTAssertEqual($0 as? FaceBenchmarkCapacityError, .invalidInput)
        }
    }
}
