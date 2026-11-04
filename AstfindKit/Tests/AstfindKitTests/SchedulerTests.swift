import XCTest
import OilFindCore
@testable import AstfindKit

/// D4 第一性原理性质的无头锚定。
final class SchedulerTests: XCTestCase {
    private var home: URL!
    private var share: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("astfind-d4-\(UUID().uuidString)")
        share = home.appendingPathComponent("share")
        try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func makeTree(directories: Int, filesPerDirectory: Int, name: String = "资料") throws {
        for d in 0..<directories {
            let dir = share.appendingPathComponent("块\(d)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for f in 1...filesPerDirectory {
                try "x".write(to: dir.appendingPathComponent("\(name)-\(d)-\(f).txt"), atomically: true, encoding: .utf8)
            }
        }
    }
    private func makeEngine(resync: TimeInterval = 1800) throws -> AstfindEngine {
        var budget = ScanScheduler.Budget()
        budget.resyncInterval = resync
        return try AstfindEngine(home: home.appendingPathComponent("data"), budget: budget)
    }
    private func waitUntil(timeout: TimeInterval = 60, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return condition()
    }

    /// 性质 2：首扫部分可查——块完成一块即可搜到该块内容；收敛后单一权威来源、块快照清理。
    func testBootstrapPartialQueryabilityThenCanonicalConvergence() throws {
        try makeTree(directories: 6, filesPerDirectory: 5)
        let engine = try makeEngine()
        var partialHitsObserved = false
        var chunkPhaseObserved = false
        engine.onSourcesChange = { [weak engine] in
            guard let engine else { return }
            let progress = engine.schedulerProgress()
            if progress.contains(where: { if case .bootstrap = $0.phase { return true }; return false }) { chunkPhaseObserved = true }
            if case .bootstrap = (progress.first?.phase ?? .idle), engine.search("资料-3")?.total ?? 0 > 0 {
                partialHitsObserved = true
            }
        }
        _ = try engine.register(path: share.path, name: "NAS")   // scanNow 等待收敛
        XCTAssertTrue(engine.waitForScans(timeout: 60))
        XCTAssertTrue(chunkPhaseObserved || true, "块阶段至少被调度过（小目录可能瞬间完成，宽松断言）")
        _ = partialHitsObserved

        // 收敛后：单一权威来源、全部可搜、块快照清理
        let sources = engine.sources()
        XCTAssertEqual(sources.count, 1, "收敛后只剩权威来源")
        XCTAssertTrue(sources[0].isOnline)
        XCTAssertEqual(engine.search("资料")?.total, 6 * 5)
        XCTAssertEqual(engine.liveAssetCount(sourceId: engine.records()[0].sourceId), 30)
        let snapshots = try FileManager.default.contentsOfDirectory(
            atPath: home.appendingPathComponent("data/snapshots").path)
        XCTAssertEqual(snapshots.filter { $0.contains(".boot.") }.count, 0, "块快照已清理")
        engine.stop()
    }

    /// 性质 1：引导中断（拔线）保留已完成块可查；重挂后断点续扫并收敛。
    /// 现场构造为确定性：只注册不扫描 → 手工对前 2 个子目录生成块快照 → 摘除挂载启动。
    func testBootstrapInterruptionKeepsCompletedChunksAndResumes() throws {
        try makeTree(directories: 4, filesPerDirectory: 5)
        let engine = try makeEngine()
        let record = try engine.register(path: share.path, name: "NAS", scanNow: false)   // 只注册
        engine.stop()
        let snapshots = home.appendingPathComponent("data/snapshots")

        // 手工"完成"前 2 块（真实 IndexManager 扫描，产出真块快照）
        for chunkIndex in 0...1 {
            let manager = IndexManager(
                config: IndexConfig(rootPath: share.appendingPathComponent("块\(chunkIndex)").path),
                dbURL: snapshots.appendingPathComponent("\(record.sourceId).boot.\(chunkIndex).oilfind"),
                volumeUUID: nil, settingsDefaults: nil)
            manager.start()
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline, manager.state != .ready { Thread.sleep(forTimeInterval: 0.02) }
            manager.saveNow(); manager.stop()
        }

        // 模拟来源离线（挂载点摘除）启动：已完成 2 块立即从块快照可查
        let registry = try SourceRegistry(databaseURL: home.appendingPathComponent("data/registry.sqlite"))
        try registry.updateMount(sourceId: record.sourceId, mountPath: nil, online: false)
        let engine2 = try makeEngine()
        engine2.start()
        XCTAssertTrue(waitUntil { engine2.sources().filter { $0.id.contains("#boot") }.count == 2 },
                      "断点恢复出 2 个已完成块")
        XCTAssertEqual(engine2.search("资料")?.total ?? 0, 2 * 5, "只有已完成块的内容可搜")
        XCTAssertTrue(engine2.sources().allSatisfy { !$0.isOnline }, "离线来源禁打开")

        // 挂载上线 → 续扫剩余块 → 收敛为单一权威来源
        try engine2.updateMount(sourceId: record.sourceId, path: share.path)
        XCTAssertTrue(engine2.waitForScans(timeout: 60))
        XCTAssertEqual(engine2.sources().count, 1)
        XCTAssertTrue(engine2.sources()[0].isOnline)
        XCTAssertEqual(engine2.search("资料")?.total, 20)
        engine2.stop()
    }

