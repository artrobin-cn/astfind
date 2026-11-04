import XCTest
import AppKit
import AVFoundation
import OilFindCore
@testable import AstfindKit
@testable import AstfindPanel

/// M0.5 以图搜图：查询图归一化 → 图片向量 → 同一张向量表同时命中图片与视频帧；
/// 查询缓存、失败分类、面板按资产去重与相似度保序。
final class ImageQueryTests: XCTestCase {
    private var home: URL!
    private var share: URL!
    private let profile = EmbeddingIndexer.Profile.image(providerId: "color", model: "color-v1", dimension: 3)

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("astfind-image-query-\(UUID().uuidString)")
        share = home.appendingPathComponent("素材库")
        try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    // MARK: - 归一化

    func testNormalizationBoundsLongSideAndDigestIsStable() throws {
        let red = share.appendingPathComponent("大红图.png")
        let blue = share.appendingPathComponent("大蓝图.png")
        try makeColorImage(.red, at: red, size: NSSize(width: 2400, height: 1200))
        try makeColorImage(.blue, at: blue, size: NSSize(width: 2400, height: 1200))

        let a = try XCTUnwrap(ImageQuery.make(fromFile: red))
        let b = try XCTUnwrap(ImageQuery.make(fromFile: red))
        XCTAssertEqual(a.digest, b.digest, "同一张图重复归一化必须得到同一缓存键")
        XCTAssertEqual(a.jpeg, b.jpeg)
        XCTAssertEqual(a.pixelWidth, 1024, "长边对齐入库缩略图 1024")
        XCTAssertEqual(a.pixelHeight, 512)
        XCTAssertFalse(a.jpeg.isEmpty)

        let other = try XCTUnwrap(ImageQuery.make(fromFile: blue))
        XCTAssertNotEqual(a.digest, other.digest)
    }

    // MARK: - 引擎检索与缓存

    func testImageQueryRanksIngestedImagesAndCachesVectorization() throws {
        try makeColorImage(.red, at: share.appendingPathComponent("红.png"))
        try makeColorImage(.blue, at: share.appendingPathComponent("蓝.png"))
        let (engine, provider) = try makeEngineWithProvider()
        let query = try XCTUnwrap(ImageQuery.make(fromFile: share.appendingPathComponent("红.png")))

        guard case .hits(let hits) = engine.imageSearch(query, limit: 5, timeout: 5) else {
            return XCTFail("图片检索应返回命中")
        }
        XCTAssertEqual(hits.first?.relativePath, "红.png", "\(hits)")
        XCTAssertEqual(hits.first?.kind, "image")
        XCTAssertGreaterThanOrEqual(hits.first?.score ?? 0, 0.9)

        let calls = provider.imageCalls
        guard case .hits(let cached) = engine.imageSearch(query, limit: 5, timeout: 5) else {
            return XCTFail("第二次查询应命中缓存")
        }
        XCTAssertEqual(cached.map(\.assetId), hits.map(\.assetId))
        XCTAssertEqual(provider.imageCalls, calls, "同一张查询图不重复向量化")
        engine.stop()
    }

    func testImageQueryUnavailableWithoutProvider() throws {
        let image = share.appendingPathComponent("红.png")
        try makeColorImage(.red, at: image)
        let engine = try AstfindEngine(home: home.appendingPathComponent("data"))
        engine.setSemanticSearch(enabled: true, persist: false)
        let query = try XCTUnwrap(ImageQuery.make(fromFile: image))
        switch engine.imageSearch(query, limit: 5, timeout: 5) {
        case .unavailable(let reason): XCTAssertFalse(reason.isEmpty)
        default: XCTFail("无 Provider 时应明确不可用")
        }
        XCTAssertEqual(engine.imageQueryAvailability(), .unavailable("未配置图片语义模型"))
        engine.stop()
    }

    func testProviderFailurePropagates() throws {
        try makeColorImage(.red, at: share.appendingPathComponent("红.png"))
        try makeColorImage(.blue, at: share.appendingPathComponent("蓝.png"))
        let (engine, provider) = try makeEngineWithProvider()
        provider.failWith = .server(500)
        let query = try XCTUnwrap(ImageQuery.make(fromFile: share.appendingPathComponent("红.png")))
        switch engine.imageSearch(query, limit: 5, timeout: 5) {
        case .failed(let reason): XCTAssertTrue(reason.contains("图片向量化失败"), reason)
        default: XCTFail("Provider 失败应回报 failed")
        }
        engine.stop()
    }

    // MARK: - 面板补充通道：视频帧去重 + 相似度保序

