import AstfindFaceCore
import CoreGraphics
import Foundation
import XCTest
@testable import FaceBenchmarkCore

private struct FakePreprocessor: FaceBenchmarkPreprocessing {
    let facesByWidth: [Int: [FaceBenchmarkPreprocessedFace]]
    let failWidths: Set<Int>

    init(
        facesByWidth: [Int: [FaceBenchmarkPreprocessedFace]],
        failWidths: Set<Int> = []
    ) {
        self.facesByWidth = facesByWidth
        self.failWidths = failWidths
    }

    func process(image: CGImage) throws -> [FaceBenchmarkPreprocessedFace] {
        if failWidths.contains(image.width) {
            throw FaceAlignmentError.noFace
        }
        guard let faces = facesByWidth[image.width] else {
            throw FaceAlignmentError.noFace
        }
        return faces
    }
}

private final class FakeEmbedder: FaceBenchmarkEmbedder {
    let modelIdentifier = "fake-model"
    let dimension: Int
    var failureCall: Int?
    var vectorCountOverride: Int?
    var vectorDimensionOverride: Int?
    private(set) var calls = 0

    init(dimension: Int) {
        self.dimension = dimension
    }

    func embed(images: [CGImage]) throws -> [[Float]] {
        calls += 1
        if let failureCall, calls == failureCall {
            throw FaceBenchmarkEmbedderTestError.expected
        }
        let count = vectorCountOverride ?? images.count
        return (0..<count).map { index in
            let dimension = vectorDimensionOverride ?? self.dimension
            return (0..<dimension).map { component in
                if component == 0 {
                    return Float(images[index % images.count].width + index)
                }
                return 0
            }
        }
    }
}

private enum FaceBenchmarkEmbedderTestError: Error {
    case expected
}

final class FaceBenchmarkRunnerTests: XCTestCase {
    private let policy = FaceBenchmarkFaceSelectionPolicy(
        minimumFaceSidePixels: 0,
        minimumConfidence: 0,
        maximumFacesPerAsset: 20)

    private func alignedImage(width: Int) -> CGImage {
        FaceTestImages.solid(width: width, height: 1, red: 1, green: 2, blue: 3)
    }

    private func face(marker: Int, area: CGFloat) -> FaceBenchmarkPreprocessedFace {
        FaceBenchmarkPreprocessedFace(
            region: FaceBenchmarkFaceRegion(
                detectionIndex: marker,
                boundingBox: CGRect(x: 0, y: 0, width: area, height: area),
                confidence: 1,
                pixelWidth: 100 * Double(area),
                pixelHeight: 100 * Double(area)),
            alignedImage: alignedImage(width: marker))
    }

    private func preprocessor(
        _ mapping: [Int: [FaceBenchmarkPreprocessedFace]],
        failWidths: Set<Int> = []
    ) -> FakePreprocessor {
        FakePreprocessor(facesByWidth: mapping, failWidths: failWidths)
    }

    private func loader(_ widths: [String: Int]) -> FaceBenchmarkImageLoader {
        FaceBenchmarkImageLoader { path in
            guard let width = widths[path] else { throw FaceRuntimeTestError.missing }
            return FaceTestImages.solid(width: width, height: 1, red: 0, green: 0, blue: 0)
        }
    }

    private func manifest(
        dimension: Int = 2,
        assets: [FaceBenchmarkAsset],
        queries: [FaceBenchmarkQuery]
    ) -> FaceBenchmarkManifest {
        FaceBenchmarkManifest(
            profile: FaceBenchmarkFixtures.profile(dimension: dimension),
            assets: assets,
            queries: queries)
    }

    private func asset(
        _ id: String,
        path: String,
        person: String? = "person-a",
        videoID: String? = nil,
        startMs: Int? = nil
    ) -> FaceBenchmarkAsset {
        FaceBenchmarkAsset(
            assetID: id,
            path: path,
            kind: videoID == nil ? .image : .videoFrame,
            personIDs: person.map { [$0] } ?? [],
            condition: videoID == nil ? .frontal : .videoFrame,
            startMs: startMs,
            videoID: videoID)
    }

    private func query(
        _ id: String,
        path: String,
        person: String? = "person-a",
        selectedFaceIndex: Int = 0
    ) -> FaceBenchmarkQuery {
        FaceBenchmarkQuery(
            queryID: id,
            personID: person,
            imagePath: path,
            sourceAssetID: nil,
            selectedFaceIndex: selectedFaceIndex,
            excludedAssetIDs: [],
            conditions: [.frontal])
    }

