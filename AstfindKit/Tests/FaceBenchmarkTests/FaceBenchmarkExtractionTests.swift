import Foundation
import XCTest
@testable import FaceBenchmarkCore

final class FaceBenchmarkExtractionTests: XCTestCase {
    func testImagePlannerFiltersSortsAndLimitsDeterministically() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sub"),
            withIntermediateDirectories: true)
        for name in ["b.JPG", "a.jpg", "c.png", "note.txt", ".hidden.jpg"] {
            try Data([1]).write(to: root.appendingPathComponent(name))
        }
        try Data([1]).write(to: root.appendingPathComponent("sub/d.jpeg"))

        let all = try FaceBenchmarkExtractionPlanner.imageFiles(in: root, maxImages: nil)
        XCTAssertEqual(
            all.map { $0.lastPathComponent },
            ["a.jpg", "b.JPG", "c.png", "d.jpeg"])
        let limited = try FaceBenchmarkExtractionPlanner.imageFiles(in: root, maxImages: 2)
        XCTAssertEqual(limited.map { $0.lastPathComponent }, ["a.jpg", "b.JPG"])
    }

    func testAssetIDIsStableAndPathSpecific() {
        let first = FaceBenchmarkExtractionPlanner.assetID(relativePath: "event/a.jpg")
        let again = FaceBenchmarkExtractionPlanner.assetID(relativePath: "event/a.jpg")
        let other = FaceBenchmarkExtractionPlanner.assetID(relativePath: "event/b.jpg")
        XCTAssertEqual(first, again)
        XCTAssertNotEqual(first, other)
        XCTAssertEqual(first.count, 16)
        XCTAssertTrue(first.allSatisfy { $0.isHexDigit })
    }
}
