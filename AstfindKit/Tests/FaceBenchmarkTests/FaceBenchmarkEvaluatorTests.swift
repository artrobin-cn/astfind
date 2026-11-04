import XCTest
@testable import FaceBenchmarkCore

final class FaceBenchmarkEvaluatorTests: XCTestCase {
    func testComputesAssetDedupedMetricsAndNearestRankLatency() throws {
        let summary = try FaceBenchmarkEvaluator.evaluate(
            manifest: FaceBenchmarkFixtures.metricManifest(),
            results: FaceBenchmarkFixtures.metricResults())
        XCTAssertEqual(summary.overall.queryCount, 2)
        XCTAssertEqual(summary.overall.rank1, 0.5, accuracy: 0.0001)
        XCTAssertEqual(summary.overall.recallAt10, 1.0, accuracy: 0.0001)
        XCTAssertEqual(summary.overall.precisionAt10, 0.15, accuracy: 0.0001)
        XCTAssertEqual(summary.unknownQueryCount, 1)
        XCTAssertEqual(summary.unknownReturnRate, 1.0, accuracy: 0.0001)
        XCTAssertEqual(summary.latencyP50Ms, 20)
        XCTAssertEqual(summary.latencyP95Ms, 40)
        XCTAssertEqual(summary.byCondition["frontal"]?.rank1, 0)
        XCTAssertEqual(summary.byCondition["frontal"]?.precisionAt10, 0.2)
        XCTAssertEqual(summary.byCondition["low_light"]?.rank1, 1)
        XCTAssertEqual(summary.byCondition["low_light"]?.precisionAt10, 0.1)
    }

    func testKnownAndUnknownQueriesWithNoHitsScoreZero() throws {
        let results = FaceBenchmarkFixtures.metricResults().map {
            FaceBenchmarkQueryResult(queryID: $0.queryID, hits: [], elapsedMs: $0.elapsedMs)
        }
        let summary = try FaceBenchmarkEvaluator.evaluate(
            manifest: FaceBenchmarkFixtures.metricManifest(), results: results)
        XCTAssertEqual(summary.overall.rank1, 0)
        XCTAssertEqual(summary.overall.recallAt10, 0)
        XCTAssertEqual(summary.overall.precisionAt10, 0)
        XCTAssertEqual(summary.unknownReturnRate, 0)
    }

    func testQueryCanContributeToMultipleConditionGroups() throws {
        var manifest = FaceBenchmarkFixtures.metricManifest()
        manifest.queries[0].conditions = [.frontal, .groupPhoto]
        let summary = try FaceBenchmarkEvaluator.evaluate(
            manifest: manifest, results: FaceBenchmarkFixtures.metricResults())
        XCTAssertEqual(summary.byCondition["frontal"]?.queryCount, 1)
        XCTAssertEqual(summary.byCondition["group_photo"]?.queryCount, 1)
    }

    func testRejectsDuplicateResultIDs() {
        var results = FaceBenchmarkFixtures.metricResults()
        results.append(results[0])
        XCTAssertThrowsError(try FaceBenchmarkEvaluator.evaluate(
            manifest: FaceBenchmarkFixtures.metricManifest(), results: results)) {
            XCTAssertEqual($0 as? FaceBenchmarkEvaluationError, .duplicateResult("query-1"))
        }
    }

    func testRejectsMissingResultIDs() {
        let results = Array(FaceBenchmarkFixtures.metricResults().dropFirst())
        XCTAssertThrowsError(try FaceBenchmarkEvaluator.evaluate(
            manifest: FaceBenchmarkFixtures.metricManifest(), results: results)) {
            XCTAssertEqual($0 as? FaceBenchmarkEvaluationError, .missingResult("query-1"))
        }
    }

    func testRejectsUnexpectedResultIDs() {
        var results = FaceBenchmarkFixtures.metricResults()
        results[0].queryID = "query-extra"
        XCTAssertThrowsError(try FaceBenchmarkEvaluator.evaluate(
            manifest: FaceBenchmarkFixtures.metricManifest(), results: results)) {
            XCTAssertEqual($0 as? FaceBenchmarkEvaluationError, .unexpectedResult("query-extra"))
        }
    }

    func testRejectsUnknownHitAsset() {
        var results = FaceBenchmarkFixtures.metricResults()
        results[0].hits[0].assetID = "asset-missing"
        XCTAssertThrowsError(try FaceBenchmarkEvaluator.evaluate(
            manifest: FaceBenchmarkFixtures.metricManifest(), results: results)) {
            XCTAssertEqual($0 as? FaceBenchmarkEvaluationError, .unknownHitAsset("asset-missing"))
        }
    }

    func testRejectsInvalidManifestBeforeEvaluation() {
        var manifest = FaceBenchmarkFixtures.metricManifest()
        manifest.queries[0].selectedFaceIndex = -1
        XCTAssertThrowsError(try FaceBenchmarkEvaluator.evaluate(
            manifest: manifest, results: FaceBenchmarkFixtures.metricResults())) {
            XCTAssertEqual($0 as? FaceBenchmarkEvaluationError,
                           .invalidManifest(["query query-1 selected face index must be nonnegative"]))
        }
    }

    func testEqualScoresUseAssetIDAsDeterministicTieBreak() throws {
        var manifest = FaceBenchmarkFixtures.metricManifest()
        manifest.queries = [manifest.queries[1]]
        let results = [FaceBenchmarkQueryResult(queryID: "query-2", hits: [
            FaceBenchmarkHit(assetID: "asset-b1", score: 0.9),
            FaceBenchmarkHit(assetID: "asset-a1", score: 0.9)
        ], elapsedMs: 10)]
        let summary = try FaceBenchmarkEvaluator.evaluate(manifest: manifest, results: results)
        XCTAssertEqual(summary.overall.rank1, 0)
        XCTAssertEqual(summary.overall.recallAt10, 1)
        XCTAssertEqual(summary.latencyP50Ms, 10)
        XCTAssertEqual(summary.latencyP95Ms, 10)
        XCTAssertEqual(summary.unknownReturnRate, 0)
    }
}