    private func temporaryStore() -> (directory: URL, store: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return (directory, directory.appendingPathComponent("index.json"))
    }

    func testIndexesMultipleFacesPerAssetAndDeduplicatesSearchHits() throws {
        let temporary = temporaryStore()
        defer { try? FileManager.default.removeItem(at: temporary.directory) }
        let manifest = manifest(
            assets: [asset("asset-a", path: "width-200")],
            queries: [query("query-1", path: "width-300")])
        let embedder = FakeEmbedder(dimension: 2)
        let stats = try FaceBenchmarkRunner.index(
            manifest: manifest,
            storeURL: temporary.store,
            generation: 1,
            embedder: embedder,
            preprocessor: preprocessor([
                200: [face(marker: 10, area: 0.5), face(marker: 11, area: 0.4)]
            ]),
            policy: policy,
            imageLoader: loader(["width-200": 200]))
        XCTAssertEqual(stats.assetCount, 1)
        XCTAssertEqual(stats.indexedAssetCount, 1)
        XCTAssertEqual(stats.vectorCount, 2)

        let index = try FaceBenchmarkIndex.load(from: temporary.store)
        let run = try FaceBenchmarkRunner.query(
            manifest: manifest,
            index: index,
            generation: 1,
            embedder: FakeEmbedder(dimension: 2),
            preprocessor: preprocessor([
                300: [face(marker: 10, area: 0.5)]
            ]),
            policy: policy,
            limit: 10,
            threshold: nil,
            imageLoader: loader(["width-300": 300]))
        XCTAssertEqual(run.results.count, 1)
        XCTAssertEqual(run.results[0].hits.count, 1)
        XCTAssertEqual(run.results[0].hits.first?.assetID, "asset-a")
    }

    func testSelectedQueryFaceControlsWhichVectorIsSearched() throws {
        let temporary = temporaryStore()
        defer { try? FileManager.default.removeItem(at: temporary.directory) }
        let manifest = manifest(
            assets: [
                asset("asset-a", path: "asset-200"),
                asset("asset-b", path: "asset-201")
            ],
            queries: [
                query("query-1", path: "query-300", selectedFaceIndex: 1)
            ])
        _ = try FaceBenchmarkRunner.index(
            manifest: manifest,
            storeURL: temporary.store,
            generation: 1,
            embedder: FaceBenchmarkFixedEmbedder(vectors: [
                [1, 0], [0, 1]
            ]),
            preprocessor: preprocessor([
                200: [face(marker: 10, area: 0.5)],
                201: [face(marker: 11, area: 0.5)]
            ]),
            policy: policy,
            imageLoader: loader(["asset-200": 200, "asset-201": 201]))

        let index = try FaceBenchmarkIndex.load(from: temporary.store)
        let run = try FaceBenchmarkRunner.query(
            manifest: manifest,
            index: index,
            generation: 1,
            embedder: FaceBenchmarkFixedEmbedder(vectors: [[0, 1], [1, 0]]),
            preprocessor: preprocessor([
                300: [face(marker: 20, area: 0.5), face(marker: 21, area: 0.4)]
            ]),
            policy: policy,
            limit: 10,
            threshold: nil,
            imageLoader: loader(["query-300": 300]))
        XCTAssertEqual(run.results.first?.hits.first?.assetID, "asset-b")
        XCTAssertEqual(run.diagnostics.first?.selectedFaceIndex, 1)
        XCTAssertEqual(run.diagnostics.first?.faceCount, 2)
    }

    func testDimensionAndVectorCountMismatchesFailBeforeWritingStore() throws {
        let temporary = temporaryStore()
        defer { try? FileManager.default.removeItem(at: temporary.directory) }
        let manifest = manifest(
            dimension: 2,
            assets: [asset("asset-a", path: "width-200")],
            queries: [query("query-1", path: "width-300")])

        XCTAssertThrowsError(try FaceBenchmarkRunner.index(
            manifest: manifest,
            storeURL: temporary.store,
            generation: 1,
            embedder: FakeEmbedder(dimension: 3),
            preprocessor: preprocessor([200: [face(marker: 10, area: 0.5)]]),
            policy: policy,
            imageLoader: loader(["width-200": 200])
        )) {
            XCTAssertEqual($0 as? FaceBenchmarkRunnerError, .dimensionMismatch(expected: 2, actual: 3))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.store.path))

