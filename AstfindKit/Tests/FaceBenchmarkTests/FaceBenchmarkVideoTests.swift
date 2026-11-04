import XCTest
@testable import FaceBenchmarkCore

final class FaceBenchmarkVideoTests: XCTestCase {
    func testSamplingPlanUsesIntervalAndFrameCap() throws {
        let policy = FaceBenchmarkVideoSamplingPolicy(intervalMs: 10_000, maxFrames: 60)
        XCTAssertEqual(
            try FaceBenchmarkVideoSampling.frameTimes(durationMs: 25_000, policy: policy),
            [0, 10_000, 20_000])
        XCTAssertEqual(
            try FaceBenchmarkVideoSampling.frameTimes(
                durationMs: 25_000,
                policy: FaceBenchmarkVideoSamplingPolicy(intervalMs: 10_000, maxFrames: 2)),
            [0, 10_000])
        XCTAssertEqual(
            try FaceBenchmarkVideoSampling.frameTimes(
                durationMs: 5_000,
                policy: FaceBenchmarkVideoSamplingPolicy(intervalMs: 10_000, maxFrames: 60)),
            [0])
        XCTAssertEqual(
            try FaceBenchmarkVideoSampling.frameTimes(
                durationMs: 25_000,
                policy: FaceBenchmarkVideoSamplingPolicy(
                    intervalMs: 10_000, maxFrames: 60, startMs: 1_000)),
            [1_000, 11_000, 21_000])
    }

    func testSamplingPlanRejectsInvalidDurationIntervalAndCap() {
        let policy = FaceBenchmarkVideoSamplingPolicy(intervalMs: 10_000, maxFrames: 60)
        XCTAssertThrowsError(
            try FaceBenchmarkVideoSampling.frameTimes(durationMs: 0, policy: policy)
        ) {
            XCTAssertEqual($0 as? FaceBenchmarkVideoSamplingError, .invalidDuration)
        }
        XCTAssertThrowsError(
            try FaceBenchmarkVideoSampling.frameTimes(
                durationMs: 10_000,
                policy: FaceBenchmarkVideoSamplingPolicy(intervalMs: 0, maxFrames: 60))
        ) {
            XCTAssertEqual($0 as? FaceBenchmarkVideoSamplingError, .invalidPolicy)
        }
        XCTAssertThrowsError(
            try FaceBenchmarkVideoSampling.frameTimes(
                durationMs: 10_000,
                policy: FaceBenchmarkVideoSamplingPolicy(intervalMs: 10_000, maxFrames: 0))
        ) {
            XCTAssertEqual($0 as? FaceBenchmarkVideoSamplingError, .invalidPolicy)
        }
    }

    func testTruthValidationRejectsDuplicateVideosAndBadIntervals() {
        let manifest = FaceBenchmarkVideoTruthManifest(videos: [
            FaceBenchmarkVideoTruth(
                videoID: "video-a",
                durationMs: 10_000,
                appearances: [
                    FaceBenchmarkVideoAppearance(personID: "person-a", startMs: 1_000, endMs: 1_000)
                ]),
            FaceBenchmarkVideoTruth(
                videoID: "video-a",
                durationMs: 10_000,
                appearances: [
                    FaceBenchmarkVideoAppearance(personID: "person-a", startMs: 0, endMs: 11_000)
                ])
        ])
        XCTAssertEqual(manifest.validationIssues(), [
            "duplicate video id video-a",
            "video video-a appearance 0 must end after start",
            "video video-a appearance 0 must fit within duration"
        ])
    }

    func testSeparatesSampledFrameRecallFromActualShotRecall() throws {
        let manifest = FaceBenchmarkFixtures.videoManifest()
        let truth = FaceBenchmarkVideoTruthManifest(videos: [
            FaceBenchmarkVideoTruth(
                videoID: "video-a",
                durationMs: 20_000,
                appearances: [
                    FaceBenchmarkVideoAppearance(personID: "person-a", startMs: 0, endMs: 5_000),
                    FaceBenchmarkVideoAppearance(personID: "person-a", startMs: 14_000, endMs: 16_000)
                ]),
            FaceBenchmarkVideoTruth(
                videoID: "video-b",
                durationMs: 10_000,
                appearances: [
                    FaceBenchmarkVideoAppearance(personID: "person-a", startMs: 0, endMs: 10_000)
                ]),
            FaceBenchmarkVideoTruth(
                videoID: "video-c",
                durationMs: 5_000,
                appearances: [
                    FaceBenchmarkVideoAppearance(personID: "person-a", startMs: 0, endMs: 5_000)
                ])
        ])
        let recall = try FaceBenchmarkVideoRecallEvaluator.evaluate(
            manifest: manifest,
            truth: truth,
            results: [
                FaceBenchmarkQueryResult(
                    queryID: "query-a",
                    hits: [
                        FaceBenchmarkHit(assetID: "frame-a-15", score: 0.95),
                        FaceBenchmarkHit(assetID: "frame-b-0", score: 0.90),
                        FaceBenchmarkHit(assetID: "frame-b-0", score: 0.80),
                        FaceBenchmarkHit(assetID: "frame-c-b", score: 0.70)
                    ],
                    elapsedMs: 10),
                FaceBenchmarkQueryResult(
                    queryID: "query-unknown",
                    hits: [FaceBenchmarkHit(assetID: "frame-a-0", score: 0.99)],
                    elapsedMs: 20)
            ])
        XCTAssertEqual(recall.sampledFramePairCount, 2)
        XCTAssertEqual(recall.sampledFrameHits, 2)
        XCTAssertEqual(recall.sampledFrameConditionalRecall, 1.0, accuracy: 0.000_1)
        XCTAssertEqual(recall.actualShotCount, 4)
        XCTAssertEqual(recall.actualShotHits, 2)
        XCTAssertEqual(recall.actualShotRecall, 0.5, accuracy: 0.000_1)
    }

    func testNoHitsProducesZeroRecallWithNonzeroDenominators() throws {
        let manifest = FaceBenchmarkFixtures.videoManifest()
        let truth = FaceBenchmarkVideoTruthManifest(videos: [
            FaceBenchmarkVideoTruth(
                videoID: "video-a",
                durationMs: 20_000,
                appearances: [
                    FaceBenchmarkVideoAppearance(personID: "person-a", startMs: 0, endMs: 5_000)
                ])
        ])
        let recall = try FaceBenchmarkVideoRecallEvaluator.evaluate(
            manifest: manifest,
            truth: truth,
            results: [
                FaceBenchmarkQueryResult(queryID: "query-a", hits: [], elapsedMs: 1),
                FaceBenchmarkQueryResult(queryID: "query-unknown", hits: [], elapsedMs: 1)
            ])
        XCTAssertEqual(recall.sampledFramePairCount, 1)
        XCTAssertEqual(recall.sampledFrameHits, 0)
        XCTAssertEqual(recall.sampledFrameConditionalRecall, 0)
        XCTAssertEqual(recall.actualShotCount, 1)
        XCTAssertEqual(recall.actualShotHits, 0)
        XCTAssertEqual(recall.actualShotRecall, 0)
    }
}
