import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import FaceBenchmarkCore

final class FaceBenchmarkImageIOTests: XCTestCase {
    func testScalesDownToMaxSideAndPreservesAspectRatio() throws {
        let image = FaceTestImages.solid(width: 200, height: 100, red: 10, green: 20, blue: 30)
        let scaled = try FaceBenchmarkImageScaler.scaled(image, maxSide: 64)
        XCTAssertEqual(scaled.width, 64)
        XCTAssertEqual(scaled.height, 32)
        XCTAssertEqual(try FaceBenchmarkImageScaler.scaled(image, maxSide: 400).width, 200)
    }

    func testWritesJPEGWithRequestedDimensions() throws {
        let image = FaceTestImages.solid(width: 200, height: 100, red: 10, green: 20, blue: 30)
        let scaled = try FaceBenchmarkImageScaler.scaled(image, maxSide: 64)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try FaceBenchmarkImageIO.writeJPEG(scaled, to: url, quality: 0.8)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(
            CGImageSourceGetType(source) as String?,
            "public.jpeg")
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, 64)
        XCTAssertEqual(decoded.height, 32)
    }
}