        let wrongCount = FakeEmbedder(dimension: 2)
        wrongCount.vectorCountOverride = 0
        XCTAssertThrowsError(try FaceBenchmarkRunner.index(
            manifest: manifest,
            storeURL: temporary.store,
            generation: 1,
            embedder: wrongCount,
            preprocessor: preprocessor([200: [face(marker: 10, area: 0.5)]]),
            policy: policy,
            imageLoader: loader(["width-200": 200])
        )) {
            XCTAssertEqual($0 as? FaceBenchmarkRunnerError, .vectorCountMismatch(expected: 1, actual: 0))
        }

        let wrongDimension = FakeEmbedder(dimension: 2)
        wrongDimension.vectorDimensionOverride = 3
        XCTAssertThrowsError(try FaceBenchmarkRunner.index(
            manifest: manifest,
            storeURL: temporary.store,
            generation: 1,
            embedder: wrongDimension,
            preprocessor: preprocessor([200: [face(marker: 10, area: 0.5)]]),
            policy: policy,
            imageLoader: loader(["width-200": 200])
        )) {
            XCTAssertEqual($0 as? FaceBenchmarkRunnerError, .invalidEmbedding("asset-a"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.store.path))
    }

    func testEmbedderFailureLeavesNoStoreAndPreservesExistingStore() throws {
        let temporary = temporaryStore()
        defer { try? FileManager.default.removeItem(at: temporary.directory) }
        try FileManager.default.createDirectory(
            at: temporary.directory,
            withIntermediateDirectories: true)

        var existing = FaceBenchmarkIndex(
            profile: FaceBenchmarkFixtures.profile(dimension: 2),
            generation: 1)
        try existing.append(FaceBenchmarkIndexRecord(
            faceID: "existing", assetID: "existing", vector: [1, 0]))
        try existing.write(to: temporary.store)

        let manifest = manifest(
            assets: [
                asset("asset-a", path: "width-200"),
                asset("asset-b", path: "width-201")
            ],
            queries: [query("query-1", path: "width-300")])
        let embedder = FakeEmbedder(dimension: 2)
        embedder.failureCall = 2
        XCTAssertThrowsError(try FaceBenchmarkRunner.index(
            manifest: manifest,
            storeURL: temporary.store,
            generation: 2,
            embedder: embedder,
            preprocessor: preprocessor([
                200: [face(marker: 10, area: 0.5)],
                201: [face(marker: 11, area: 0.5)]
            ]),
            policy: policy,
            imageLoader: loader(["width-200": 200, "width-201": 201])
        ))
        XCTAssertEqual(try FaceBenchmarkIndex.load(from: temporary.store), existing)
    }

    func testEmptyAssetIsSkippedAndNoFaceQueryBecomesEmptyResult() throws {
        let temporary = temporaryStore()
        defer { try? FileManager.default.removeItem(at: temporary.directory) }
        let manifest = manifest(
            assets: [
                asset("asset-empty", path: "blank-100"),
                asset("asset-a", path: "width-200")
            ],
            queries: [query("query-empty", path: "blank-101")])
        let stats = try FaceBenchmarkRunner.index(
            manifest: manifest,
            storeURL: temporary.store,
            generation: 1,
            embedder: FakeEmbedder(dimension: 2),
            preprocessor: preprocessor([200: [face(marker: 10, area: 0.5)]]),
            policy: policy,
            imageLoader: loader(["blank-100": 100, "width-200": 200]))
        XCTAssertEqual(stats.skippedAssetCount, 1)
        XCTAssertEqual(stats.indexedAssetCount, 1)

        let index = try FaceBenchmarkIndex.load(from: temporary.store)
        let run = try FaceBenchmarkRunner.query(
            manifest: manifest,
            index: index,
            generation: 1,
            embedder: FakeEmbedder(dimension: 2),
            preprocessor: preprocessor([:], failWidths: [101]),
            policy: policy,
            limit: 10,
            threshold: nil,
            imageLoader: loader(["blank-101": 101]))
        XCTAssertEqual(run.results.count, 1)
        XCTAssertTrue(run.results[0].hits.isEmpty)
        XCTAssertEqual(run.diagnostics[0].failureReason, "no_face")
    }

