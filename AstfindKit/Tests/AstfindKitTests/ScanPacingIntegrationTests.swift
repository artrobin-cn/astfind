import XCTest
import OilFindCore
@testable import AstfindKit

/// M0.6：分块首扫与权威重扫都必须安装 Pacer；本地/外置来源不创建等待。
final class ScanPacingIntegrationTests: XCTestCase {
    private var home: URL!
    private var share: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("astfind-m06-\(UUID().uuidString)")
        share = home.appendingPathComponent("share")
        try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func makeTree(chunks: Int, filesPerChunk: Int) throws {
        for chunk in 0..<chunks {
            let directory = share.appendingPathComponent("块\(chunk)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for file in 0..<filesPerChunk {
                try "body-\(chunk)-\(file)".write(
                    to: directory.appendingPathComponent("content-\(chunk)-\(file).txt"),
                    atomically: true, encoding: .utf8)
            }
        }
    }

    private func makeEngine() throws -> AstfindEngine {
        try AstfindEngine(home: home.appendingPathComponent("data"))
    }

    func testSMBChunkAndCanonicalScansInstallPacers() throws {
        try makeTree(chunks: 3, filesPerChunk: 3)
        let engine = try makeEngine()
        _ = try engine.register(path: share.path, name: "NAS", kind: .smb)
        XCTAssertTrue(engine.waitForScans(timeout: 60))
        XCTAssertEqual(engine.search("content")?.total, 9)

        let kinds = engine.scanPacingForTesting.createdPacerKinds
        let smbPacers = kinds.filter { $0 == .smb }.count
        XCTAssertGreaterThanOrEqual(smbPacers, 4,
                                    "3 个分块首扫 + 1 次权威重扫都应安装 Pacer（实际 \(kinds)）")
        XCTAssertFalse(engine.isSMBScanThrottled, "无前台活动时不得进入降速")
        engine.stop()
    }

    func testLocalSourcesTakePassThroughPathWithoutPacer() throws {
        try makeTree(chunks: 1, filesPerChunk: 2)
        let engine = try makeEngine()
        _ = try engine.register(path: share.path, name: "Local", kind: .local)
        XCTAssertTrue(engine.waitForScans(timeout: 60))
        XCTAssertEqual(engine.sources().count, 1)
        let kinds = engine.scanPacingForTesting.createdPacerKinds
        XCTAssertTrue(kinds.allSatisfy { $0 == .local }, "本地来源不创建 SMB Pacer：\(kinds)")
        XCTAssertFalse(engine.scanPacingForTesting.isThrottled)
        engine.stop()
    }

