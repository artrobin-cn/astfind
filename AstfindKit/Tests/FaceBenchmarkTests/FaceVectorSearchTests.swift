import AstfindFaceCore
import XCTest
@testable import FaceBenchmarkCore

final class FaceVectorSearchTests: XCTestCase {
    func testCosineHandlesIdenticalOrthogonalOppositeAndZeroVectors() {
        XCTAssertEqual(FaceVectorSearch.cosine([1, 0], [1, 0]), 1, accuracy: 0.000_001)
        XCTAssertEqual(FaceVectorSearch.cosine([1, 0], [0, 1]), 0, accuracy: 0.000_001)
        XCTAssertEqual(FaceVectorSearch.cosine([1, 0], [-1, 0]), -1, accuracy: 0.000_001)
        XCTAssertEqual(FaceVectorSearch.cosine([0, 0], [1, 0]), 0)
        XCTAssertEqual(FaceVectorSearch.cosine([1], [1, 0]), 0)
    }

    func testSearchDeduplicatesAssetsAndUsesDeterministicOrdering() {
        let candidates = [
            FaceVectorCandidate(assetID: "asset-b", vector: [0, 1]),
            FaceVectorCandidate(assetID: "asset-c", vector: [1, 0]),
            FaceVectorCandidate(assetID: "asset-a", vector: [1, 0]),
            FaceVectorCandidate(assetID: "asset-a", vector: [-1, 0])
        ]
        let hits = FaceVectorSearch.search(query: [1, 0], candidates: candidates, limit: 3)
        XCTAssertEqual(hits.map(\.assetID), ["asset-a", "asset-c", "asset-b"])
        XCTAssertEqual(hits.map(\.score), [1, 1, 0])
        XCTAssertEqual(FaceVectorSearch.search(query: [1, 0], candidates: candidates, limit: 0), [])
    }
}