    func testUnknownQueryCanReturnNoHitsAfterThreshold() throws {
        let temporary = temporaryStore()
        defer { try? FileManager.default.removeItem(at: temporary.directory) }
        let manifest = manifest(
            assets: [asset("asset-a", path: "width-200")],
            queries: [query("query-unknown", path: "width-300", person: nil)])
        _ = try FaceBenchmarkRunner.index(
            manifest: manifest,
            storeURL: temporary.store,
            generation: 1,
            embedder: FakeEmbedder(dimension: 2),
            preprocessor: preprocessor([200: [face(marker: 10, area: 0.5)]]),
            policy: policy,
            imageLoader: loader(["width-200": 200]))
        let index = try FaceBenchmarkIndex.load(from: temporary.store)
        let run = try FaceBenchmarkRunner.query(
            manifest: manifest,
            index: index,
            generation: 1,
            embedder: FaceBenchmarkFixedEmbedder(vectors: [[0, 1]]),
            preprocessor: preprocessor([300: [face(marker: 20, area: 0.5)]]),
            policy: policy,
            limit: 10,
            threshold: 0.5,
            imageLoader: loader(["width-300": 300]))
        XCTAssertTrue(run.results[0].hits.isEmpty)
    }

    func testWrongGenerationFails() throws {
        let temporary = temporaryStore()
        defer { try? FileManager.default.removeItem(at: temporary.directory) }
        let manifest = manifest(
            assets: [asset("asset-a", path: "width-200")],
            queries: [query("query-1", path: "width-300")])
        _ = try FaceBenchmarkRunner.index(
            manifest: manifest,
            storeURL: temporary.store,
            generation: 1,
            embedder: FakeEmbedder(dimension: 2),
            preprocessor: preprocessor([200: [face(marker: 10, area: 0.5)]]),
            policy: policy,
            imageLoader: loader(["width-200": 200]))
        let index = try FaceBenchmarkIndex.load(from: temporary.store)
        XCTAssertThrowsError(try FaceBenchmarkRunner.query(
            manifest: manifest,
            index: index,
            generation: 2,
            embedder: FakeEmbedder(dimension: 2),
            preprocessor: preprocessor([:]),
            policy: policy,
            limit: 10,
            threshold: nil,
            imageLoader: loader([:])
        )) {
            XCTAssertEqual($0 as? FaceBenchmarkRunnerError, .generationMismatch(expected: 1, actual: 2))
        }
    }

    func testRepeatedIndexBuildIsDeterministic() throws {
        let temporary = temporaryStore()
        defer { try? FileManager.default.removeItem(at: temporary.directory) }
        let manifest = manifest(
            assets: [asset("asset-a", path: "width-200")],
            queries: [query("query-1", path: "width-300")])
        let first = temporary.directory.appendingPathComponent("first.json")
        let second = temporary.directory.appendingPathComponent("second.json")
        for store in [first, second] {
            _ = try FaceBenchmarkRunner.index(
                manifest: manifest,
                storeURL: store,
                generation: 1,
                embedder: FakeEmbedder(dimension: 2),
                preprocessor: preprocessor([200: [face(marker: 10, area: 0.5)]]),
                policy: policy,
                imageLoader: loader(["width-200": 200]))
        }
        XCTAssertEqual(
            try FaceBenchmarkIndex.load(from: first),
            try FaceBenchmarkIndex.load(from: second))
    }
    func testFastQueryPathUsesOnlySelectedFaceAndReportsFaceCount() throws {
        let temporary = temporaryStore()
        defer { try? FileManager.default.removeItem(at: temporary.directory) }
        let manifest = manifest(
            assets: [asset("asset-a", path: "width-200")],
            queries: [query("query-1", path: "width-300")])
        _ = try FaceBenchmarkRunner.index(
            manifest: manifest,
            storeURL: temporary.store,
            generation: 1,
            embedder: FakeEmbedder(dimension: 2),
            preprocessor: preprocessor([200: [face(marker: 10, area: 0.5)]]),
            policy: policy,
            imageLoader: loader(["width-200": 200]))
        let index = try FaceBenchmarkIndex.load(from: temporary.store)

        let selected = FaceBenchmarkSelectedFace(
            faceCount: 3,
            region: FaceBenchmarkFaceRegion(
                detectionIndex: 7,
                boundingBox: CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
                confidence: 1,
                pixelWidth: 100,
                pixelHeight: 100),
            alignedImage: alignedImage(width: 77))
        let run = try FaceBenchmarkRunner.query(
            manifest: manifest,
            index: index,
            generation: 1,
            embedder: FaceBenchmarkFixedEmbedder(vectors: [[1, 0]]),
            preprocessor: FailingPreprocessor(),
            policy: policy,
            limit: 10,
            threshold: nil,
            imageLoader: loader(["width-300": 300]),
            queryPreprocessor: FakeQueryPreprocessor(behavior: .selected(selected)))
        XCTAssertEqual(run.diagnostics[0].faceCount, 3)
        XCTAssertEqual(run.diagnostics[0].selectedFaceIndex, 0)
        XCTAssertEqual(run.results[0].hits.first?.assetID, "asset-a")
    }

