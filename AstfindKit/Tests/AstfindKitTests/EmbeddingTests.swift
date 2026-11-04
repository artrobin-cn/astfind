import XCTest
import AppKit
import ImageIO
@testable import AstfindKit

/// A2 图片语义：int8 量化/余弦检索/三段式入库/任务隔离/失败分类——Fake Provider 按图片平均色出向量，零网络。
final class EmbeddingTests: XCTestCase {
    /// 假向量 Provider：图片 → 平均 RGB（3 维）；文本按关键字映射到颜色轴。
    final class ColorProvider: EmbeddingProvider, @unchecked Sendable {
        let id = "color", displayName = "颜色向量（假）"
        var capabilities = ProviderCapabilities(embedText: true, embedImage: true, dimensions: 3, model: "color-v1")
        var failWith: ProviderError?
        /// 命中该颜色的图 → server(500)（毒图模拟：批请求带着它整批失败）
        var failVector: [Float]?
        /// 文本向量化人为时延（回归测试：模拟被入库流量占满的远端 Provider）。
        var textDelay: TimeInterval = 0
        /// 文本向量化失败注入（联合查询降级测试）。
        var textFailWith: ProviderError?
        /// 文本向量维度/内容注入（同空间校验测试）。
        var textVectorOverride: [Float]?
        /// 原生批量：true=一次调用记一个批次（请求分组证据）；false=逐图串行（协议默认回退）。
        var nativeBatch = false
        private let counterLock = NSLock()
        private(set) var imageCalls = 0
        private(set) var textCalls = 0
        private(set) var batchCalls: [Int] = []
        func probe() async -> ProviderProbe { .available(latencyMs: 1, capabilities: capabilities) }
        func embedText(_ text: String) async throws -> [Float] {
            counterLock.lock(); textCalls += 1; counterLock.unlock()
            if textDelay > 0 { try await Task.sleep(nanoseconds: UInt64(textDelay * 1_000_000_000)) }
            if let textFailWith { throw textFailWith }
            if let textVectorOverride { return textVectorOverride }
            if text.contains("红") { return [1, 0, 0] }
            if text.contains("蓝") { return [0, 0, 1] }
            return [0, 1, 0]
        }
        func embedImageData(_ data: Data, mime: String) async throws -> [Float] {
            counterLock.lock(); imageCalls += 1; counterLock.unlock()
            if let failWith { throw failWith }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ProviderError.invalidResponse("decode") }
            var pixel = [UInt8](repeating: 0, count: 4)
            let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let vector = [Float(pixel[0]) / 255, Float(pixel[1]) / 255, Float(pixel[2]) / 255]
            if let failVector, zip(vector, failVector).reduce(0.0, { $0 + abs($1.0 - $1.1) }) < 0.1 {
                throw ProviderError.server(500)   // 毒图：带着它的批请求整批 500（容差 0.1 吸收 JPEG 色噪）
            }
            return vector
        }
        func embedImagesData(_ batch: [(data: Data, mime: String)]) async throws -> [[Float]] {
            if nativeBatch { counterLock.lock(); batchCalls.append(batch.count); counterLock.unlock() }
            var vectors: [[Float]] = []
            for image in batch { vectors.append(try await embedImageData(image.data, mime: image.mime)) }
            return vectors
        }
    }

    private var home: URL!
    private var share: URL!
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("astfind-embed-\(UUID().uuidString)")
        share = home.appendingPathComponent("图库")
        try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private func makeColorImage(_ color: NSColor, at url: URL) throws {
        let size = NSSize(width: 64, height: 64)
        let image = NSImage(size: size)
        image.lockFocus(); color.setFill(); NSRect(origin: .zero, size: size).fill(); image.unlockFocus()
        let data = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }
    private let profile = EmbeddingIndexer.Profile.image(providerId: "color", model: "color-v1", dimension: 3)

    /// int8 量化往返：4096 维随机向量量化后与原向量余弦 >0.99；blob 点积≈余弦。
    func testQuantizationRoundtripPreservesCosine() {
        let vector = (0..<4096).map { _ in Float.random(in: -1...1) }
        let blob = EmbeddingIndexer.quantize(vector)
        XCTAssertEqual(blob.count, 4 + 4096, "4 字节刻度 + N 字节 int8")
        let restored = try! XCTUnwrap(EmbeddingIndexer.dequantize(blob))
        let unit = EmbeddingIndexer.normalized(vector)
        let cosine = zip(unit, EmbeddingIndexer.normalized(restored)).reduce(0) { $0 + $1.0 * $1.1 }
        XCTAssertGreaterThan(cosine, 0.99, "int8 量化误差可忽略：\(cosine)")
        var scratch = [Float](repeating: 0, count: 4096)
        let dot = try! XCTUnwrap(EmbeddingIndexer.dot(quantized: blob, query: unit, scratch: &scratch))
        XCTAssertEqual(dot, 1, accuracy: 0.02, "自身点积≈1")
        XCTAssertNil(EmbeddingIndexer.dot(quantized: blob, query: [1, 2, 3], scratch: &scratch), "维度不符拒绝")
    }

    /// 入库→检索：红图/蓝图各一，「红色」查询红图排首且分高；任务与内容泵互不认领。
    func testIngestAndSearchRankByColorWithJobIsolation() throws {
        try makeColorImage(.red, at: share.appendingPathComponent("红.png"))
        try makeColorImage(.blue, at: share.appendingPathComponent("蓝.png"))
        let engine = try AstfindEngine(home: home.appendingPathComponent("data"))
        engine.autoExtractContent = false
        let record = try engine.register(path: share.path, name: "图库")
        let semantic = try XCTUnwrap(engine.semantic)
        let provider = ColorProvider()
        try semantic.ensureProfile(profile)

        XCTAssertEqual(try semantic.enqueuePending(sourceId: record.sourceId, profile: profile), 2)
        _ = engine.extractContent(sourceId: record.sourceId, limit: 0)   // 内容任务也入队（OCR）
        XCTAssertEqual(try XCTUnwrap(engine.content).pendingCount(), 2, "内容泵只看 extract_text")
        XCTAssertEqual(try semantic.counts().pending, 2, "嵌入泵只看 embed_image")

        let summary = try semantic.runPending(limit: 25, sourceId: record.sourceId, lanes: 2, provider: provider, profile: profile)
        XCTAssertEqual(summary.embedded, 2)
        XCTAssertEqual(semantic.embeddingCount(profile: profile), 2)
        XCTAssertEqual(try XCTUnwrap(engine.content).pendingCount(), 2, "嵌入泵没有吞掉内容任务")
        XCTAssertEqual(try semantic.counts().done, 2)

        let redQuery = try awaitValue { try await provider.embedText("红色的图片") }
        let hits = try semantic.search(queryVector: redQuery, profile: profile, limit: 5)
        XCTAssertEqual(hits.first?.relativePath, "红.png", "\(hits)")
        XCTAssertGreaterThan(hits[0].score, hits[1].score)
        XCTAssertGreaterThan(hits[0].score, 0.9, "红图与红轴几乎同向：\(hits[0].score)")
        let blueQuery = try awaitValue { try await provider.embedText("蓝色") }
        XCTAssertEqual(try semantic.search(queryVector: blueQuery, profile: profile, limit: 1).first?.relativePath, "蓝.png")

        // 幂等：同 token 已有向量 → 不再入队；向量被清 → 重新入队
        XCTAssertEqual(try semantic.enqueuePending(sourceId: record.sourceId, profile: profile), 0)
        engine.stop()
    }

    /// 批量入库（2026-10-21 WeMM 实测 2.5~2.9x）：能力>1 按批分组单请求（批次大小为证）；
    /// 能力缺省回退协议默认逐图串行——自定义 Provider 零改动照常工作。
    func testRunPendingBatchesWhenCapableAndFallsBackOtherwise() throws {
        for (name, color) in [("红1", NSColor.red), ("红2", NSColor.red), ("蓝1", NSColor.blue), ("蓝2", NSColor.blue)] {
            try makeColorImage(color, at: share.appendingPathComponent("\(name).png"))
        }

        // ① 原生批量：batchImages=2 → 4 图分 2 批
        let engineA = try AstfindEngine(home: home.appendingPathComponent("data-a"))
        engineA.autoExtractContent = false
        let recordA = try engineA.register(path: share.path, name: "图库A")
        let semanticA = try XCTUnwrap(engineA.semantic)
        try semanticA.ensureProfile(profile)
        XCTAssertEqual(try semanticA.enqueuePending(sourceId: recordA.sourceId, profile: profile), 4)
        let batchy = ColorProvider(); batchy.capabilities.batchImages = 2; batchy.nativeBatch = true
        let summaryA = try semanticA.runPending(limit: 25, sourceId: recordA.sourceId, lanes: 2, provider: batchy, profile: profile)
        XCTAssertEqual(summaryA.embedded, 4)
        XCTAssertEqual(batchy.batchCalls.sorted(), [2, 2], "4 图按批量 2 分两批，实际批次：\(batchy.batchCalls)")
        XCTAssertEqual(semanticA.embeddingCount(profile: profile), 4)

        // 检索仍正确：红向量命中的高分项恰为两张红图（蓝图 0 分不入高分集）
        let redHits = try semanticA.search(queryVector: [1, 0, 0], profile: profile, limit: 4)
        XCTAssertEqual(Set(redHits.filter { $0.score > 0.9 }.map(\.relativePath)), ["红1.png", "红2.png"], "\(redHits)")
        engineA.stop()

        // ② 串行回退：默认能力（batchImages=0）→ 逐图 embedImageData，无批量调用
        let engineB = try AstfindEngine(home: home.appendingPathComponent("data-b"))
        engineB.autoExtractContent = false
        let recordB = try engineB.register(path: share.path, name: "图库B")
        let semanticB = try XCTUnwrap(engineB.semantic)
        try semanticB.ensureProfile(profile)
        XCTAssertEqual(try semanticB.enqueuePending(sourceId: recordB.sourceId, profile: profile), 4)
        let serial = ColorProvider()   // nativeBatch=false：协议默认回退路径
        let summaryB = try semanticB.runPending(limit: 25, sourceId: recordB.sourceId, lanes: 2, provider: serial, profile: profile)
        XCTAssertEqual(summaryB.embedded, 4)
        XCTAssertTrue(serial.batchCalls.isEmpty, "未声明批量能力不得走批量请求")
        XCTAssertEqual(serial.imageCalls, 4, "回退为逐图串行")
        XCTAssertEqual(semanticB.embeddingCount(profile: profile), 4)
        engineB.stop()
    }

    /// 批量失败放大与二分隔离（2026-10-21 NAS 源实弹：整批 25 张被个别毒图拖成
    /// transient=25、embedded=0）。4 图一批其中 1 张毒图：批 500 → 二分 → 好图入库、
    /// 毒图单独留队（环境类），批次轨迹 [4,2,2,1,1] 为证。
    func testBatchBisectionIsolatesPoisonImage() throws {
        for (name, color) in [("红1", NSColor.red), ("红2", NSColor.red), ("毒绿", NSColor.green), ("红3", NSColor.red)] {
            try makeColorImage(color, at: share.appendingPathComponent("\(name).png"))
        }
        let engine = try AstfindEngine(home: home.appendingPathComponent("data"))
        engine.autoExtractContent = false
        let record = try engine.register(path: share.path, name: "图库")
        let semantic = try XCTUnwrap(engine.semantic)
        try semantic.ensureProfile(profile)
        XCTAssertEqual(try semantic.enqueuePending(sourceId: record.sourceId, profile: profile), 4)

        let poisoned = ColorProvider()
        poisoned.capabilities.batchImages = 4
        poisoned.nativeBatch = true
        poisoned.failVector = [0, 1, 0]   // 绿图 → server(500)
        let summary = try semantic.runPending(limit: 25, sourceId: record.sourceId, lanes: 2, provider: poisoned, profile: profile)
        XCTAssertEqual(summary.embedded, 3, "毒图二分隔离，好图不陪葬")
        XCTAssertEqual(summary.transientFailures, 1, "毒图单独环境类失败留队")
        XCTAssertEqual(summary.failed, 0)
        XCTAssertTrue(summary.lastFailure?.contains("server") == true, "\(summary.lastFailure ?? "nil")")
        XCTAssertEqual(poisoned.batchCalls.sorted(), [1, 1, 2, 2, 4], "二分轨迹：整批→两半→再两半，实际 \(poisoned.batchCalls)")
        XCTAssertEqual(semantic.embeddingCount(profile: profile), 3)
        engine.stop()
    }

    /// 毒图隔离（2026-10-21 NAS 实弹：一张图让 WeMM 恒 502，"留队重试"语义变成每轮空转）：
    /// 健康证据窗内的失败记笔，满 10 笔终态 failed；纯宕机（无任何成功）不记笔不误杀。
    func testPoisonImageQuarantinedAfterStrikesButOutageNeverKills() throws {
        // 场景 A：毒图 + 好图混跑 → 好图入库建立健康证据 → 毒图记笔累积 → 10 笔隔离
        for (name, color) in [("红1", NSColor.red), ("毒绿", NSColor.green), ("红2", NSColor.red), ("红3", NSColor.red)] {
            try makeColorImage(color, at: share.appendingPathComponent("\(name).png"))
        }
        let engineA = try AstfindEngine(home: home.appendingPathComponent("data-a"))
        engineA.autoExtractContent = false
        let recordA = try engineA.register(path: share.path, name: "图库A")
        let semanticA = try XCTUnwrap(engineA.semantic)
        try semanticA.ensureProfile(profile)
        _ = try semanticA.enqueuePending(sourceId: recordA.sourceId, profile: profile)
        let poisoned = ColorProvider()
        poisoned.capabilities.batchImages = 4
        poisoned.nativeBatch = true
        poisoned.failVector = [0, 1, 0]
        var summary = try semanticA.runPending(limit: 25, sourceId: recordA.sourceId, lanes: 2, provider: poisoned, profile: profile)
        XCTAssertEqual(summary.embedded, 3)
        XCTAssertEqual(summary.transientFailures, 1, "毒图首轮：环境类留队记 1 笔")
        // 后续轮：只剩毒图，靠首轮成功建立的健康证据继续记笔
        var rounds = 1
        while rounds < 12 {
            summary = try semanticA.runPending(limit: 25, sourceId: recordA.sourceId, lanes: 2, provider: poisoned, profile: profile)
            rounds += 1
            if summary.quarantined > 0 { break }
        }
        XCTAssertEqual(rounds, EmbeddingIndexer.quarantineStrikes, "恰在第 \(EmbeddingIndexer.quarantineStrikes) 笔隔离（首轮 1 笔 + 毒图独轮逐笔）")
        let countsA = try semanticA.counts()
        XCTAssertEqual(countsA.pending, 0, "毒图记满 10 笔终态，队列清空")
        XCTAssertEqual(countsA.failed, 1)
        XCTAssertEqual(semanticA.embeddingCount(profile: profile), 3, "好图三张安然无恙")
        engineA.stop()

        // 场景 B：纯宕机（全部 503，从未有过成功）→ 不记笔，反复重试不误杀
        let engineB = try AstfindEngine(home: home.appendingPathComponent("data-b"))
        engineB.autoExtractContent = false
        let recordB = try engineB.register(path: share.path, name: "图库B")
        let semanticB = try XCTUnwrap(engineB.semantic)
        try semanticB.ensureProfile(profile)
        _ = try semanticB.enqueuePending(sourceId: recordB.sourceId, profile: profile)
        let dead = ColorProvider(); dead.failWith = .server(503)
        for _ in 0..<3 {
            _ = try semanticB.runPending(limit: 25, sourceId: recordB.sourceId, lanes: 2, provider: dead, profile: profile)
        }
        let countsB = try semanticB.counts()
        XCTAssertEqual(countsB.pending, 4, "宕机期间全员留队（零健康证据不记笔）")
        XCTAssertEqual(countsB.failed, 0)
        engineB.stop()
    }

    /// 失败分类进任务态：环境类（503）留队待重试并计 transient；配置类（401）终态 failed。
    func testTransientFailureStaysPendingAndConfigFailureIsTerminal() throws {
        try makeColorImage(.green, at: share.appendingPathComponent("绿.png"))
        let engine = try AstfindEngine(home: home.appendingPathComponent("data"))
        engine.autoExtractContent = false
        let record = try engine.register(path: share.path, name: "图库")
        let semantic = try XCTUnwrap(engine.semantic)
        try semantic.ensureProfile(profile)
        _ = try semantic.enqueuePending(sourceId: record.sourceId, profile: profile)

        let flaky = ColorProvider(); flaky.failWith = .server(503)
        let first = try semantic.runPending(sourceId: record.sourceId, provider: flaky, profile: profile)
        XCTAssertEqual(first.transientFailures, 1); XCTAssertEqual(first.failed, 0)
        XCTAssertEqual(try semantic.counts().pending, 1, "环境类失败留队")

        let broken = ColorProvider(); broken.failWith = .unauthorized
        let second = try semantic.runPending(sourceId: record.sourceId, provider: broken, profile: profile)
        XCTAssertEqual(second.failed, 1)
        XCTAssertEqual(try semantic.counts().failed, 1, "配置类失败终态")
        XCTAssertEqual(semantic.embeddingCount(profile: profile), 0)
        engine.stop()
    }

    private func awaitValue<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultHolder<T>()
        Task { box.value = await Result { try await body() }; semaphore.signal() }
        semaphore.wait()
        return try XCTUnwrap(box.value).get()
    }
}

final class ResultHolder<U>: @unchecked Sendable { var value: Result<U, Error>? }

extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