    private func waitUntil(timeout: TimeInterval = 30, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    /// PM 补验：反复显隐不得更换权威重扫 run 或 Scanner 实例身份。
    func testRepeatedVisibilityKeepsCanonicalRunAndScannerIdentity() throws {
        let bulk = share.appendingPathComponent("bulk")
        try FileManager.default.createDirectory(at: bulk, withIntermediateDirectories: true)
        for index in 0..<500 {
            try FileManager.default.createDirectory(
                at: bulk.appendingPathComponent(String(format: "d%04d", index)),
                withIntermediateDirectories: true)
        }
        let registry = try SourceRegistry(databaseURL: home.appendingPathComponent("data/registry.sqlite"))
        let record = try registry.registerSource(kind: .smb, locator: share.path, displayName: "NAS")
        let session = try SourceSession(record: record, registry: registry,
                                        snapshotDirectory: home.appendingPathComponent("data/snapshots"))
        let coordinator = ForegroundActivityCoordinator()
        coordinator.setPanel(visible: false)
        session.scanPacing = ScanPacingController(coordinator: coordinator,
                                                  enabledProvider: { true })
        let finished = DispatchSemaphore(value: 0)
        let mountPath = share.path
        DispatchQueue.global(qos: .utility).async {
            _ = try? session.scanOnline(mountPath: mountPath, timeout: 180)
            finished.signal()
        }
        XCTAssertTrue(waitUntil {
            session.isScanningForTesting
                && session.activeScanRunIdForTesting != nil
                && session.scannerIdentityForTesting != nil
                && session.scannedCount > 0
        }, "扫描必须已开始并可观察 run/scanner 身份")
        let runBefore = try XCTUnwrap(session.activeScanRunIdForTesting)
        let scannerBefore = try XCTUnwrap(session.scannerIdentityForTesting)

        for index in 0..<20 {
            coordinator.setPanel(visible: index % 2 == 0)
            Thread.sleep(forTimeInterval: 0.01)
        }
        coordinator.setPanel(visible: false)   // B 方案：恢复后才能完成扫描
        XCTAssertEqual(session.activeScanRunIdForTesting, runBefore,
                       "反复显隐不得新建 scan run")
        XCTAssertEqual(session.scannerIdentityForTesting, scannerBefore,
                       "反复显隐不得替换 Scanner")
        XCTAssertTrue(session.isScanningForTesting, "身份断言时扫描仍应进行")

        XCTAssertEqual(finished.wait(timeout: .now() + 120), .success)
        XCTAssertEqual(session.scannerIdentityForTesting, scannerBefore,
                       "完成扫描后仍是同一 Scanner 实例")
        XCTAssertNil(session.activeScanRunIdForTesting)
        session.stop()
    }

    /// 长测（默认跳过）：B 方案下，面板可见期间应暂停新扫描；隐藏后恢复。
    /// 运行：`ASTFIND_M06_LONG_TESTS=1 swift test --filter testVisibleScanSuspendsAndHiddenResumes`
    func testVisibleScanSuspendsAndHiddenResumes() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ASTFIND_M06_LONG_TESTS"] == "1",
                          "set ASTFIND_M06_LONG_TESTS=1 to run the long scan test")
        let bulk = share.appendingPathComponent("bulk")
        try FileManager.default.createDirectory(at: bulk, withIntermediateDirectories: true)
        for index in 0..<2_500 {
            try FileManager.default.createDirectory(
                at: bulk.appendingPathComponent(String(format: "d%04d", index)),
                withIntermediateDirectories: true)
        }
        let registry = try SourceRegistry(databaseURL: home.appendingPathComponent("data/registry.sqlite"))
        let record = try registry.registerSource(kind: .smb, locator: share.path, displayName: "NAS")
        let session = try SourceSession(record: record, registry: registry,
                                        snapshotDirectory: home.appendingPathComponent("data/snapshots"))
        let coordinator = ForegroundActivityCoordinator()
        coordinator.setPanel(visible: false)
        session.scanPacing = ScanPacingController(coordinator: coordinator,
                                                  enabledProvider: { true })
        let finished = DispatchSemaphore(value: 0)
        let mountPath = share.path
        DispatchQueue.global(qos: .utility).async {
            _ = try? session.scanOnline(mountPath: mountPath, timeout: 180)
            finished.signal()
        }
        XCTAssertTrue(waitUntil { session.isScanningForTesting && session.scannedCount > 0 },
                      "扫描必须已经产生条目")
        Thread.sleep(forTimeInterval: 0.3)
        let before = session.scannedCount
        coordinator.setPanel(visible: true)
        Thread.sleep(forTimeInterval: 1.5)
        let during = session.scannedCount
        XCTAssertLessThanOrEqual(during, before + 1, "面板可见时不应继续发放新扫描 I/O")
        coordinator.setPanel(visible: false)
        XCTAssertTrue(waitUntil(timeout: 10) { session.scannedCount > during },
                      "面板隐藏后扫描应恢复推进")
        try? session.cancelActiveScan()
        _ = finished.wait(timeout: .now() + 10)
        session.stop()
    }

    /// FIX-1：同一个测量会话内 start()+rescan() 的 Pacer 指标必须聚合，而不是只留最后一个。
    func testIndexManagerAggregatesPacerPassesAcrossStartAndRescan() throws {
        try makeTree(chunks: 2, filesPerChunk: 3)
        let dbURL = home.appendingPathComponent("data/aggregate.oilfind")
        let manager = IndexManager(config: IndexConfig(rootPath: share.path), dbURL: dbURL,
                                   volumeUUID: nil, settingsDefaults: nil)
        manager.scanPacerFactory = {
            ScanPacer(.init(batchInterval: 0, maximumWait: 0.01, isThrottled: { false }))
        }
        manager.beginScanMeasurement()
        manager.start()
        XCTAssertTrue(waitUntil { manager.state == .ready }, "首次扫描必须完成")
        let firstStore = try XCTUnwrap(manager.store)
        manager.rescan()
        XCTAssertTrue(waitUntil { manager.state == .ready && manager.store !== firstStore },
                      "权威重扫必须安装新快照")
        let passes = manager.lastScanPacerPasses
        XCTAssertEqual(passes.count, 2, "start+rescan 必须记录两个 pass")
        XCTAssertEqual(passes.filter { $0.kind == .initial }.count, 1)
        XCTAssertEqual(passes.filter { $0.kind == .rescan }.count, 1)
        XCTAssertTrue(passes.allSatisfy { $0.pacerInstalled && $0.scannedEntries > 0 })
        XCTAssertTrue(passes.allSatisfy { $0.metrics.permits > 0 })
        let aggregatePermits = passes.reduce(0) { $0 + $1.metrics.permits }
        XCTAssertEqual(manager.lastScanPacerMetrics?.permits, aggregatePermits,
                       "聚合值必须等于两个 pass 的 permits 之和")
        manager.endScanMeasurement()
        manager.stop()
    }

    func testInvalidSnapshotDoesNotCauseRedundantSecondPass() throws {
        try makeTree(chunks: 1, filesPerChunk: 2)
        let registry = try SourceRegistry(databaseURL: home.appendingPathComponent("data/registry.sqlite"))
        let record = try registry.registerSource(kind: .smb, locator: share.path, displayName: "NAS")
        let snapshotDirectory = home.appendingPathComponent("data/snapshots")
        try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        let snapshotURL = snapshotDirectory.appendingPathComponent(record.sourceId + ".oilfind")
        try Data("not-a-valid-index".utf8).write(to: snapshotURL)

        let session = try SourceSession(record: record, registry: registry,
                                        snapshotDirectory: snapshotDirectory)
        let coordinator = ForegroundActivityCoordinator()
        coordinator.setPanel(visible: false)
        session.scanPacing = ScanPacingController(coordinator: coordinator, enabledProvider: { true })
        let source = try session.scanOnline(mountPath: share.path, timeout: 60)
        XCTAssertNotNil(source)
        XCTAssertEqual(session.lastScanPassCountForTesting, 1,
                       "无效快照已被 start() 全扫时，scanOnline 不应再做第二次全扫")
        session.stop()
    }

    func testRepeatedVisibilityChangesDoNotRestartRunOrFailScan() throws {
        try makeTree(chunks: 2, filesPerChunk: 4)
        let engine = try makeEngine()
        let record = try engine.register(path: share.path, name: "NAS", kind: .smb, scanNow: false)
        engine.refreshMounts()
        // 20 次显隐只改变前台活动，不触发 pause/cancel/restart。
        for index in 0..<20 {
            engine.setInteractive(visible: index % 2 == 0, typing: false)
            Thread.sleep(forTimeInterval: 0.01)
        }
        engine.setInteractive(visible: false, typing: false)   // B 方案：恢复后收敛
        XCTAssertTrue(engine.waitForScans(timeout: 60))
        XCTAssertEqual(engine.liveAssetCount(sourceId: record.sourceId), 8)
        XCTAssertEqual(engine.schedulerProgress().first?.phase, .ready)
        engine.setInteractive(visible: false, typing: false)
        engine.stop()
    }
}
