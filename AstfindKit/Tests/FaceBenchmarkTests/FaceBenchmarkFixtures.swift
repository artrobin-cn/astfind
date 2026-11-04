import Foundation
@testable import FaceBenchmarkCore

enum FaceBenchmarkFixtures {
    static func profile(dimension: Int = 512) -> FaceBenchmarkProfile {
        FaceBenchmarkProfile(
            detector: "vision-v1",
            alignment: "five-point-v1",
            preprocessing: "112-jpeg85-v1",
            model: "face-test-v1",
            dimension: dimension,
            normalization: "l2",
            quantization: "float32")
    }

    static func valid() -> FaceBenchmarkManifest {
        FaceBenchmarkManifest(
            profile: profile(),
            assets: [
                FaceBenchmarkAsset(
                    assetID: "asset-a1", path: "/private/a1.jpg", kind: .image,
                    personIDs: ["person-a"], condition: .frontal, startMs: nil),
                FaceBenchmarkAsset(
                    assetID: "asset-b1", path: "/private/b1.jpg", kind: .image,
                    personIDs: ["person-b"], condition: .lowLight, startMs: nil),
                FaceBenchmarkAsset(
                    assetID: "asset-v1", path: "/private/a.mov", kind: .videoFrame,
                    personIDs: ["person-a"], condition: .videoFrame, startMs: 1_000)
            ],
            queries: [
                FaceBenchmarkQuery(
                    queryID: "query-1", personID: "person-a", imagePath: "/private/query-a.jpg",
                    sourceAssetID: nil, selectedFaceIndex: 0, excludedAssetIDs: [], conditions: [.frontal]),
                FaceBenchmarkQuery(
                    queryID: "query-2", personID: "person-b", imagePath: "/private/query-b.jpg",
                    sourceAssetID: nil, selectedFaceIndex: 0, excludedAssetIDs: [], conditions: [.lowLight]),
                FaceBenchmarkQuery(
                    queryID: "query-unknown", personID: nil, imagePath: "/private/query-u.jpg",
                    sourceAssetID: nil, selectedFaceIndex: 0, excludedAssetIDs: [], conditions: [.frontal])
            ])
    }

    static func videoManifest() -> FaceBenchmarkManifest {
        FaceBenchmarkManifest(
            profile: profile(),
            assets: [
                FaceBenchmarkAsset(
                    assetID: "frame-a-0", path: "/private/a-0.jpg", kind: .videoFrame,
                    personIDs: ["person-a"], condition: .videoFrame, startMs: 0,
                    videoID: "video-a"),
                FaceBenchmarkAsset(
                    assetID: "frame-a-15", path: "/private/a-15.jpg", kind: .videoFrame,
                    personIDs: ["person-a"], condition: .videoFrame, startMs: 15_000,
                    videoID: "video-a"),
                FaceBenchmarkAsset(
                    assetID: "frame-b-0", path: "/private/b-0.jpg", kind: .videoFrame,
                    personIDs: ["person-a"], condition: .videoFrame, startMs: 0,
                    videoID: "video-b"),
                FaceBenchmarkAsset(
                    assetID: "frame-c-b", path: "/private/c-b.jpg", kind: .videoFrame,
                    personIDs: ["person-b"], condition: .videoFrame, startMs: 0,
                    videoID: "video-c")
            ],
            queries: [
                FaceBenchmarkQuery(
                    queryID: "query-a", personID: "person-a", imagePath: "/private/query-a.jpg",
                    sourceAssetID: nil, selectedFaceIndex: 0, excludedAssetIDs: [],
                    conditions: [.videoFrame]),
                FaceBenchmarkQuery(
                    queryID: "query-unknown", personID: nil, imagePath: "/private/query-u.jpg",
                    sourceAssetID: nil, selectedFaceIndex: 0, excludedAssetIDs: [],
                    conditions: [.videoFrame])
            ])
    }

    static func metricManifest() -> FaceBenchmarkManifest { valid() }

    static func metricResults() -> [FaceBenchmarkQueryResult] {
        [
            FaceBenchmarkQueryResult(queryID: "query-1", hits: [
                FaceBenchmarkHit(assetID: "asset-b1", score: 0.95),
                FaceBenchmarkHit(assetID: "asset-a1", score: 0.90),
                FaceBenchmarkHit(assetID: "asset-a1", score: 0.80),
                FaceBenchmarkHit(assetID: "asset-v1", score: 0.70)
            ], elapsedMs: 10),
            FaceBenchmarkQueryResult(queryID: "query-2", hits: [
                FaceBenchmarkHit(assetID: "asset-b1", score: 0.90)
            ], elapsedMs: 20),
            FaceBenchmarkQueryResult(queryID: "query-unknown", hits: [
                FaceBenchmarkHit(assetID: "asset-a1", score: 0.20)
            ], elapsedMs: 40)
        ]
    }
}