    func testFastQueryPathMapsNoFaceAndOutOfRange() throws {
        let temporary = temporaryStore()
        defer { try? FileManager.default.removeItem(at: temporary.directory) }
        let manifest = manifest(
            assets: [asset("asset-a", path: "width-200")],
            queries: [query("query-1", path: "width-300", selectedFaceIndex: 2)])
        _ = try FaceBenchmarkRunner.index(
            manifest: manifest,
            storeURL: temporary.store,
            generation: 1,
            embedder: FakeEmbedder(dimension: 2),
            preprocessor: preprocessor([200: [face(marker: 10, area: 0.5)]]),
            policy: policy,
            imageLoader: loader(["width-200": 200]))
        let index = try FaceBenchmarkIndex.load(from: temporary.store)

        let empty = try FaceBenchmarkRunner.query(
            manifest: manifest,
            index: index,
            generation: 1,
            embedder: FakeEmbedder(dimension: 2),
            preprocessor: FailingPreprocessor(),
            policy: policy,
            limit: 10,
            threshold: nil,
            imageLoader: loader(["width-300": 300]),
            queryPreprocessor: FakeQueryPreprocessor(behavior: .noFace))
        XCTAssertTrue(empty.results[0].hits.isEmpty)
        XCTAssertEqual(empty.diagnostics[0].failureReason, "no_face")

        XCTAssertThrowsError(try FaceBenchmarkRunner.query(
            manifest: manifest,
            index: index,
            generation: 1,
            embedder: FakeEmbedder(dimension: 2),
            preprocessor: FailingPreprocessor(),
            policy: policy,
            limit: 10,
            threshold: nil,
            imageLoader: loader(["width-300": 300]),
            queryPreprocessor: FakeQueryPreprocessor(behavior: .outOfRange(2))
        )) {
            XCTAssertEqual(
                $0 as? FaceBenchmarkRunnerError,
                .selectedFaceOutOfRange(queryID: "query-1", faceCount: 2))
        }
    }

}

private final class FaceBenchmarkFixedEmbedder: FaceBenchmarkEmbedder {
    let modelIdentifier = "fixed"
    let dimension = 2
    let vectors: [[Float]]
    private var callIndex = 0

    init(vectors: [[Float]]) {
        self.vectors = vectors
    }

    func embed(images: [CGImage]) throws -> [[Float]] {
        let start = callIndex
        callIndex += images.count
        return images.indices.map { vectors[(start + $0) % vectors.count] }
    }
}

private enum FaceRuntimeTestError: Error {
    case missing
}

private struct FakeQueryPreprocessor: FaceBenchmarkQueryPreprocessing {
    enum Behavior {
        case selected(FaceBenchmarkSelectedFace)
        case noFace
        case outOfRange(Int)
    }
    let behavior: Behavior

    func processSelected(
        image: CGImage,
        selectedFaceIndex: Int,
        policy: FaceBenchmarkFaceSelectionPolicy
    ) throws -> FaceBenchmarkSelectedFace {
        switch behavior {
        case .selected(let face):
            return face
        case .noFace:
            throw FaceAlignmentError.noFace
        case .outOfRange(let count):
            throw FaceBenchmarkFaceSelectionError.selectedFaceOutOfRange(faceCount: count)
        }
    }
}

private struct FailingPreprocessor: FaceBenchmarkPreprocessing {
    func process(image: CGImage) throws -> [FaceBenchmarkPreprocessedFace] {
        throw FaceRunnerTestError.preprocessorShouldNotRun
    }
}

private enum FaceRunnerTestError: Error {
    case preprocessorShouldNotRun
}
