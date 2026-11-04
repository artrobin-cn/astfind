import XCTest
@testable import FaceBenchmarkCore

final class FaceBenchmarkReportTests: XCTestCase {
    private func manifest() -> FaceBenchmarkManifest {
        FaceBenchmarkManifest(
            profile: FaceBenchmarkFixtures.profile(),
            assets: [
                FaceBenchmarkAsset(
                    assetID: "asset-a", path: "/private/a.jpg", kind: .image,
                    personIDs: ["person-a"], condition: .frontal, startMs: nil),
                FaceBenchmarkAsset(
                    assetID: "asset-b", path: "/private/b.jpg", kind: .image,
                    personIDs: ["person-b"], condition: .frontal, startMs: nil)
            ],
            queries: [
                FaceBenchmarkQuery(
                    queryID: "query-a", personID: "person-a", imagePath: "/private/qa.jpg",
                    sourceAssetID: nil, selectedFaceIndex: 0, excludedAssetIDs: [],
                    conditions: [.frontal]),
                FaceBenchmarkQuery(
                    queryID: "query-b", personID: "person-b", imagePath: "/private/qb.jpg",
                    sourceAssetID: nil, selectedFaceIndex: 0, excludedAssetIDs: [],
                    conditions: [.frontal]),
                FaceBenchmarkQuery(
                    queryID: "query-unknown", personID: nil, imagePath: "/private/qu.jpg",
                    sourceAssetID: nil, selectedFaceIndex: 0, excludedAssetIDs: [],
                    conditions: [.frontal])
            ])
    }

    private func results() -> [FaceBenchmarkQueryResult] {
        [
            FaceBenchmarkQueryResult(queryID: "query-a", hits: [
                FaceBenchmarkHit(assetID: "asset-a", score: 0.90),
                FaceBenchmarkHit(assetID: "asset-b", score: 0.60)
            ], elapsedMs: 10),
            FaceBenchmarkQueryResult(queryID: "query-b", hits: [
                FaceBenchmarkHit(assetID: "asset-b", score: 0.90)
            ], elapsedMs: 20),
            FaceBenchmarkQueryResult(queryID: "query-unknown", hits: [
                FaceBenchmarkHit(assetID: "asset-a", score: 0.70)
            ], elapsedMs: 30)
        ]
    }

    func testThresholdSweepFiltersHitsAndRecomputesUnknownRate() throws {
        let sweep = try FaceBenchmarkThresholdAnalyzer.sweep(
            manifest: manifest(),
            results: results(),
            thresholds: [0, 0.8, 0.95])
        XCTAssertEqual(sweep.map(\.threshold), [0, 0.8, 0.95])
        XCTAssertEqual(sweep[0].rank1, 1, accuracy: 0.000_1)
        XCTAssertEqual(sweep[0].recallAt10, 1, accuracy: 0.000_1)
        XCTAssertEqual(sweep[0].precisionAt10, 0.1, accuracy: 0.000_1)
        XCTAssertEqual(sweep[0].unknownReturnRate, 1, accuracy: 0.000_1)
        XCTAssertEqual(sweep[1].rank1, 1, accuracy: 0.000_1)
        XCTAssertEqual(sweep[1].unknownReturnRate, 0, accuracy: 0.000_1)
        XCTAssertEqual(sweep[2].rank1, 0, accuracy: 0.000_1)
        XCTAssertEqual(sweep[2].recallAt10, 0, accuracy: 0.000_1)
        XCTAssertEqual(sweep[2].unknownReturnRate, 0, accuracy: 0.000_1)
    }

    func testReportIncludesSelectedThresholdGroupingLatencyAndVideoRecall() throws {
        let videoManifest = FaceBenchmarkFixtures.videoManifest()
        let videoTruth = FaceBenchmarkVideoTruthManifest(videos: [
            FaceBenchmarkVideoTruth(
                videoID: "video-a",
                durationMs: 20_000,
                appearances: [
                    FaceBenchmarkVideoAppearance(personID: "person-a", startMs: 14_000, endMs: 16_000)
                ])
        ])
        let report = try FaceBenchmarkReportBuilder.build(
            manifest: videoManifest,
            results: [
                FaceBenchmarkQueryResult(
                    queryID: "query-a",
                    hits: [FaceBenchmarkHit(assetID: "frame-a-15", score: 0.95)],
                    elapsedMs: 10),
                FaceBenchmarkQueryResult(queryID: "query-unknown", hits: [], elapsedMs: 20)
            ],
            thresholds: [0.8, 0.9],
            selectedThreshold: 0.9,
            videoTruth: videoTruth)
        XCTAssertEqual(report.selectedThreshold, 0.9)
        XCTAssertEqual(report.selected.rank1, 1, accuracy: 0.000_1)
        XCTAssertEqual(report.thresholdCurve.count, 2)
        XCTAssertEqual(report.thresholdCurve.map(\.threshold), [0.8, 0.9])
        XCTAssertEqual(report.knownQueryCount, 1)
        XCTAssertEqual(report.unknownQueryCount, 1)
        XCTAssertEqual(report.byCondition["video_frame"]?.queryCount, 1)
        XCTAssertEqual(report.latencyP50Ms, 10, accuracy: 0.000_1)
        XCTAssertEqual(report.latencyP95Ms, 20, accuracy: 0.000_1)
        let videoRecall = try XCTUnwrap(report.videoRecall)
        XCTAssertEqual(videoRecall.sampledFrameConditionalRecall, 1, accuracy: 0.000_1)
        XCTAssertEqual(videoRecall.actualShotRecall, 1, accuracy: 0.000_1)
    }
}
