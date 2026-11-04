import AppKit
import AstfindFaceCore
import XCTest
@testable import AstfindKit

final class FaceIndexerTests: XCTestCase {
    private var home: URL!
    private var mount: URL!
    private var databaseURL: URL!
    private var registry: SourceRegistry!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("astfind-face-\(UUID().uuidString)")
        mount = home.appendingPathComponent("mount")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        databaseURL = home.appendingPathComponent("registry.sqlite")
        registry = try SourceRegistry(databaseURL: databaseURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func makeImage(at url: URL) throws {
        let image = NSImage(size: NSSize(width: 112, height: 112))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 112, height: 112).fill()
        NSColor.black.setFill()
        NSRect(x: 30, y: 30, width: 52, height: 52).fill()
        image.unlockFocus()
        let representation = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let data = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }

    private func makeSource(name: String = "人物") throws -> SourceRecord {
        let source = try registry.registerSource(kind: .local, locator: mount.path, displayName: name)
        try registry.updateMount(sourceId: source.sourceId, mountPath: mount.path, online: true)
        try registry.setFaceIndexEnabled(sourceId: source.sourceId, enabled: true)
        return source
    }

    private func sync(asset: String, source: SourceRecord) throws {
        _ = try registry.syncAssets(sourceId: source.sourceId, scanRunId: "face-run",
                                   scanRunCompleted: true,
                                   entries: [(asset, "image", 123, 456)])
    }

    func testEnqueueRunSearchAndDisable() throws {
        let url = mount.appendingPathComponent("face.png")
        try makeImage(at: url)
        let source = try makeSource()
        try sync(asset: "face.png", source: source)
        let indexer = try FaceIndexer(databaseURL: databaseURL,
                                      embedder: FakeFaceEmbedder(),
                                      preprocessor: FakeFacePreprocessor())

        XCTAssertEqual(try indexer.enqueuePending(sourceId: source.sourceId), 1)
        XCTAssertEqual(try indexer.enqueuePending(sourceId: source.sourceId), 0, "同一 token 不重复入队")
        let summary = try indexer.runPending(limit: 10)
        XCTAssertEqual(summary.embedded, 1)
        XCTAssertEqual(summary.failed, 0)
        XCTAssertEqual(try indexer.embeddingCount(), 1)

        let hits = try indexer.search(vector: FakeFaceEmbedder.vector, limit: 5, minScore: 0)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.relativePath, "face.png")
        XCTAssertEqual(hits.first?.score ?? 0, 1.0, accuracy: 0.0001)