    func testImageQueryHitsDedupeVideoFramesAndPreserveSimilarityOrder() throws {
        let blueImage = share.appendingPathComponent("蓝.png")
        try makeColorImage(.blue, at: blueImage)
        try makeColorVideo(at: share.appendingPathComponent("开场.mp4"), secondsColors: Array(repeating: .blue, count: 4))

        let engine = try AstfindEngine(home: home.appendingPathComponent("data"))
        engine.autoExtractContent = false
        let record = try engine.register(path: share.path, name: "素材库")
        let semantic = try XCTUnwrap(engine.semantic)
        semantic.videoSampleInterval = 1
        semantic.videoMaxFrames = 100
        try semantic.ensureProfile(profile)
        let provider = EmbeddingTests.ColorProvider()
        XCTAssertEqual(try semantic.enqueuePending(sourceId: record.sourceId, profile: profile), 1)
        _ = try semantic.runPending(limit: 25, sourceId: record.sourceId, lanes: 2, provider: provider, profile: profile)
        XCTAssertEqual(try semantic.enqueuePendingVideos(sourceId: record.sourceId, profile: profile), 1)
        _ = try semantic.runPendingVideo(limit: 2, sourceId: record.sourceId, lanes: 1, provider: provider, profile: profile)
        engine.providers.addEmbeddingProvider(provider)
        engine.providers.record(probe: .available(latencyMs: 1, capabilities: provider.capabilities), id: provider.id)
        engine.setSemanticSearch(enabled: true, persist: false)

        let query = try XCTUnwrap(ImageQuery.make(fromFile: blueImage))
        guard case .hits = engine.imageSearch(query, limit: ContentSupplementaryProvider.imageFetchLimit, timeout: 5) else {
            return XCTFail("预热查询应命中")
        }

        let supplementary = ContentSupplementaryProvider(engine: engine)
        XCTAssertTrue(supplementary.acceptImageQuery(try Data(contentsOf: blueImage)))
        let sources = engine.sources()
        XCTAssertFalse(sources.isEmpty)
        var result: (hits: [SupplementaryHit], phase: ImageQueryPhase) = ([], .analyzing)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            result = supplementary.imageQueryHits(for: sources, kind: nil, isCancelled: { false })
            if case .ready = result.phase { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard case .ready(let count) = result.phase else { return XCTFail("\(result.phase)") }
        XCTAssertEqual(count, result.hits.count)
        XCTAssertGreaterThan(count, 0)
        XCTAssertTrue(result.hits.allSatisfy { $0.detail.hasSuffix("蓝.png") || $0.detail.hasSuffix("开场.mp4") },
                      "\(result.hits.map(\.detail))")

        let videoRows = result.hits.filter { $0.detail.hasSuffix("开场.mp4") }
        XCTAssertEqual(videoRows.count, 1, "同一视频多帧去重为一行：\(result.hits.map(\.detail))")
        XCTAssertTrue(videoRows.first?.detail.contains("@00:0") == true)
        XCTAssertNotNil(videoRows.first?.thumbnailTimeMs, "本地视频命中要按时间码抽帧")
        XCTAssertNotNil(videoRows.first?.mediaStartMs, "本地视频命中保留可跳转时间码")
        XCTAssertTrue(result.hits.filter { $0.detail.hasSuffix("蓝.png") }.allSatisfy { $0.mediaStartMs == nil })
        XCTAssertTrue(result.hits.allSatisfy { $0.detail.hasPrefix("【以图搜图 · 相似度") })

        let presentation = SearchPresentation(sources: sources, query: Query.parse(""))
            .supplement(result.hits, options: SearchOptions(), preserveHitOrder: true)
        XCTAssertEqual(presentation.total, result.hits.count)
        XCTAssertTrue(presentation.isCurrent(sources))
        XCTAssertNil(presentation.store)
        for i in result.hits.indices {
            XCTAssertEqual(presentation.row(i)?.id, result.hits[i].entryID, "第 \(i) 行应保持相似度顺序")
        }
        engine.stop()
    }

    // MARK: - 视频命中帧缩略图

    func testVideoFrameThumbnailExtractsHitFrame() throws {
        let video = share.appendingPathComponent("帧.mp4")
        try makeColorVideo(at: video, secondsColors: [.red, .red, .blue, .blue])
        let icons = IconProvider()
        let done = expectation(description: "命中帧缩略图")
        var image: NSImage?
        icons.thumbnail(path: video.path, modified: Date(), frameMs: 1000) { image = $0; done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertNotNil(image)
    }

    // MARK: - 网盘视频不做命中帧抽帧（避免大文件随机读拖慢整块 NAS）

    func testSMBVideoKeepsTimecodeButSkipsFrameThumbnail() throws {
        let blueImage = share.appendingPathComponent("蓝.png")
        try makeColorImage(.blue, at: blueImage)
        try makeColorVideo(at: share.appendingPathComponent("网盘.mp4"), secondsColors: Array(repeating: .blue, count: 2))

        let engine = try AstfindEngine(home: home.appendingPathComponent("data"))
        engine.autoExtractContent = false
        let record = try engine.register(path: share.path, name: "网盘", kind: .smb)
        XCTAssertEqual(record.kind, .smb)
        let semantic = try XCTUnwrap(engine.semantic)
        semantic.videoSampleInterval = 1
        semantic.videoMaxFrames = 100
        try semantic.ensureProfile(profile)
        let provider = EmbeddingTests.ColorProvider()
        _ = try semantic.enqueuePending(sourceId: record.sourceId, profile: profile)
        _ = try semantic.runPending(limit: 25, sourceId: record.sourceId, lanes: 2, provider: provider, profile: profile)
        _ = try semantic.enqueuePendingVideos(sourceId: record.sourceId, profile: profile)
        _ = try semantic.runPendingVideo(limit: 2, sourceId: record.sourceId, lanes: 1, provider: provider, profile: profile)
        engine.providers.addEmbeddingProvider(provider)
        engine.providers.record(probe: .available(latencyMs: 1, capabilities: provider.capabilities), id: provider.id)
        engine.setSemanticSearch(enabled: true, persist: false)

        let query = try XCTUnwrap(ImageQuery.make(fromFile: blueImage))
        guard case .hits = engine.imageSearch(query, limit: ContentSupplementaryProvider.imageFetchLimit, timeout: 5) else {
            return XCTFail("预热查询应命中")
        }
        let supplementary = ContentSupplementaryProvider(engine: engine)
        XCTAssertTrue(supplementary.acceptImageQuery(try Data(contentsOf: blueImage)))
        let sources = engine.sources()
        var result: (hits: [SupplementaryHit], phase: ImageQueryPhase) = ([], .analyzing)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            result = supplementary.imageQueryHits(for: sources, kind: nil, isCancelled: { false })
            if case .ready = result.phase { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard case .ready = result.phase else { return XCTFail("\(result.phase)") }
        let video = result.hits.first { $0.detail.hasSuffix("网盘.mp4") }
        XCTAssertNotNil(video, "\(result.hits.map(\.detail))")
        XCTAssertNil(video?.thumbnailTimeMs, "SMB 视频不做命中帧抽帧")
        XCTAssertNotNil(video?.mediaStartMs, "SMB 视频仍保留可跳转时间码（与缩略图解耦）")
        XCTAssertTrue(video?.detail.contains("@00:0") == true, "时间码标签仍保留")
        engine.stop()
    }

    // MARK: - ⌘V 粘贴路径（面板接线，不依赖辅助功能权限）

    func testCommandVPasteRoutesImageIntoImageMode() throws {
        let url = share.appendingPathComponent("粘贴.png")
        try makeColorImage(.red, at: url)
        let png = try Data(contentsOf: url)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("astfind-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        ImagePasteboard.testPasteboard = pasteboard
        defer { ImagePasteboard.testPasteboard = nil }

        let controller = SearchViewController(snapshot: false)
        controller.loadViewIfNeeded()
        let provider = FakeImageProvider()
        controller.supplementaryProvider = provider
        // M0.7b：已有文字时粘贴新图，文字不得被清掉。
        controller.searchField.text = "舞台"
        let queried = expectation(description: "图片查询进入面板通道")
        provider.onHits = { queried.fulfill() }

        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                                   context: nil, characters: "v", charactersIgnoringModifiers: "v",
                                                   isARepeat: false, keyCode: 9))
        XCTAssertTrue(controller.handleKey(event), "⌘V 应被图片粘贴路径接管")
        XCTAssertEqual(provider.accepted, png)
        XCTAssertNotNil(controller.searchField.imagePreview, "参考图 chip 应立即出现")
        XCTAssertEqual(controller.searchField.text, "舞台", "粘贴新图必须保留当前文字")
        wait(for: [queried], timeout: 5)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertGreaterThanOrEqual(provider.hitsCalls, 1, "图片模式应走 imageQueryHits")
        XCTAssertEqual(provider.textCalls, 0, "图片模式不得走文本补充通道")
    }

    // MARK: - 搜索框布局（图片入口 / 参考图 chip 不挤压文字）

    func testSearchFieldLayoutReservesImageEntryAndChip() {
        let field = SearchField(frame: NSRect(x: 0, y: 0, width: 600, height: 64))
        field.layout()
        let baseWidth = field.input.frame.width
        XCTAssertGreaterThan(baseWidth, 0)

        field.imageEntryVisible = true
        field.layout()
        XCTAssertLessThan(field.input.frame.width, baseWidth, "图片按钮必须占用右侧空间，不能压到文字")

        field.imagePreview = NSImage(size: NSSize(width: 40, height: 40))
        field.layout()
        XCTAssertEqual(field.input.frame.minX, 64, accuracy: 0.5, "参考图 chip 出现后文字起点右移")
        XCTAssertLessThan(field.input.frame.maxX, field.bounds.width - 44, "文字不能压到清除按钮")

        field.imagePreview = nil
        field.imageEntryVisible = false
        field.layout()
        XCTAssertEqual(field.input.frame.width, baseWidth, accuracy: 0.5)
    }

    // MARK: - M0.7b 图文联合查询

    func testJointVectorFusionNormalizesAndRespectsAlpha() {
        let fused = JointVectorFusion.fuse(image: [1, 0], text: [0, 1], alpha: 0.7)
        let vector = fused ?? []
        XCTAssertEqual(vector.count, 2)
        let norm = (vector[0] * vector[0] + vector[1] * vector[1]).squareRoot()
        XCTAssertEqual(norm, 1, accuracy: 0.0001, "融合结果必须 L2 归一化")
        XCTAssertEqual(vector[0] / vector[1], 0.7 / 0.3, accuracy: 0.001, "alpha 权重生效")
        XCTAssertNil(JointVectorFusion.fuse(image: [1, 0], text: [0], alpha: 0.7), "维度不一致必须降级")
        XCTAssertNil(JointVectorFusion.fuse(image: [0, 0], text: [0, 0], alpha: 0.7), "零向量必须降级")
        XCTAssertEqual(JointVectorFusion.cosine([1, 0], [1, 0]), 1)
        XCTAssertNil(JointVectorFusion.cosine([1], [1, 0]))
    }

    func testJointQueryFusionLetsTextShiftRankingAndCachesVectors() throws {
        try makeColorImage(.red, at: share.appendingPathComponent("红.png"))
        try makeColorImage(.blue, at: share.appendingPathComponent("蓝.png"))
        let (engine, provider) = try makeEngineWithProvider()
        let red = try XCTUnwrap(ImageQuery.make(fromFile: share.appendingPathComponent("红.png")))

        // 默认 alpha=0.7 图片主导：红图 + “蓝”仍应红图在前。
        let imageDominant = JointImageQuery(image: red, text: "蓝")
        switch engine.jointImageSearch(imageDominant, limit: 5, timeout: 5) {
        case .hits(let result):
            XCTAssertEqual(result.mode, .fused, "同 Provider/同维度应走向量融合")
            XCTAssertNil(result.fallback)
            XCTAssertEqual(result.hits.first?.relativePath, "红.png", "\(result.hits)")
        default: XCTFail("联合查询应返回命中")
        }
        let imageCalls = provider.imageCalls, textCalls = provider.textCalls

        // 同一查询走 60s 结果缓存，不重复向量化。
        _ = engine.jointImageSearch(imageDominant, limit: 5, timeout: 5)
        XCTAssertEqual(provider.imageCalls, imageCalls)
        XCTAssertEqual(provider.textCalls, textCalls)

        // 换 alpha 不换文字：图片向量与文本向量都应命中缓存。
        let textDominant = JointImageQuery(image: red, text: "蓝", alpha: 0.2)
        switch engine.jointImageSearch(textDominant, limit: 5, timeout: 5) {
        case .hits(let result):
            XCTAssertEqual(result.mode, .fused)
            XCTAssertEqual(result.hits.first?.relativePath, "蓝.png", "alpha=0.2 时文字应主导：\(result.hits)")
        default: XCTFail("换 alpha 后联合查询应返回命中")
        }
        XCTAssertEqual(provider.imageCalls, imageCalls, "同一参考图改 alpha 不得重复图片向量化")
        XCTAssertEqual(provider.textCalls, textCalls, "同一文字改 alpha 不得重复文本向量化")

        // 换文字：图片向量按 digest 复用，只重新算文本向量。
        let otherText = JointImageQuery(image: red, text: "红", alpha: 0.2)
        switch engine.jointImageSearch(otherText, limit: 5, timeout: 5) {
        case .hits(let result):
            XCTAssertEqual(result.mode, .fused)
            XCTAssertEqual(result.hits.first?.relativePath, "红.png", "\(result.hits)")
        default: XCTFail("换文字后联合查询应返回命中")
        }
        XCTAssertEqual(provider.imageCalls, imageCalls, "同一参考图改文字不得重复图片向量化")
        XCTAssertGreaterThan(provider.textCalls, textCalls, "不同文字应按 profile + text 重新计算")
        engine.stop()
    }

    func testJointQueryFallsBackToFilteredImageRecallWhenTextVectorFails() throws {
        try makeColorImage(.red, at: share.appendingPathComponent("红色海报.png"))
        try makeColorImage(.blue, at: share.appendingPathComponent("蓝色海报.png"))
        let (engine, provider) = try makeEngineWithProvider()
        provider.textFailWith = .server(500)
        let red = try XCTUnwrap(ImageQuery.make(fromFile: share.appendingPathComponent("红色海报.png")))
        let query = JointImageQuery(image: red, text: "红色")
        switch engine.jointImageSearch(query, limit: 20, timeout: 5) {
        case .hits(let result):
            XCTAssertEqual(result.mode, .filtered, "文本向量不可用但文件名命中 → 图片召回 + 文本重排")
            XCTAssertEqual(result.fallback, .textVectorUnavailable)
            XCTAssertEqual(result.hits.first?.relativePath, "红色海报.png", "\(result.hits)")
        default: XCTFail("降级也必须返回图片结果")
        }
        engine.stop()
    }

    func testJointQueryNeverReturnsEmptyWhenTextHasNoMatch() throws {
        try makeColorImage(.red, at: share.appendingPathComponent("红.png"))
        try makeColorImage(.blue, at: share.appendingPathComponent("蓝.png"))
        let (engine, provider) = try makeEngineWithProvider()
        provider.textFailWith = .server(500)
        let red = try XCTUnwrap(ImageQuery.make(fromFile: share.appendingPathComponent("红.png")))
        let query = JointImageQuery(image: red, text: "完全不存在词xyz")
        switch engine.jointImageSearch(query, limit: 20, timeout: 5) {
        case .hits(let result):
            XCTAssertEqual(result.mode, .imageOnly)
            XCTAssertEqual(result.fallback, .textVectorUnavailable)
            XCTAssertFalse(result.hits.isEmpty, "文本无命中必须保留纯图结果，绝不返回空")
            XCTAssertEqual(result.hits.first?.relativePath, "红.png")
        default: XCTFail("降级也必须返回图片结果")
        }
        engine.stop()
    }

    func testJointQueryFallsBackWhenTextVectorDimensionMismatches() throws {
        try makeColorImage(.red, at: share.appendingPathComponent("红.png"))
        try makeColorImage(.blue, at: share.appendingPathComponent("蓝.png"))
        let (engine, provider) = try makeEngineWithProvider()
        provider.textVectorOverride = [1, 0]   // 与图片/索引 3 维不一致：不得融合
        let red = try XCTUnwrap(ImageQuery.make(fromFile: share.appendingPathComponent("红.png")))
        switch engine.jointImageSearch(JointImageQuery(image: red, text: "紫色"), limit: 20, timeout: 5) {
        case .hits(let result):
            XCTAssertEqual(result.mode, .imageOnly)
            XCTAssertEqual(result.fallback, .textVectorUnavailable)
            XCTAssertFalse(result.hits.isEmpty)
        default: XCTFail("维度不一致也必须降级返回图片结果")
        }
        engine.stop()
    }

    func testJointQueryCacheDoesNotSurviveSemanticSearchDisable() throws {
        try makeColorImage(.red, at: share.appendingPathComponent("红.png"))
        try makeColorImage(.blue, at: share.appendingPathComponent("蓝.png"))
        let (engine, _) = try makeEngineWithProvider()
        let red = try XCTUnwrap(ImageQuery.make(fromFile: share.appendingPathComponent("红.png")))
        let query = JointImageQuery(image: red, text: "蓝")
        guard case .hits = engine.jointImageSearch(query, limit: 5, timeout: 5) else {
            return XCTFail("预热联合查询应命中")
        }
        engine.setSemanticSearch(enabled: false, persist: false)
        switch engine.jointImageSearch(query, limit: 5, timeout: 5) {
        case .unavailable(let reason): XCTAssertFalse(reason.isEmpty)
        default: XCTFail("关闭语义检索后旧模型缓存不得复用")
        }
        engine.stop()
    }

    // MARK: - M0.7a 视频帧找相似 / 跳时间点

    func testVideoFrameExtractorExtractsRequestedMoment() throws {
        let video = share.appendingPathComponent("三色.mp4")
        try makeColorVideo(at: video, secondsColors: [.red, .green, .blue])
        let result = VideoFrameExtractor.jpegData(path: video.path, atMs: 2000, timeout: 8)
        guard case .success(let data) = result else {
            return XCTFail("指定毫秒抽帧应成功：\(result)")
        }
        let image = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertLessThanOrEqual(max(image.pixelsWide, image.pixelsHigh), 1024)
        let color = try XCTUnwrap(image.colorAt(x: image.pixelsWide / 2, y: image.pixelsHigh / 2)?
            .usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(color.blueComponent, color.redComponent + 0.2, "2s 处应为蓝色帧：\(color)")
    }

    func testVideoFrameExtractorTimeoutIsClassified() throws {
        let video = share.appendingPathComponent("超时.mp4")
        try makeColorVideo(at: video, secondsColors: [.red, .blue])
        switch VideoFrameExtractor.jpegData(path: video.path, atMs: 1000, timeout: 0.0001) {
        case .failure(.timeout): break
        default: XCTFail("极小看门狗应返回可分类的 timeout")
        }
    }

    func testVideoPlaybackSeeksWithQuickTime() {
        let coordinator = VideoPlaybackCoordinator()
        coordinator.playerBundleID = { _ in VideoPlaybackCoordinator.quickTimeBundleID }
        var opened = false
        var scriptedSeconds: Double?
        coordinator.openStandard = { _ in opened = true }
        coordinator.runAppleScript = { _, seconds, _ in scriptedSeconds = seconds; return .success(()) }
        let outcome = coordinator.open(url: share.appendingPathComponent("clip.mp4"), startMs: 4200)
        XCTAssertEqual(outcome.kind, .sought)
        XCTAssertEqual(outcome.playerBundleID, VideoPlaybackCoordinator.quickTimeBundleID)
        XCTAssertEqual(scriptedSeconds ?? 0, 4.2, accuracy: 0.001)
        XCTAssertFalse(opened)
    }

    func testVideoPlaybackFallsBackWhenPlayerIsNotQuickTime() {
        let coordinator = VideoPlaybackCoordinator()
        coordinator.playerBundleID = { _ in "com.apple.moviz" }
        var opened = false
        coordinator.openStandard = { _ in opened = true }
        coordinator.runAppleScript = { _, _, _ in XCTFail("非 QuickTime 不得尝试 AppleScript"); return .success(()) }
        let outcome = coordinator.open(url: share.appendingPathComponent("clip.mp4"), startMs: 1000)
        XCTAssertEqual(outcome.kind, .standard)
        XCTAssertEqual(outcome.reason, .notQuickTime)
        XCTAssertTrue(opened)
    }

    func testVideoPlaybackFallsBackAndDoesNotRetryAfterPermissionDenial() {
        let coordinator = VideoPlaybackCoordinator()
        coordinator.playerBundleID = { _ in VideoPlaybackCoordinator.quickTimeBundleID }
        var opened = 0, scripts = 0
        coordinator.openStandard = { _ in opened += 1 }
        coordinator.runAppleScript = { _, _, _ in scripts += 1; return .failure(.permissionDenied) }
        let first = coordinator.open(url: share.appendingPathComponent("clip.mp4"), startMs: 1000)
        XCTAssertEqual(first.kind, .fallback)
        XCTAssertEqual(first.reason, .permissionDenied)
        XCTAssertTrue(coordinator.automationDenied)
        let second = coordinator.open(url: share.appendingPathComponent("clip.mp4"), startMs: 2000)
        XCTAssertEqual(second.kind, .standard)
        XCTAssertEqual(second.reason, .automationDenied)
        XCTAssertEqual(scripts, 1, "同一会话拒绝后不得反复弹授权")
        XCTAssertEqual(opened, 2)
    }

    func testVideoPlaybackFallsBackOnAppleScriptFailure() {
        let coordinator = VideoPlaybackCoordinator()
        coordinator.playerBundleID = { _ in VideoPlaybackCoordinator.quickTimeBundleID }
        var opened = false
        coordinator.openStandard = { _ in opened = true }
        coordinator.runAppleScript = { _, _, _ in .failure(.scriptFailed("boom")) }
        let outcome = coordinator.open(url: share.appendingPathComponent("clip.mp4"), startMs: 1000)
        XCTAssertEqual(outcome.kind, .fallback)
        XCTAssertEqual(outcome.reason, .scriptFailed("boom"))
        XCTAssertTrue(opened)
    }

    // MARK: - M0.7b 面板联合输入

    func testImageModeTypingKeepsImageAndRoutesToJointSearch() {
        let controller = SearchViewController(snapshot: false)
        controller.loadViewIfNeeded()
        let provider = FakeJointProvider()
        provider.imagePreview = NSImage(size: NSSize(width: 40, height: 40))
        controller.supplementaryProvider = provider
        let jointed = expectation(description: "联合查询")
        provider.onJoint = { jointed.fulfill() }

        controller.searchField.text = "室内"
        controller.searchField.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,
                                                                 object: controller.searchField.input))
        XCTAssertNotNil(controller.searchField.imagePreview, "图片模式下输入文字不得清掉参考图")
        wait(for: [jointed], timeout: 5)
        XCTAssertEqual(provider.clearCalls, 0)
        XCTAssertEqual(provider.textCalls, 0, "联合模式不得退回纯文本补充通道")
        XCTAssertGreaterThan(provider.jointCalls, 0)

        // 清空文字 → 回纯图（图片仍保留）。
        controller.searchField.text = ""
        controller.searchField.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,
                                                                 object: controller.searchField.input))
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertNotNil(controller.searchField.imagePreview)
        XCTAssertGreaterThan(provider.imageCalls, 0, "清空文字后应回到纯图查询")

