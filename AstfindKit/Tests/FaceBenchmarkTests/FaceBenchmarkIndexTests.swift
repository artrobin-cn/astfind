import Foundation
import XCTest
@testable import FaceBenchmarkCore

final class FaceBenchmarkIndexTests: XCTestCase {
    private func index(dimension: Int = 2, generation: Int = 1) -> FaceBenchmarkIndex {
        FaceBenchmarkIndex(
            profile: FaceBenchmarkFixtures.profile(dimension: dimension),
            generation: generation)
    }

    func testSearchDeduplicatesAssetsAndUsesDeterministicOrdering() throws {
        var store = index()
        try store.append([
            FaceBenchmarkIndexRecord(faceID: "f1", assetID: "asset-a", vector: [1, 0]),
            FaceBenchmarkIndexRecord(faceID: "f2", assetID: "asset-a", vector: [-1, 0]),
            FaceBenchmarkIndexRecord(faceID: "f3", assetID: "asset-b", vector: [0, 1]),
            FaceBenchmarkIndexRecord(faceID: "f4", assetID: "asset-c", vector: [1, 0])
        ])

        let hits = try store.search(query: [1, 0], limit: 10, generation: 1)
        XCTAssertEqual(hits.map(\.assetID), ["asset-a", "asset-c", "asset-b"])
        XCTAssertEqual(hits.map(\.score), [1, 1, 0])
        XCTAssertEqual(store.assetCount, 3)
        XCTAssertEqual(store.vectorCount, 4)
    }

    func testSearchAppliesThresholdAndPreservesVideoMetadata() throws {
        var store = index()
        try store.append([
            FaceBenchmarkIndexRecord(
                faceID: "f1", assetID: "frame-1", vector: [1, 0],
                videoID: "video-a", startMs: 10_000),
            FaceBenchmarkIndexRecord(
                faceID: "f2", assetID: "frame-2", vector: [0, 1],
                videoID: "video-a", startMs: 20_000)
        ])

        let hits = try store.search(query: [1, 0], limit: 10, threshold: 0.5, generation: 1)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].assetID, "frame-1")
        XCTAssertEqual(hits[0].videoID, "video-a")
        XCTAssertEqual(hits[0].startMs, 10_000)
    }

    func testRejectsDimensionGenerationDuplicateAndNonFiniteVectors() throws {
        var store = index()
        XCTAssertThrowsError(try store.append(
            FaceBenchmarkIndexRecord(faceID: "f1", assetID: "a", vector: [1, 0, 0])
        )) {
            XCTAssertEqual($0 as? FaceBenchmarkIndexError, .invalidDimension(expected: 2, actual: 3))
        }

        try store.append(FaceBenchmarkIndexRecord(faceID: "f1", assetID: "a", vector: [1, 0]))
        XCTAssertThrowsError(try store.append(
            FaceBenchmarkIndexRecord(faceID: "f1", assetID: "b", vector: [0, 1])
        )) {
            XCTAssertEqual($0 as? FaceBenchmarkIndexError, .duplicateFaceID("f1"))
        }
        XCTAssertThrowsError(try store.append(
            FaceBenchmarkIndexRecord(faceID: "f2", assetID: "b", vector: [.nan, 0])
        )) {
            XCTAssertEqual($0 as? FaceBenchmarkIndexError, .invalidVector("f2"))
        }
        XCTAssertThrowsError(try store.search(query: [1, 0], limit: 10, generation: 2)) {
            XCTAssertEqual($0 as? FaceBenchmarkIndexError, .generationMismatch(expected: 1, actual: 2))
        }
        XCTAssertThrowsError(try store.search(query: [1, 0, 0], limit: 10, generation: 1)) {
            XCTAssertEqual($0 as? FaceBenchmarkIndexError, .invalidDimension(expected: 2, actual: 3))
        }
    }

    func testAtomicPersistenceRoundTripAndInvalidWriteKeepsExistingFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("index.json")

        var store = index()
        try store.append([
            FaceBenchmarkIndexRecord(
                faceID: "f1", assetID: "asset-a", vector: [1, 0],
                videoID: "video-a", startMs: 1_000)
        ])
        try store.write(to: url)
        let loaded = try FaceBenchmarkIndex.load(from: url)
        XCTAssertEqual(loaded, store)
        XCTAssertTrue(try store.encodedData().count > 0)

        let invalid = FaceBenchmarkIndex(
            profile: FaceBenchmarkFixtures.profile(dimension: 2),
            generation: 1,
            records: [FaceBenchmarkIndexRecord(faceID: "bad", assetID: "x", vector: [1])])
        XCTAssertThrowsError(try invalid.write(to: url))
        XCTAssertEqual(try FaceBenchmarkIndex.load(from: url), store)
    }

    func testQueryCacheMissesWhenGenerationOrSelectedCropDigestChanges() {
        var cache = FaceBenchmarkQueryCache()
        let key = FaceBenchmarkQueryCacheKey(
            cropDigest: "crop-a",
            profileFingerprint: FaceBenchmarkFixtures.profile().fingerprint,
            generation: 1,
            mode: "query",
            threshold: 0.5,
            limit: 10)
        let hits = [FaceBenchmarkIndexHit(
            faceID: "f1", assetID: "asset-a", score: 0.9,
            videoID: nil, startMs: nil)]
        cache.store(hits, for: key)
        XCTAssertEqual(cache.hits(for: key), hits)

        let nextGeneration = FaceBenchmarkQueryCacheKey(
            cropDigest: "crop-a",
            profileFingerprint: FaceBenchmarkFixtures.profile().fingerprint,
            generation: 2,
            mode: "query",
            threshold: 0.5,
            limit: 10)
        XCTAssertNil(cache.hits(for: nextGeneration))

        let otherCrop = FaceBenchmarkQueryCacheKey(
            cropDigest: "crop-b",
            profileFingerprint: FaceBenchmarkFixtures.profile().fingerprint,
            generation: 1,
            mode: "query",
            threshold: 0.5,
            limit: 10)
        XCTAssertNil(cache.hits(for: otherCrop))
    }
}
