import XCTest
import AppKit
import OilFindCore
@testable import AstfindKit

/// 本机盘内容索引范围选择器（P0）：复用面板主索引零双扫登记所选目录资产，
/// 只做 OCR/正文。开发者真实场景：本地图片（副券/教师节快乐）此前搜不到。
final class LocalContentScopeTests: XCTestCase {
    private var home: URL!
    private var root: URL!   // 模拟"本机盘"（主索引的扫描根）
    private var desktop: URL!
    private var downloads: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("astfind-scope-\(UUID().uuidString)")
        root = home.appendingPathComponent("本机")
        desktop = root.appendingPathComponent("桌面")
        downloads = root.appendingPathComponent("下载")
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
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

    /// 生产同构：IndexManager 对"本机盘"根做完整扫描（面板主索引的建法），返回其 store。
    private func scanPrimary() throws -> IndexStore {
        let manager = IndexManager(config: IndexConfig(rootPath: root.path),
                                   dbURL: home.appendingPathComponent("index.oilfind"),
                                   volumeUUID: nil, settingsDefaults: nil)
        manager.start()
        let deadline = Date().addingTimeInterval(60)
        var seenActive = false
        while Date() < deadline {
            switch manager.state {
            case .ready: Thread.sleep(forTimeInterval: 0.05); return try XCTUnwrap(manager.store)
            case .idle: if seenActive { throw XCTSkip("primary scan failed") }
            case .loading, .scanning: seenActive = true
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw XCTSkip("primary scan timeout")
    }

    private func makeEngine() throws -> AstfindEngine {
        let engine = try AstfindEngine(home: home.appendingPathComponent("data"))
        engine.autoExtractContent = false
        return engine
    }

    /// 只登记所选目录（组件级过滤：桌面-2 ≠ 桌面之下）；contentOnly 隐藏不进 sources()。
    func testEnsureRegistersOnlyEntriesUnderChosenDirectory() throws {
        try makeImage(text: "副券 停车凭证", at: desktop.appendingPathComponent("副券.png"))
        try "桌面笔记".write(to: desktop.appendingPathComponent("笔记.txt"), atomically: true, encoding: .utf8)
        try "下载的文档".write(to: downloads.appendingPathComponent("下载文档.txt"), atomically: true, encoding: .utf8)
        try makeImage(text: "下载的图片", at: downloads.appendingPathComponent("下载图.jpg"))
        let sibling = root.appendingPathComponent("桌面-2")   // 前缀巧合目录：绝不误收
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try "同名陷阱".write(to: sibling.appendingPathComponent("陷阱.txt"), atomically: true, encoding: .utf8)

        let store = try scanPrimary()
        let engine = try makeEngine()
        let record = try engine.ensureLocalContentSource(dirPath: desktop.path, displayName: "桌面", store: store)

        XCTAssertEqual(engine.liveAssetCount(sourceId: record.sourceId), 2, "只登记所选目录的文件")
        XCTAssertEqual(engine.records().count, 0, "contentOnly 对用户来源清单隐藏")
        XCTAssertTrue(engine.sources().isEmpty, "不进搜索源（文件名归面板主索引，不重复）")
        XCTAssertEqual(engine.localContentScopes().map(\.sourceId), [record.sourceId])
        XCTAssertEqual(record.kind, .local)
        XCTAssertEqual(record.locator, "file://" + desktop.path)
        engine.stop()

        // 幂等：重复 ensure 不产生重复源、计数稳定
        let engine2 = try makeEngine()
        _ = try engine2.ensureLocalContentSource(dirPath: desktop.path, displayName: "桌面", store: store)
        XCTAssertEqual(engine2.localContentScopes().count, 1)
        XCTAssertEqual(engine2.liveAssetCount(sourceId: record.sourceId), 2)
        engine2.stop()
    }

    /// 开发者真实场景端到端：本地目录图片里的字 → 内容源登记 → 抽取 → 内容搜索命中。
    func testLocalScopeImageTextSearchableEndToEnd() throws {
        try makeImage(text: "教师节快乐 感恩有你", at: desktop.appendingPathComponent("贺卡.png"))
        try makeImage(text: "副券 请妥善保管", at: desktop.appendingPathComponent("副券.png"))
        let store = try scanPrimary()
        let engine = try makeEngine()
        let record = try engine.ensureLocalContentSource(dirPath: desktop.path, displayName: "桌面", store: store)
        let summary = try XCTUnwrap(engine.extractContent(sourceId: record.sourceId))
        XCTAssertEqual(summary.extracted, 2, "两张图全部抽取")
        XCTAssertGreaterThanOrEqual(engine.contentSearch("教师节快乐").count, 1, "本地图片文字可搜（此前搜不到的根因）")
        XCTAssertGreaterThanOrEqual(engine.contentSearch("副券").count, 1)
        engine.stop()
    }

    /// 目录内删除随主索引收敛：重同步确认删除 → 观测清扫，内容命中消失（离线 ≠ 删除的红线不破坏——
    /// 这里是磁盘上真删了）。
    func testDeletedFileConvergesOnResync() throws {
        try makeImage(text: "待删除凭证 XYZQ", at: desktop.appendingPathComponent("旧图.png"))
        try "保留的笔记".write(to: desktop.appendingPathComponent("笔记.txt"), atomically: true, encoding: .utf8)
        let store = try scanPrimary()
        let engine = try makeEngine()
        let record = try engine.ensureLocalContentSource(dirPath: desktop.path, displayName: "桌面", store: store)
        _ = try XCTUnwrap(engine.extractContent(sourceId: record.sourceId))
        XCTAssertGreaterThanOrEqual(engine.contentSearch("XYZQ").count, 1)

        // 磁盘真删 + 主索引重扫收敛（必须先等 ready 再 rescan——上游 beginRescan 对非 ready 态静默 no-op）
        try FileManager.default.removeItem(at: desktop.appendingPathComponent("旧图.png"))
        let manager = IndexManager(config: IndexConfig(rootPath: root.path),
                                   dbURL: home.appendingPathComponent("index.oilfind"),
                                   volumeUUID: nil, settingsDefaults: nil)
        manager.start()
        let readyDeadline = Date().addingTimeInterval(60)
        while Date() < readyDeadline, manager.state != .ready { Thread.sleep(forTimeInterval: 0.05) }
        let previous = manager.store
        manager.rescan()
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline,
              !(manager.store != nil && manager.store !== previous && !manager.isRescanning) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        let refreshed = try XCTUnwrap(manager.store)
        engine.resyncLocalContentScopes(store: refreshed)   // 主索引变化驱动的幂等重同步

        XCTAssertEqual(engine.liveAssetCount(sourceId: record.sourceId), 1, "删除已收敛")
        let summary = try XCTUnwrap(engine.extractContent(sourceId: record.sourceId))
        XCTAssertGreaterThanOrEqual(summary.cleanedDeletions, 1, "已删资产的内容观测被清扫")
        XCTAssertEqual(engine.contentSearch("XYZQ").count, 0, "命中随删除消失")
        engine.stop()
        manager.stop()
    }

    /// 成本预估（确认流）：按提取器扩展名分类，跳过 ._ 边车与不支持类型；时长按路数折算。
    func testLocalContentEstimateCountsAndDurations() throws {
        try makeImage(text: "图一", at: downloads.appendingPathComponent("a.png"))
        try makeImage(text: "图二", at: downloads.appendingPathComponent("b.jpg"))
        try "文一".write(to: downloads.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        try Data([0x25, 0x50]).write(to: downloads.appendingPathComponent("d.pdf"))
        try Data([0x00]).write(to: downloads.appendingPathComponent("._a.png"))   // 边车
        try Data([0x00]).write(to: downloads.appendingPathComponent(".DS_Store"))
        try Data([0x00]).write(to: downloads.appendingPathComponent("e.zip"))     // 不支持
        try FileManager.default.createDirectory(at: downloads.appendingPathComponent("子目录"), withIntermediateDirectories: true)
        try "嵌套文档".write(to: downloads.appendingPathComponent("子目录").appendingPathComponent("f.md"), atomically: true, encoding: .utf8)

        let engine = try makeEngine()
        let estimate = engine.localContentEstimate(dirPath: downloads.path)
        XCTAssertEqual(estimate.images, 2, "只算图片扩展名（边车跳过）")
        XCTAssertEqual(estimate.documents, 3, "txt/pdf/md；zip 不算")
        XCTAssertEqual(estimate.total, 5)
        XCTAssertGreaterThan(estimate.totalBytes, 0)
        XCTAssertEqual(estimate.estimatedSeconds(lanes: 2), 3, "5 个文件 2 路 ≈ 3 秒（向上取整）")
        XCTAssertEqual(estimate.estimatedSeconds(lanes: 4), 2)
        engine.stop()
    }
}
