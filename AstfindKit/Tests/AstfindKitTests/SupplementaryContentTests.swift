import XCTest
import AppKit
import OilFindCore
@testable import AstfindPanel
@testable import AstfindKit

/// GUI 内容检索链路的无头版（2026-10-19 反馈：面板搜不到图片里的文字）：
/// 图片 → Vision OCR → trigram FTS → ContentSupplementaryProvider →
/// SupplementaryHit（entryID 可反查回源 store，供面板渲染/打开/离线禁开）。
/// 面板接线本身在 vendored AppDelegate:60（supplementaryProvider = 扩展提供者）。
final class SupplementaryContentTests: XCTestCase {
    private var home: URL!
    private var share: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("astfind-supplementary-\(UUID().uuidString)")
        share = home.appendingPathComponent("贺卡")
        try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func makeImage(text: String, at url: URL) throws {
        let size = NSSize(width: 480, height: 140)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        (text as NSString).draw(at: NSPoint(x: 30, y: 50),
            withAttributes: [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black])
        image.unlockFocus()
        let data = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?
            .representation(using: .png, properties: [:]))
        try data.write(to: url)
    }

    /// 2026-10-22 开发者实弹反馈：类别页签（图片/视频/…）对补充命中不生效——「视频」页签下
    /// 混入图片语义行。补充命中必须与主结果用同一张扩展名类别表过滤。
    func testKindFilterAppliesToSupplementaryHits() throws {
        try makeImage(text: "红色感恩教师节", at: share.appendingPathComponent("贺卡.png"))
        try "红色感恩说明文档".write(to: share.appendingPathComponent("说明.txt"),
                                     atomically: true, encoding: .utf8)
        let engine = try AstfindEngine(home: home.appendingPathComponent("data"))
        engine.autoExtractContent = false
        _ = try engine.register(path: share.path, name: "贺卡素材")
        _ = try XCTUnwrap(engine.extractContent())
        let sources = engine.sources()
        let provider = ContentSupplementaryProvider(engine: engine)

        func kinds(_ options: SearchOptions) -> Set<String> {
            let hits = provider.prepareSearch(Query.parse("红色感恩"), options: options,
                                              sources: sources, isCancelled: { false })()
            return Set(hits.map(\.detail))
        }
        let both = kinds(SearchOptions())
        XCTAssertEqual(both.count, 2, "全部：图片OCR 与正文命中都在场：\(both)")
        XCTAssertTrue(both.contains { $0.contains("图片OCR") })
        XCTAssertTrue(both.contains { $0.contains("正文") })

        XCTAssertEqual(kinds(SearchOptions(kind: 4)), both.filter { $0.contains("图片OCR") },
                       "图片页签：只剩图片命中")
        XCTAssertEqual(kinds(SearchOptions(kind: 3)), both.filter { $0.contains("正文") },
                       "文档页签：只剩文档命中")
        XCTAssertTrue(kinds(SearchOptions(kind: 5)).isEmpty, "视频页签：无视频资产应清空")

        // 类别表与上游分类一致（镜像自 Classifier.extGroups，防漂移抽查）
        XCTAssertEqual(ContentSupplementaryProvider.kindByExtension["mp4"], 5)
        XCTAssertEqual(ContentSupplementaryProvider.kindByExtension["txt"], 3)
        XCTAssertEqual(ContentSupplementaryProvider.kindByExtension["jpeg"], 4)
        XCTAssertNil(ContentSupplementaryProvider.kindByExtension["xyz"], "未知扩展=0 类不误报")
        engine.stop()
    }

    /// 2026-10-21 面板 0 结果回归锚定：语义段绝不能拖慢内容命中。
    /// 慢文本向量（2s，模拟 WeMM 被入库泵占满）下：第一波闭包必须 <1s 返回 OCR 命中、
    /// 无语义行；引擎后台算完以 onSupplementaryRefresh 通知宿主重跑，第二波同查询
    /// 即时并入语义行（走缓存，同样 <1s）。
    func testSemanticStageNeverDelaysContentHits() throws {
        // 同一张图同时喂两条通道：OCR 文本含「红色感恩」，纯红图向量走语义
        try makeImage(text: "红色感恩教师节", at: share.appendingPathComponent("贺卡.png"))
        try makeSolidColorImage(.red, at: share.appendingPathComponent("红.png"))
        let engine = try AstfindEngine(home: home.appendingPathComponent("data"))
        engine.autoExtractContent = false
        let record = try engine.register(path: share.path, name: "贺卡素材")
        _ = try XCTUnwrap(engine.extractContent())

        let slow = EmbeddingTests.ColorProvider(); slow.textDelay = 2
        engine.providers.addEmbeddingProvider(slow)
        engine.providers.record(probe: .available(latencyMs: 1, capabilities: slow.capabilities), id: slow.id)
        let semantic = try XCTUnwrap(engine.semantic)
        let profile = EmbeddingIndexer.Profile.image(providerId: "color", model: "color-v1", dimension: 3)
        try semantic.ensureProfile(profile)
        _ = try semantic.enqueuePending(sourceId: record.sourceId, profile: profile)
        XCTAssertEqual(try semantic.runPending(limit: 25, sourceId: record.sourceId, lanes: 2, provider: slow, profile: profile).embedded, 2)
        engine.setSemanticSearch(enabled: true, persist: false)

        let sources = engine.sources()
        let provider = ContentSupplementaryProvider(engine: engine)
        let refreshed = expectation(description: "异步语义命中就绪回调宿主")
        engine.onSupplementaryRefresh = { refreshed.fulfill() }

        // 第一波：语义还在后台算，内容命中必须立即在场
        let began1 = CFAbsoluteTimeGetCurrent()
        let wave1 = provider.prepareSearch(Query.parse("红色感恩"), options: SearchOptions(),
                                           sources: sources, isCancelled: { false })()
        let elapsed1 = CFAbsoluteTimeGetCurrent() - began1
        XCTAssertTrue(wave1.contains { $0.detail.contains("图片OCR") }, "内容命中必须在场：\(wave1.map(\.detail))")
        XCTAssertFalse(wave1.contains { $0.detail.contains("语义") }, "语义未算完不得出现")
        XCTAssertLessThan(elapsed1, 1.0, "内容命中不得被语义拖慢（翻车实况：闭包要等 2s+）：\(elapsed1)")

        wait(for: [refreshed], timeout: 20)

        // 第二波（宿主收到通知后重跑同查询）：缓存命中，语义行即时并入
        let began2 = CFAbsoluteTimeGetCurrent()
        let wave2 = provider.prepareSearch(Query.parse("红色感恩"), options: SearchOptions(),
                                           sources: sources, isCancelled: { false })()
        XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - began2, 1.0)
        XCTAssertTrue(wave2.contains { $0.detail.contains("图片OCR") }, "内容命中仍在场")
        XCTAssertTrue(wave2.contains { $0.detail.contains("语义") }, "语义行应从缓存并入：\(wave2.map(\.detail))")
        engine.stop()
    }

    private func makeSolidColorImage(_ color: NSColor, at url: URL) throws {
        let size = NSSize(width: 64, height: 64)
        let image = NSImage(size: size)
        image.lockFocus(); color.setFill(); NSRect(origin: .zero, size: size).fill(); image.unlockFocus()
        let data = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?
            .representation(using: .png, properties: [:]))
        try data.write(to: url)
    }

    /// M0.7b：参考图 + 文字走同一 Provider/profile 的融合检索；结果带“图+文”标签与视频时间码。
    func testJointImageQueryFusesTextAndLabelsHits() throws {
        try makeSolidColorImage(.red, at: share.appendingPathComponent("红.png"))
        try makeSolidColorImage(.blue, at: share.appendingPathComponent("蓝.png"))
        let engine = try AstfindEngine(home: home.appendingPathComponent("data"))
        engine.autoExtractContent = false
        let record = try engine.register(path: share.path, name: "图库")
        let semantic = try XCTUnwrap(engine.semantic)
        let provider = EmbeddingTests.ColorProvider()
        let profile = EmbeddingIndexer.Profile.image(providerId: "color", model: "color-v1", dimension: 3)
        try semantic.ensureProfile(profile)
        XCTAssertEqual(try semantic.enqueuePending(sourceId: record.sourceId, profile: profile), 2)
        _ = try semantic.runPending(limit: 25, sourceId: record.sourceId, lanes: 2,
                                    provider: provider, profile: profile)
        engine.providers.addEmbeddingProvider(provider)
        engine.providers.record(probe: .available(latencyMs: 1, capabilities: provider.capabilities), id: provider.id)
        engine.setSemanticSearch(enabled: true, persist: false)

        let supplementary = ContentSupplementaryProvider(engine: engine)
        XCTAssertTrue(supplementary.acceptImageQuery(try Data(contentsOf: share.appendingPathComponent("红.png"))))
        let sources = engine.sources()
        var result: (hits: [SupplementaryHit], phase: JointImageQueryPhase) = ([], .analyzing)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            result = supplementary.jointImageHits(for: "蓝", sources: sources, kind: nil, isCancelled: { false })
            if case .ready = result.phase { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard case .ready(let count, let mode, let fallback) = result.phase else {
            return XCTFail("\(result.phase)")
        }
        XCTAssertEqual(mode, .fused)
        XCTAssertNil(fallback)
        XCTAssertEqual(count, result.hits.count)
        XCTAssertGreaterThan(count, 0)
        XCTAssertTrue(result.hits.allSatisfy { $0.detail.hasPrefix("【图+文 · 相似度") },
                      "\(result.hits.map(\.detail))")
        XCTAssertEqual(result.hits.first?.mediaStartMs, nil, "图片命中没有视频时间码")
        engine.stop()
    }

    /// 扫描期间 store.version 持续变化：图片/联合结果只应在“来源集合被替换”时丢弃，
    /// 不能因为版本推进把整批结果卡在 analyzing（2026-10-31 实弹）。
    func testImagePresentationSourceCheckIgnoresVersionChurn() throws {
        let engine = try AstfindEngine(home: home.appendingPathComponent("data"))
        _ = try engine.register(path: share.path, name: "版本抖动")
        let source = try XCTUnwrap(engine.sources().first)
        let presentation = SearchPresentation(sources: [source])
        source.store.version &+= 1
        XCTAssertTrue(presentation.sameStores(as: [source]), "版本推进不应丢弃图片结果")
        XCTAssertFalse(presentation.isCurrent([source]), "文本通道仍按版本严格校验")
        engine.stop()
    }

    func testPanelSupplementaryChannelReturnsResolvableContentHits() throws {
        try makeImage(text: "教师节快乐 感恩老师", at: share.appendingPathComponent("贺卡.png"))
        try "中秋节 副券编号 A-1024".write(to: share.appendingPathComponent("说明.txt"),
                                          atomically: true, encoding: .utf8)

        let engine = try AstfindEngine(home: home.appendingPathComponent("data"))
        engine.autoExtractContent = false
        _ = try engine.register(path: share.path, name: "贺卡素材")
        let summary = try XCTUnwrap(engine.extractContent())
        XCTAssertEqual(summary.failed, 0)

        let sources = engine.sources()
        XCTAssertTrue(sources.allSatisfy(\.isOnline))

        // ① 图片 OCR 命中：entryID 必须能反查回源 store 的真实文件（面板渲染的前提）
        let provider = ContentSupplementaryProvider(engine: engine)
        let work = provider.prepareSearch(Query.parse("教师节快乐"), options: SearchOptions(),
                                          sources: sources, isCancelled: { false })
        let hits = work()
        let hit = try XCTUnwrap(hits.first, "面板补充通道应返回图片 OCR 命中")
        XCTAssertTrue(hit.detail.contains("图片OCR"), "匹配说明要标明命中类型，实际：\(hit.detail)")
        let source = try XCTUnwrap(sources.first { $0.id == hit.sourceID })
        let path = source.store.path(hit.entryID)
        XCTAssertTrue(path.hasSuffix("贺卡.png"), "entry 反查路径 \(path)")

        // ② 正文（txt）命中同一通道
        let docHits = provider.prepareSearch(Query.parse("副券"), options: SearchOptions(),
                                             sources: sources, isCancelled: { false })()
        XCTAssertTrue(docHits.contains { $0.detail.contains("正文") })

        // ③ 查询代次取消：旧查询的闭包必须立即返回空，不产生过期结果
        let cancelled = provider.prepareSearch(Query.parse("教师节"), options: SearchOptions(),
                                               sources: sources, isCancelled: { true })()
        XCTAssertTrue(cancelled.isEmpty)

        engine.stop()
    }
}