        try registry.setFaceIndexEnabled(sourceId: source.sourceId, enabled: false)
        XCTAssertEqual(try indexer.enqueuePending(sourceId: source.sourceId), 0, "关闭来源不再入队")
        XCTAssertEqual(try indexer.deleteAll(), 1)
        XCTAssertEqual(try indexer.embeddingCount(), 0)
    }

    func testNoFaceIsTerminalAndNotRequeued() throws {
        let url = mount.appendingPathComponent("blank.png")
        try makeImage(at: url)
        let source = try makeSource()
        try sync(asset: "blank.png", source: source)
        let indexer = try FaceIndexer(databaseURL: databaseURL,
                                      embedder: FakeFaceEmbedder(),
                                      preprocessor: NoFacePreprocessor())

        XCTAssertEqual(try indexer.enqueuePending(sourceId: source.sourceId), 1)
        let summary = try indexer.runPending(limit: 10)
        XCTAssertEqual(summary.noFace, 1)
        XCTAssertEqual(summary.embedded, 0)
        XCTAssertEqual(try indexer.enqueuePending(sourceId: source.sourceId), 0, "无人脸是终态，不反复排队")
    }

    func testFacePrefixOnlyEnqueuesScopedAssets() throws {
        let aDir = mount.appendingPathComponent("a")
        let bDir = mount.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: aDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bDir, withIntermediateDirectories: true)
        try makeImage(at: aDir.appendingPathComponent("one.png"))
        try makeImage(at: bDir.appendingPathComponent("two.png"))
        let source = try makeSource()
        _ = try registry.syncAssets(sourceId: source.sourceId, scanRunId: "prefix",
                                    scanRunCompleted: true,
                                    entries: [("a/one.png", "image", 1, 1),
                                              ("b/two.png", "image", 2, 2)])
        try registry.setFaceIndexPrefix(sourceId: source.sourceId, prefix: "a/")
        let indexer = try FaceIndexer(databaseURL: databaseURL,
                                      embedder: FakeFaceEmbedder(),
                                      preprocessor: FakeFacePreprocessor())
        XCTAssertEqual(try indexer.enqueuePending(sourceId: source.sourceId), 1, "只索引 a/ 前缀")
        XCTAssertEqual(try indexer.runPending(limit: 5).embedded, 1)
        let hits = try indexer.search(vector: FakeFaceEmbedder.vector, limit: 5, minScore: 0)
        XCTAssertEqual(hits.map(\.relativePath), ["a/one.png"])
    }

    func testVideoSamplingCoversLongVideosWithinFrameCap() {
        XCTAssertEqual(FaceVideoSampling.frameTimes(durationMs: 10_000, minIntervalMs: 2_000, maxFrames: 60),
                       [0, 2_000, 4_000, 6_000, 8_000])
        let long = FaceVideoSampling.frameTimes(durationMs: 600_000, minIntervalMs: 2_000, maxFrames: 60)
        XCTAssertEqual(long.count, 60)
        XCTAssertEqual(long.first, 0)
        XCTAssertEqual(long[1], 10_000, "10 分钟视频自适应到 10s 间隔，覆盖全片")
    }

    func testSearchKeepsBestFrameForSameAsset() throws {
        let url = mount.appendingPathComponent("face.png")
        try makeImage(at: url)
        let source = try makeSource()
        try sync(asset: "face.png", source: source)
        let indexer = try FaceIndexer(databaseURL: databaseURL,
                                      embedder: FakeFaceEmbedder(),
                                      preprocessor: FakeFacePreprocessor())
        XCTAssertEqual(try indexer.enqueuePending(sourceId: source.sourceId), 1)
        XCTAssertEqual(try indexer.runPending(limit: 5).embedded, 1)

        // 同一资产追加一个更强的“视频帧”向量（start_ms=2000）。
        var second = [Float](repeating: 0, count: 512)
        second[1] = 1
        let assetId = try XCTUnwrap(registry.assets(sourceId: source.sourceId).first).assetId
        let db = try Database(url: databaseURL)
        try db.run("""
            INSERT INTO face_embeddings
            (face_id, asset_id, source_id, relative_path, start_ms, bbox_json, quality,
             profile_id, vector_blob, content_change_token, created_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?)
            """, [.text(UUID().uuidString), .text(assetId), .text(source.sourceId),
                  .text("face.png"), .int(2_000), .text("{}"), .double(0.8),
                  .text("face-buffalo_sc-v1"),
                  .blob(second.withUnsafeBytes { Data($0) }), .text("123:456"), .int(0)])

        let hits = try indexer.search(vector: second, limit: 5, minScore: 0)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.startMs, 2_000, "同资产应保留最佳帧")
        XCTAssertEqual(hits.first?.score ?? 0, 1.0, accuracy: 0.0001)
    }

    func testModelUnavailableLeavesJobsPending() throws {
        let url = mount.appendingPathComponent("face.png")
        try makeImage(at: url)
        let source = try makeSource()
        try sync(asset: "face.png", source: source)
        let indexer = try FaceIndexer(databaseURL: databaseURL,
                                      embedder: nil,
                                      preprocessor: FakeFacePreprocessor())

        XCTAssertEqual(try indexer.enqueuePending(sourceId: source.sourceId), 1)
        let summary = try indexer.runPending(limit: 10)
        XCTAssertTrue(summary.modelUnavailable)
        XCTAssertEqual(try indexer.counts().pending, 1, "模型缺失时任务保留，模型就绪后继续")
    }
}

private struct FakeFaceEmbedder: FaceEmbeddingProviding {
    let profile: FaceProfile = .buffaloSC
    static let vector: [Float] = {
        var values = [Float](repeating: 0, count: 512)
        values[0] = 1
        return values
    }()

    func embed(alignedImage: CGImage) throws -> [Float] { Self.vector }
}

private struct FakeFacePreprocessor: FacePreprocessing {
    func process(image: CGImage) throws -> FacePreprocessResult {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 112, height: 112, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let aligned = try XCTUnwrap(context.makeImage())
        return FacePreprocessResult(
            faceCount: 1, selectedFaceIndex: 0, alignedImage: aligned,
            boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), quality: 0.9)
    }
}

private struct NoFacePreprocessor: FacePreprocessing {
    func process(image: CGImage) throws -> FacePreprocessResult {
        throw FaceAlignmentError.noFace
    }
}
