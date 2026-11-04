import XCTest
@testable import FaceBenchmarkCore

final class FaceBenchmarkModelsTests: XCTestCase {
    func testAcceptsKnownAndUnknownQueries() {
        XCTAssertEqual(FaceBenchmarkFixtures.valid().validationIssues(), [])
    }

    func testDecodesSnakeCaseManifest() throws {
        let data = Data("""
        {
          "profile": {
            "detector": "vision-v1", "alignment": "five-point-v1",
            "preprocessing": "112-jpeg85-v1", "model": "face-test-v1",
            "dimension": 512, "normalization": "l2", "quantization": "float32"
          },
          "assets": [{
            "asset_id": "asset-a", "path": "/private/a.jpg", "kind": "image",
            "person_ids": ["person-a"], "condition": "frontal", "start_ms": null
          }],
          "queries": [{
            "query_id": "query-a", "person_id": "person-a", "image_path": "/private/q.jpg",
            "source_asset_id": null, "selected_face_index": 0,
            "excluded_asset_ids": [], "conditions": ["frontal"]
          }]
        }
        """.utf8)
        let manifest = try JSONDecoder().decode(FaceBenchmarkManifest.self, from: data)
        XCTAssertEqual(manifest.assets.first?.assetID, "asset-a")
        XCTAssertEqual(manifest.queries.first?.queryID, "query-a")
        XCTAssertEqual(manifest.validationIssues(), [])
    }

    func testRejectsDuplicateAssetAndQueryIDs() {
        var manifest = FaceBenchmarkFixtures.valid()
        manifest.assets[1].assetID = manifest.assets[0].assetID
        manifest.queries[1].queryID = manifest.queries[0].queryID
        XCTAssertEqual(manifest.validationIssues(), [
            "duplicate asset id asset-a1",
            "duplicate query id query-1"
        ])
    }

    func testRejectsQuerySourceAndNearDuplicateLeakage() {
        var manifest = FaceBenchmarkFixtures.valid()
        manifest.queries[0].sourceAssetID = "asset-query"
        manifest.queries[0].excludedAssetIDs = ["asset-query"]
        manifest.assets.append(FaceBenchmarkAsset(
            assetID: "asset-query", path: "/private/query.jpg", kind: .image,
            personIDs: ["person-a"], condition: .frontal, startMs: nil))
        XCTAssertEqual(manifest.validationIssues(), [
            "query query-1 leaks source asset asset-query",
            "query query-1 excluded asset asset-query remains in gallery"
        ])
    }

    func testRejectsKnownPersonMissingFromGalleryWithoutPrintingPaths() {
        var manifest = FaceBenchmarkFixtures.valid()
        manifest.queries[0].personID = "person-missing"
        let issues = manifest.validationIssues()
        XCTAssertEqual(issues, ["query query-1 person person-missing is absent from gallery"])
        XCTAssertFalse(issues.joined().contains("/private"))
    }

    func testRejectsInvalidProfileFaceIndexAndConditions() {
        var manifest = FaceBenchmarkFixtures.valid()
        manifest.profile.dimension = 0
        manifest.queries[0].selectedFaceIndex = -1
        manifest.queries[1].conditions = []
        XCTAssertEqual(manifest.validationIssues(), [
            "profile dimension must be positive",
            "query query-1 selected face index must be nonnegative",
            "query query-2 must have at least one condition"
        ])
    }

    func testRejectsEmptyAssetsAndQueries() {
        var manifest = FaceBenchmarkFixtures.valid()
        manifest.assets = []
        manifest.queries = []
        XCTAssertEqual(manifest.validationIssues(), [
            "manifest must contain assets",
            "manifest must contain queries"
        ])
    }
}