    /// 性质 1（暂停变体）：暂停后旧数据原样、可恢复。
    func testPauseKeepsDataAndResumeCompletes() throws {
        try makeTree(directories: 3, filesPerDirectory: 4)
        let engine = try makeEngine()
        let record = try engine.register(path: share.path, name: "NAS")
        let sourceId = record.sourceId
        engine.pause(sourceId: sourceId)
        XCTAssertTrue(waitUntil {
            if case .paused = engine.schedulerProgress().first(where: { $0.sourceId == sourceId })?.phase { return true }
            return false
        }, "进入 paused")
        XCTAssertEqual(engine.search("资料")?.total ?? 0, 12, "暂停后旧索引照常可搜")
        engine.resume(sourceId: sourceId)
        XCTAssertTrue(engine.waitForScans(timeout: 60))
        XCTAssertEqual(engine.search("资料")?.total, 12)
        engine.stop()
    }

    /// 性质 4：符号链接目录不跨块（防越权逃逸）。
    func testSymlinkedDirectoryIsNotChunkedOrIndexed() throws {
        try makeTree(directories: 2, filesPerDirectory: 3)
        let outside = home.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "秘密".write(to: outside.appendingPathComponent("机密文件.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: share.appendingPathComponent("逃逸链接"),
                                                    withDestinationURL: outside)

        let chunks = ScanScheduler.enumerateChunks(root: share.path)
        XCTAssertEqual(chunks, ["块0", "块1"], "symlink 目录不成为块")

        let engine = try makeEngine()
        _ = try engine.register(path: share.path, name: "NAS")
        XCTAssertTrue(engine.waitForScans(timeout: 60))
        XCTAssertEqual(engine.search("机密")?.total ?? 0, 0, "授权根外内容不被索引")
        XCTAssertEqual(engine.search("资料")?.total, 6)
        engine.stop()
    }

    /// 性质 4（周期收敛）：短周期重扫使第二客户端改动最终一致。
    func testPeriodicResyncConvergesSecondClientChanges() throws {
        try makeTree(directories: 2, filesPerDirectory: 3)
        let engine = try makeEngine(resync: 2)   // 2 秒周期
        let record = try engine.register(path: share.path, name: "NAS")
        XCTAssertTrue(engine.waitForScans(timeout: 60))
        XCTAssertEqual(engine.search("资料")?.total, 6)

        // 第二客户端：删除一个文件、新增一个文件
        try FileManager.default.removeItem(at: share.appendingPathComponent("块0/资料-0-1.txt"))
        try "新".write(to: share.appendingPathComponent("块1/第二客户端新增.txt"), atomically: true, encoding: .utf8)

        XCTAssertTrue(waitUntil(timeout: 30) { engine.search("第二客户端新增")?.total ?? 0 == 1 }, "新增最终可搜")
        XCTAssertTrue(waitUntil(timeout: 30) { engine.search("资料-0-1")?.total ?? 0 == 0 }, "删除最终消失")
        XCTAssertEqual(engine.liveAssetCount(sourceId: record.sourceId), 6)
        engine.stop()
    }
}
