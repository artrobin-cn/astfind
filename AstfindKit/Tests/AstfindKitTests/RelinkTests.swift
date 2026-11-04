import XCTest
import OilFindCore
@testable import AstfindKit

/// R2/L3：PR 式手动重链接——素材整体搬家后点一次完成批量重绑，
/// 索引、内容观测、身份全部保留（零重扫 OCR）。
final class RelinkTests: XCTestCase {
    private var home: URL!
    private var root: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("astfind-r2-\(UUID().uuidString)")
        root = home.appendingPathComponent("素材根")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    /// 建一棵两层素材树（txt 正文带唯一关键词，供内容观测验证）。
    @discardableResult
    private func makeTree(files: Int = 12) throws -> URL {
        let sub = root.appendingPathComponent("合同档案")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        for i in 1...files {
            try "归档备注 重链接第\(i)号文件".write(to: sub.appendingPathComponent("归档-\(i).txt"),
                                                 atomically: true, encoding: .utf8)
        }
        return sub
    }
    private func makeEngine() throws -> AstfindEngine {
        try AstfindEngine(home: home.appendingPathComponent("data"))
    }

    /// PRD R2 验收主链路：建源→扫描→抽取→整棵移动→ relink(新根) → 匹配率 100% →
    /// 在线可搜、内容观测不丢（extractContent 全 skippedUnchanged）。
    func testRelinkAfterMovingEntireTreePreservesContent() throws {
        _ = try makeTree()
        let engine = try makeEngine()
        engine.autoExtractContent = false
        let record = try engine.register(path: root.path, name: "素材根", kind: .local)
        let first = try XCTUnwrap(engine.extractContent(sourceId: record.sourceId))
        XCTAssertEqual(first.processed, 12, "首轮全部抽取")
        XCTAssertGreaterThanOrEqual(engine.contentSearch("重链接第").count, 12)

        // 素材整体搬家（模拟换盘/换 NAS 后内容在新位置）
        let newRoot = home.appendingPathComponent("搬家后位置")
        try FileManager.default.moveItem(at: root, to: newRoot)
        engine.refreshMounts()   // 旧路径失效 → 离线（快照保留）

        // 评估：目录锚点直接指认新根
        let report = try engine.analyzeRelink(sourceId: record.sourceId, anchor: newRoot)
        XCTAssertEqual(report.matchRate, 1.0, "纯移动应 100% 匹配（含大小一致）")
        XCTAssertEqual(report.candidateRoot, newRoot.path)
        XCTAssertEqual(report.totalAssets, 12)

        // 确认 → 重绑 → 重扫收敛
        try engine.applyRelink(sourceId: record.sourceId, to: report.candidateRoot)
        XCTAssertTrue(engine.waitForScans(timeout: 60))
        let rebound = try XCTUnwrap(engine.records().first)
        XCTAssertEqual(rebound.mountPath, newRoot.path)
        XCTAssertEqual(rebound.onlineState, .online)
        let rows = engine.search("归档")?.rows ?? []
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy { $0.path.hasPrefix(newRoot.path) }, "结果路径收敛到新根")

