import XCTest
import OilFindCore
@testable import AstfindKit

/// D5 验收核心场景的无头版：在线命中、拔线离线可见不可开（isOnline=false）、
/// 重挂载后台重扫收敛、双来源同名不合并、引擎重启（App 重启）恢复。
final class EngineTests: XCTestCase {
    private var home: URL!
    private var shareA: URL!
    private var shareB: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("astfind-engine-\(UUID().uuidString)")
        shareA = home.appendingPathComponent("nas-a")
        shareB = home.appendingPathComponent("ssd-b")
        try FileManager.default.createDirectory(at: shareA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shareB, withIntermediateDirectories: true)
        for i in 1...10 {
            try "a\(i)".write(to: shareA.appendingPathComponent("报告-\(i).pdf"), atomically: true, encoding: .utf8)
            try "b\(i)".write(to: shareB.appendingPathComponent("报告-\(i).pdf"), atomically: true, encoding: .utf8)   // 同名跨来源
        }
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func makeEngine() throws -> AstfindEngine {
        try AstfindEngine(home: home.appendingPathComponent("data"))
    }

    /// 输入卡顿回归（2026-10-19）：sources() 热路径不得每次调用都探测文件系统。
    /// 面板在索引重建期以 ~2Hz、输入期每键拉一次 sources()；曾对 NAS 路径同步
    /// SMB fileExists 卡住主线程。缓存命中必须零探测；变化检测交给后台 TTL 重验。
    func testSourcesHotPathAvoidsRepeatedReachabilityProbes() throws {
        let engine = try makeEngine()
        var probeCount = 0
        engine.reachabilityProbe = { path in
            probeCount += 1
            return FileManager.default.fileExists(atPath: path)
        }
        engine.reachabilityTTL = 6   // 拉长 TTL，测试窗口内后台重验不干扰计数
        _ = try engine.register(path: shareA.path, name: "NAS 甲", scanNow: false)
        engine.start()

        let afterWarmup = probeCount
        for _ in 0..<20 { _ = engine.sources() }
        XCTAssertEqual(probeCount, afterWarmup, "20 次 sources() 应全部命中缓存，零文件系统探测")

        // 事件驱动失效仍即时：目录移走 + refreshMounts → sources() 立即反映离线
        let tucked = home.appendingPathComponent("tucked")
        try FileManager.default.moveItem(at: shareA, to: tucked)
        engine.refreshMounts()
        XCTAssertTrue(engine.sources().allSatisfy { !$0.isOnline })
        engine.stop()
    }

    func testFaceMinScoreClampsToSupportedRange() throws {
        let engine = try makeEngine()
        engine.setFaceMinScore(0.1)
        XCTAssertEqual(engine.faceMinScore, 0.2)
        engine.setFaceMinScore(0.95)
        XCTAssertEqual(engine.faceMinScore, 0.9)
        engine.setFaceMinScore(0.35)
        XCTAssertEqual(engine.faceStatus().minScore, 0.35)
        engine.stop()
    }

    func testUnifiedSearchAndSameNameAcrossSources() throws {
        let engine = try makeEngine()
        _ = try engine.register(path: shareA.path, name: "NAS 甲")
        _ = try engine.register(path: shareB.path, name: "SSD 乙")
        engine.start()
        let sources = engine.sources()
        XCTAssertEqual(sources.count, 2)
        XCTAssertTrue(sources.allSatisfy(\.isOnline), "两来源挂载可达且已重扫，应在线")

        let result = try XCTUnwrap(engine.search("报告-3"))
        XCTAssertEqual(result.total, 2)
        let names = Set(result.rows.map(\.source))
        XCTAssertEqual(names, ["NAS 甲", "SSD 乙"], "同名文件跨来源不合并")
        engine.stop()
    }

    func testUnplugKeepsSourceSearchableButOffline() throws {
        let engine = try makeEngine()
        _ = try engine.register(path: shareA.path, name: "NAS 甲")
        engine.start()
        XCTAssertTrue(engine.sources().allSatisfy(\.isOnline))

        // 拔线：目录移走 + 刷新挂载（模拟 NSWorkspace 卸载通知）
        let tucked = home.appendingPathComponent("tucked")
        try FileManager.default.moveItem(at: shareA, to: tucked)
        engine.refreshMounts()
        let offlineSources = engine.sources()
        XCTAssertEqual(offlineSources.count, 1)
        XCTAssertEqual(offlineSources.first?.isOnline, false, "离线来源保留可搜但标记不可打开")

        let result = try XCTUnwrap(engine.search("报告-7"))
        XCTAssertEqual(result.total, 1)
        XCTAssertEqual(result.rows.first?.online, false)
        engine.stop()
        try FileManager.default.moveItem(at: tucked, to: shareA)
    }

    func testRemountAtDifferentPathRescansInBackground() throws {
        let engine = try makeEngine()
        _ = try engine.register(path: shareA.path, name: "NAS 甲")
        engine.stop()

        // 换名重挂载，重启引擎（App 重启语义）：离线先可搜 → 后台重扫 → 在线 + 新路径
        let remounted = home.appendingPathComponent("nas-a-remounted")
        try FileManager.default.moveItem(at: shareA, to: remounted)
        let engine2 = try makeEngine()
        var changes = 0
        engine2.onSourcesChange = { changes += 1 }
        engine2.start()
        // 立即可搜（离线快照，旧根路径）
        XCTAssertGreaterThanOrEqual(engine2.search("报告-1")?.total ?? 0, 1)

        // 更新挂载点并等待后台重扫完成
        let record = engine2.records().first
        try engine2.updateMount(sourceId: record!.sourceId, path: remounted.path)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, engine2.sources().first?.isOnline != true { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertEqual(engine2.sources().first?.isOnline, true)
        XCTAssertGreaterThanOrEqual(changes, 1, "状态变化必须通知 UI")
        let rows = engine2.search("报告-2")?.rows ?? []
        XCTAssertTrue(rows.contains { $0.path.hasPrefix(remounted.path) }, "重扫后结果路径在新挂载点下")
        engine2.stop()
    }

    func testEngineRestartRestoresSourcesFromRegistry() throws {
        do {
            let engine = try makeEngine()
            _ = try engine.register(path: shareA.path, name: "NAS 甲")
            engine.stop()
        }
        // "App 重启"：全新引擎实例，registry 持久化 + 快照离线加载
        let engine2 = try makeEngine()
        XCTAssertEqual(engine2.records().count, 1)
        XCTAssertEqual(engine2.records().first?.displayName, "NAS 甲")
        engine2.start()
        let sources = engine2.sources()
        XCTAssertEqual(sources.count, 1)
        XCTAssertGreaterThanOrEqual(engine2.search("报告-5")?.total ?? 0, 1)
        engine2.stop()
    }
}