        // 点 chip × → 清除参考图，回到纯文本查询。
        controller.searchField.onClearImage?()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(provider.clearCalls, 1)
        XCTAssertNil(controller.searchField.imagePreview)
        XCTAssertGreaterThan(provider.textCalls, 0, "清除参考图后应走文本搜索")
    }

    func testPersonEntryVisibilityAndPreviewWiring() throws {
        let image = share.appendingPathComponent("人物.png")
        try makeColorImage(.red, at: image)
        let png = try Data(contentsOf: image)

        let controller = SearchViewController(snapshot: false)
        controller.loadViewIfNeeded()
        let provider = FakeImageProvider()
        provider.personEntryAvailability = .available
        controller.supplementaryProvider = provider
        controller.sourcesChanged()

        XCTAssertTrue(controller.searchField.personEntryVisible, "人物入口应可见")
        XCTAssertTrue(provider.acceptPersonQuery(png))
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !controller.searchField.personPreview {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(controller.searchField.personPreview, "人物参考图应切换占位/预览状态")
        XCTAssertNotNil(controller.searchField.imagePreview)
    }

    func testPersonFacePickerShowsForMultipleFacesAndSelects() {
        let controller = SearchViewController(snapshot: false)
        controller.loadViewIfNeeded()
        let provider = FakeImageProvider()
        provider.isPersonQueryActive = true
        provider.personFacePreviews = [NSImage(size: NSSize(width: 36, height: 36)),
                                       NSImage(size: NSSize(width: 36, height: 36))]
        controller.supplementaryProvider = provider
        XCTAssertFalse(controller.facePicker.isHidden, "多脸参考图应展示候选脸选择条")
        controller.facePicker.onSelect?(1)
        XCTAssertEqual(provider.selectedPersonFaceIndex, 1)
    }

    // MARK: - 方案 A：Finder 服务

    func testFinderServiceAcceptsOnlyImageFileAndHandsOffURL() throws {
        let image = share.appendingPathComponent("访达找相似.png")
        let document = share.appendingPathComponent("说明.txt")
        try makeColorImage(.red, at: image)
        try "不是图片".write(to: document, atomically: true, encoding: .utf8)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("astfind-service-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([image as NSURL])
        XCTAssertEqual(FinderServiceProvider.imageURL(from: pasteboard), image)

        let provider = FinderServiceProvider()
        let delegate = FakeFinderServiceDelegate()
        provider.delegate = delegate
        XCTAssertTrue(provider.perform(pasteboard: pasteboard))
        XCTAssertEqual(delegate.url, image)

        pasteboard.clearContents()
        pasteboard.writeObjects([document as NSURL])
        XCTAssertNil(FinderServiceProvider.imageURL(from: pasteboard))
        XCTAssertFalse(provider.perform(pasteboard: pasteboard))
    }

    func testFinderServiceEntryClearsTextAndEntersImageMode() throws {
        let image = share.appendingPathComponent("服务入口.png")
        try makeColorImage(.red, at: image)
        let png = try Data(contentsOf: image)

        let controller = SearchViewController(snapshot: false)
        controller.loadViewIfNeeded()
        let provider = FakeImageProvider()
        controller.supplementaryProvider = provider
        controller.searchField.text = "旧查询文字"
        controller.prepareFinderServiceImage(image)

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, provider.accepted == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(provider.accepted, png)
        XCTAssertEqual(controller.searchField.text, "", "Finder 服务入口应清掉旧文字，按纯图检索")
        XCTAssertNotNil(controller.searchField.imagePreview, "参考图 chip 应出现")
        XCTAssertGreaterThanOrEqual(provider.hitsCalls, 1, "应进入图片查询")
    }

    // MARK: - 装置

    /// 面板接线用的假双协议 Provider：不碰引擎，只记录入口/命中调用。
    final class FakeImageProvider: SupplementarySearchProvider, ImageQuerySearchProvider {
        var isEnabled = true
        var onImageQueryChange: (() -> Void)?
        var imagePreview: NSImage?
        var imageQueryPhase: ImageQueryPhase = .idle
        var imageEntryAvailability: ImageEntryAvailability = .available
        var isPersonQueryActive = false
        var personEntryAvailability: ImageEntryAvailability = .unavailable("")
        var personFacePreviews: [NSImage] = []
        var selectedPersonFaceIndex = 0
        private(set) var accepted: Data?
        private(set) var hitsCalls = 0
        private(set) var textCalls = 0
        var hits: [SupplementaryHit] = []
        var onHits: (() -> Void)?

        func acceptImageQuery(_ data: Data) -> Bool {
            accepted = data
            imagePreview = NSImage(data: data)
            imageQueryPhase = .ready(1)
            onImageQueryChange?()
            return imagePreview != nil
        }
        func acceptPersonQuery(_ data: Data) -> Bool {
            accepted = data
            imagePreview = NSImage(data: data)
            isPersonQueryActive = true
            imageQueryPhase = .ready(1)
            onImageQueryChange?()
            return imagePreview != nil
        }
        func selectPersonFace(_ index: Int) {
            selectedPersonFaceIndex = index
        }
        func clearImageQuery() {
            imagePreview = nil
            isPersonQueryActive = false
            imageQueryPhase = .idle
            onImageQueryChange?()
        }
        func imageQueryHits(for sources: [SearchSource], kind: UInt8?,
                            isCancelled: @escaping () -> Bool) -> (hits: [SupplementaryHit], phase: ImageQueryPhase) {
            hitsCalls += 1
            let callback = onHits
            onHits = nil
            callback?()
            return (hits, imageQueryPhase)
        }
        func prepareSearch(_ query: Query, options: SearchOptions, sources: [SearchSource],
                           isCancelled: @escaping () -> Bool) -> () -> [SupplementaryHit] {
            textCalls += 1
            return { [] }
        }
        func sourcesDidChange(_ sources: [SearchSource]) { }
        func userActivity(visible: Bool, typing: Bool) { }
    }

    /// 面板接线用的假双协议 Provider：不碰引擎，只记录入口/命中调用。
    final class FakeJointProvider: SupplementarySearchProvider, JointImageSearchProvider {
        var isEnabled = true
        var onImageQueryChange: (() -> Void)?
        var imagePreview: NSImage?
        var imageQueryPhase: ImageQueryPhase = .ready(1)
        var jointQueryPhase: JointImageQueryPhase = .idle
        var imageEntryAvailability: ImageEntryAvailability = .available
        var isPersonQueryActive = false
        var personEntryAvailability: ImageEntryAvailability = .unavailable("")
        var personFacePreviews: [NSImage] = []
        var selectedPersonFaceIndex = 0
        private(set) var accepted: Data?
        private(set) var imageCalls = 0
        private(set) var jointCalls = 0
        private(set) var textCalls = 0
        private(set) var clearCalls = 0
        var onJoint: (() -> Void)?

        func acceptImageQuery(_ data: Data) -> Bool {
            accepted = data
            imagePreview = NSImage(data: data)
            imageQueryPhase = .ready(1)
            onImageQueryChange?()
            return imagePreview != nil
        }
        func acceptPersonQuery(_ data: Data) -> Bool {
            accepted = data
            imagePreview = NSImage(data: data)
            isPersonQueryActive = true
            imageQueryPhase = .ready(1)
            onImageQueryChange?()
            return imagePreview != nil
        }
        func selectPersonFace(_ index: Int) {
            selectedPersonFaceIndex = index
        }
        func clearImageQuery() {
            clearCalls += 1
            imagePreview = nil
            isPersonQueryActive = false
            imageQueryPhase = .idle
            jointQueryPhase = .idle
            onImageQueryChange?()
        }
        func imageQueryHits(for sources: [SearchSource], kind: UInt8?,
                            isCancelled: @escaping () -> Bool) -> (hits: [SupplementaryHit], phase: ImageQueryPhase) {
            imageCalls += 1
            return ([], imageQueryPhase)
        }
        func jointImageHits(for text: String, sources: [SearchSource], kind: UInt8?,
                            isCancelled: @escaping () -> Bool) -> (hits: [SupplementaryHit], phase: JointImageQueryPhase) {
            jointCalls += 1
            jointQueryPhase = .ready(count: 0, mode: .fused, fallback: nil)
            onJoint?()
            return ([], jointQueryPhase)
        }
        func prepareSearch(_ query: Query, options: SearchOptions, sources: [SearchSource],
                           isCancelled: @escaping () -> Bool) -> () -> [SupplementaryHit] {
            textCalls += 1
            return { [] }
        }
        func sourcesDidChange(_ sources: [SearchSource]) { }
        func userActivity(visible: Bool, typing: Bool) { }
    }

    final class FakeFinderServiceDelegate: FinderServiceDelegate {
        var url: URL?
        func finderService(_ service: FinderServiceProvider, findSimilar url: URL) { self.url = url }
    }

    private func makeEngineWithProvider() throws -> (AstfindEngine, EmbeddingTests.ColorProvider) {
        let engine = try AstfindEngine(home: home.appendingPathComponent("data"))
        engine.autoExtractContent = false
        let record = try engine.register(path: share.path, name: "素材库")
        let semantic = try XCTUnwrap(engine.semantic)
        let provider = EmbeddingTests.ColorProvider()
        try semantic.ensureProfile(profile)
        XCTAssertGreaterThanOrEqual(try semantic.enqueuePending(sourceId: record.sourceId, profile: profile), 2)
        _ = try semantic.runPending(limit: 25, sourceId: record.sourceId, lanes: 2, provider: provider, profile: profile)
        engine.providers.addEmbeddingProvider(provider)
        engine.providers.record(probe: .available(latencyMs: 1, capabilities: provider.capabilities), id: provider.id)
        engine.setSemanticSearch(enabled: true, persist: false)
        return (engine, provider)
    }

    private func makeColorImage(_ color: NSColor, at url: URL, size: NSSize = NSSize(width: 64, height: 64)) throws {
        let image = NSImage(size: size)
        image.lockFocus(); color.setFill(); NSRect(origin: .zero, size: size).fill(); image.unlockFocus()
        let data = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }

    private func makeColorVideo(at url: URL, secondsColors: [NSColor]) throws {
        let width = 320, height = 180
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        XCTAssertTrue(writer.canAdd(input)); writer.add(input)
        XCTAssertTrue(writer.startWriting(), "\(writer.error.map { "\($0)" } ?? "")")
        writer.startSession(atSourceTime: .zero)
        for (second, color) in secondsColors.enumerated() {
            let buffer = try makeFrame(color: color, width: width, height: height, pool: adaptor.pixelBufferPool)
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(seconds: Double(second), preferredTimescale: 600)))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 30), .success)
        XCTAssertEqual(writer.status, .completed, "\(writer.error.map { "\($0)" } ?? "")")
    }

    private func makeFrame(color: NSColor, width: Int, height: Int, pool: CVPixelBufferPool?) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) }
        if buffer == nil {
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32ARGB,
                                [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary, &buffer)
        }
        let pixel = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        let context = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel),
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setFillColor(color.usingColorSpace(.deviceRGB)!.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return pixel
    }
}