        // 内容观测不丢：重扫后 token 未变 → 全部 skippedUnchanged（零重抽）
        let second = try XCTUnwrap(engine.extractContent(sourceId: record.sourceId))
        XCTAssertEqual(second.extracted, 0, "不得重新抽取")
        XCTAssertEqual(second.processed, 0)
        XCTAssertEqual(second.skippedUnchanged, 0, "未变更 token 在入队层跳过，不重复建任务")
        XCTAssertGreaterThanOrEqual(engine.contentSearch("重链接第").count, 12, "内容命中保留")
        engine.stop()
    }

    /// 锚点消歧（PRD 验收）：新位置套了一层目录，锚点文件仍能定位真正根；
    /// 而误选包装目录作锚点时报告低匹配率（不做部分重绑）。
    func testAnchorFileResolvesTrueRootThroughWrapperDirectory() throws {
        _ = try makeTree(files: 8)
        let engine = try makeEngine()
        engine.autoExtractContent = false
        let record = try engine.register(path: root.path, name: "素材根", kind: .local)

        // 新位置把真根整套进一层"搬家包装"目录
        let wrapper = home.appendingPathComponent("新位置").appendingPathComponent("搬家包装")
        try FileManager.default.createDirectory(at: wrapper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: root, to: wrapper)

        // 用户只点了里面的一个文件（锚点模式）
        let anchor = wrapper.appendingPathComponent("合同档案").appendingPathComponent("归档-3.txt")
        let report = try engine.analyzeRelink(sourceId: record.sourceId, anchor: anchor)
        XCTAssertEqual(report.candidateRoot, wrapper.path, "锚点按相对路径反推出真正根（剥掉包装层）")
        XCTAssertEqual(report.matchRate, 1.0)

        // 误选包装目录本身 → 匹配率 0，交由用户改选（不猜、不部分重绑）
        let wrong = try engine.analyzeRelink(sourceId: record.sourceId, anchor: wrapper.deletingLastPathComponent())
        XCTAssertEqual(wrong.matchRate, 0, accuracy: 0.001, "包装目录不是根：缺失应全部报告")
        XCTAssertEqual(wrong.missingSamples.count, 8)
        engine.stop()
    }

    /// 报告完整性：缺失清单 + 大小不符计数；低于阈值时调用方（CLI/UI）拒绝重绑。
    func testReportShowsMissingAndSizeMismatch() throws {
        _ = try makeTree(files: 12)
        let engine = try makeEngine()
        engine.autoExtractContent = false
        let record = try engine.register(path: root.path, name: "素材根", kind: .local)

        let newRoot = home.appendingPathComponent("部分损坏的新位置")
        try FileManager.default.moveItem(at: root, to: newRoot)
        try FileManager.default.removeItem(at: newRoot.appendingPathComponent("合同档案").appendingPathComponent("归档-5.txt"))
        try FileManager.default.removeItem(at: newRoot.appendingPathComponent("合同档案").appendingPathComponent("归档-7.txt"))
        try "改大了的内容，长度与原来明显不同，用于触发大小不符。".write(
            to: newRoot.appendingPathComponent("合同档案").appendingPathComponent("归档-9.txt"),
            atomically: true, encoding: .utf8)

        let report = try engine.analyzeRelink(sourceId: record.sourceId, anchor: newRoot)
        XCTAssertEqual(report.matched, 9)
        XCTAssertEqual(report.sizeMismatched, 1)
        XCTAssertEqual(report.missingSamples.count, 2, "缺失清单含被删文件")
        XCTAssertEqual(report.matchRate, 9.0 / 12.0, accuracy: 0.001)
        XCTAssertFalse(report.missingSamples.contains { !$0.hasPrefix("合同档案/") })
        engine.stop()
    }

    /// SMB 源重链接到另一共享位置：locator 身份随新位置更新（换 NAS 主机场景）。
    func testSMBRelinkUpdatesShareIdentity() throws {
        final class FakeSMBResolver: SMBShareResolving {
            var mounts: [SMBShareMount] = []
            func smbShareMounts() -> [SMBShareMount] { mounts }
        }
        let resolver = FakeSMBResolver()
        _ = try makeTree(files: 6)
        let engine = try AstfindEngine(home: home.appendingPathComponent("data"),
                                       volumeResolver: SMBIdentityTests.EmptyVolumeResolver(),
                                       smbResolver: resolver)
        // fake host oldnas.local/newnas.local 不存在；SMB 存活探测注入为真。
        engine.smbServerProbe = { _ in true }
        engine.autoExtractContent = false
        let oldShareMount = home.appendingPathComponent("oldnas")
        try FileManager.default.createDirectory(at: oldShareMount, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: root, to: oldShareMount.appendingPathComponent("素材根"))
        resolver.mounts = [SMBShareMount(shareURL: "smb://oldnas.local/share", mountPath: oldShareMount.path)]
        let record = try engine.register(path: oldShareMount.appendingPathComponent("素材根").path,
                                         name: "素材根", kind: .external)
        XCTAssertEqual(record.locator, "smb://oldnas.local/share/素材根")

        // 换新 NAS：共享挂到新主机名下，内容在新共享里
        let newShareMount = home.appendingPathComponent("newnas")
        try FileManager.default.createDirectory(at: newShareMount, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: oldShareMount.appendingPathComponent("素材根"),
                                         to: newShareMount.appendingPathComponent("素材根"))
        resolver.mounts = [SMBShareMount(shareURL: "smb://newnas.local/share", mountPath: newShareMount.path)]

        let report = try engine.analyzeRelink(sourceId: record.sourceId,
                                              anchor: newShareMount.appendingPathComponent("素材根"))
        XCTAssertEqual(report.matchRate, 1.0)
        try engine.applyRelink(sourceId: record.sourceId, to: report.candidateRoot)
        XCTAssertTrue(engine.waitForScans(timeout: 60))
        let rebound = try XCTUnwrap(engine.records().first)
        XCTAssertEqual(rebound.locator, "smb://newnas.local/share/素材根", "身份随重链接更新到新共享")
        XCTAssertEqual(rebound.onlineState, .online)
        XCTAssertFalse(engine.search("归档")?.rows.isEmpty ?? true)
        engine.stop()
    }

    /// 锚点在快照中无对应（随手选了个不相关文件）→ 明确报错，不猜。
    func testUnrelatedAnchorFileErrors() throws {
        _ = try makeTree(files: 4)
        let engine = try makeEngine()
        engine.autoExtractContent = false
        let record = try engine.register(path: root.path, name: "素材根", kind: .local)
        let stranger = home.appendingPathComponent("无关文件.txt")
        try "无关内容".write(to: stranger, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try engine.analyzeRelink(sourceId: record.sourceId, anchor: stranger)) {
            XCTAssertEqual($0 as? AstfindEngine.RelinkError, .anchorUnresolvable("锚点文件在「素材根」的快照中找不到对应资产"))
        }
        engine.stop()
    }

    // MARK: R3 设置页入口的锚定语义

    /// 门槛语义：≥90% 才允许确认重绑（UI 确认按钮与 CLI --confirm 共用同一判定，防两处漂移）。
    func testMeetsThresholdGating() {
        func report(matched: Int, sampled: Int) -> AstfindEngine.RelinkReport {
            AstfindEngine.RelinkReport(sourceId: "s", candidateRoot: "/r", totalAssets: sampled,
                                       sampled: sampled, matched: matched, sizeMismatched: 0, missingSamples: [])
        }
        XCTAssertTrue(report(matched: 90, sampled: 100).meetsThreshold, "恰好 90% 应达标")
        XCTAssertFalse(report(matched: 89, sampled: 100).meetsThreshold, "89% 不足，提示改选目录")
        XCTAssertFalse(report(matched: 0, sampled: 0).meetsThreshold, "无样本（无从匹配）不得放行")
        XCTAssertTrue(report(matched: 8, sampled: 8).meetsThreshold)
    }

    /// 重链接弹窗的样例文件：来自快照真实资产、条数受控（帮用户回忆原始内容）。
    func testSampleRelativePathsForRelinkDialog() throws {
        _ = try makeTree(files: 12)
        let engine = try makeEngine()
        engine.autoExtractContent = false
        let record = try engine.register(path: root.path, name: "素材根", kind: .local)
        let samples = engine.sampleRelativePaths(sourceId: record.sourceId, count: 3)
        XCTAssertEqual(samples.count, 3)
        XCTAssertTrue(samples.allSatisfy { $0.hasPrefix("合同档案/归档-") && $0.hasSuffix(".txt") },
                      "样例必须是快照里的真实相对路径")
        XCTAssertTrue(engine.sampleRelativePaths(sourceId: record.sourceId, count: 5).count == 5)
        engine.stop()
    }
}
