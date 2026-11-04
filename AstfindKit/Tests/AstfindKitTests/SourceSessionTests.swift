import XCTest
import OilFindCore
@testable import AstfindKit

/// 端到端：SourceSession 驱动真实 IndexManager，覆盖 D2 验收要求的
/// 「重启索引恢复」「断线失败事务不清空数据」。
final class SourceSessionTests: XCTestCase {
    private var directory: URL!
    private var root: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("astfind-kit-session-\(UUID().uuidString)")
        root = directory.appendingPathComponent("share")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for i in 1...20 {
            let sub = root.appendingPathComponent("docs\(i % 3)")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try "content \(i)\n".write(to: sub.appendingPathComponent("file-\(i).txt"), atomically: true, encoding: .utf8)
        }
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func makeRegistry() throws -> (SourceRegistry, SourceRecord) {
        let registry = try SourceRegistry(databaseURL: directory.appendingPathComponent("registry.sqlite"))
        let record = try registry.registerSource(kind: .local, locator: root.path, displayName: "Test Share")
        return (registry, record)
    }

    func testOnlineScanThenOfflineReloadAfterAppRestart() throws {
        let (registry, record) = try makeRegistry()
        let session = try SourceSession(record: record, registry: registry,
                                        snapshotDirectory: directory.appendingPathComponent("snapshots"))
        let online = try session.scanOnline(mountPath: root.path, timeout: 60)
        XCTAssertNotNil(online)
        XCTAssertEqual(session.state, .onlineReady)
        XCTAssertEqual(try registry.liveAssetCount(sourceId: record.sourceId), 20)
        var reloaded = try registry.source(id: record.sourceId)
        XCTAssertEqual(reloaded?.indexState, .ready)
        XCTAssertEqual(reloaded?.snapshotRootPath, root.path)
        session.stop()

        // 模拟来源离线（目录整个消失）+ App 重启（全新 Session）
        let moved = directory.appendingPathComponent("share-away")
        try FileManager.default.moveItem(at: root, to: moved)
        let offlineSession = try SourceSession(record: try XCTUnwrap(try registry.source(id: record.sourceId)),
                                               registry: registry,
                                               snapshotDirectory: directory.appendingPathComponent("snapshots"))
        let offline = try offlineSession.loadOffline()
        XCTAssertNotNil(offline)
        XCTAssertEqual(offlineSession.state, .offlineReady)
        XCTAssertEqual(offline?.isOnline, false)

        // 离线查询零源 I/O：目录不存在仍能命中
        let result = try XCTUnwrap(MultiSearcher.search(Query.parse("file-7"), in: [offline!]))
        XCTAssertTrue(result.total >= 1)
        let path = result.sources[result.items[0].sourceIndex].store.path(result.items[0].entryID)
        XCTAssertTrue(path.hasPrefix(root.path))   // 结果保留快照原始根，展示层负责重绑

        // 恢复在线：挂载点换名重扫（换路径 → 指纹变化 → 完整重扫），收敛
        let remounted = directory.appendingPathComponent("share-remounted")
        try FileManager.default.moveItem(at: moved, to: remounted)
        let onlineAgain = try session.scanOnline(mountPath: remounted.path, timeout: 60)
        XCTAssertNotNil(onlineAgain)
        XCTAssertEqual(try registry.liveAssetCount(sourceId: record.sourceId), 20)
        reloaded = try registry.source(id: record.sourceId)
        XCTAssertEqual(reloaded?.snapshotRootPath, remounted.path)
        session.stop()
    }

    func testFailedScanKeepsOldIndexAndAssets() throws {
        let (registry, record) = try makeRegistry()
        let session = try SourceSession(record: record, registry: registry,
                                        snapshotDirectory: directory.appendingPathComponent("snapshots"))
        _ = try session.scanOnline(mountPath: root.path, timeout: 60)
        XCTAssertEqual(try registry.liveAssetCount(sourceId: record.sourceId), 20)
        session.stop()

        // 目录消失后尝试在线扫描：必须失败收尾且不动旧数据
        try FileManager.default.removeItem(at: root)
        let failing = try session.scanOnline(mountPath: root.path, timeout: 30)
        XCTAssertNil(failing)
        var reloaded = try registry.source(id: record.sourceId)
        XCTAssertEqual(reloaded?.indexState, .stale)          // 降级而非清空
        XCTAssertEqual(try registry.liveAssetCount(sourceId: record.sourceId), 20)   // 资产行原样
        XCTAssertNotNil(reloaded?.lastSuccessfulScanAt)

        // 失败后离线加载仍可用（旧快照未被破坏）
        let offline = try session.loadOffline()
        XCTAssertNotNil(offline)
        reloaded = try registry.source(id: record.sourceId)
        _ = reloaded
        session.stop()
    }

    func testEntriesExtractionSkipsRootAndProducesRelativePaths() throws {
        let (registry, record) = try makeRegistry()
        let session = try SourceSession(record: record, registry: registry,
                                        snapshotDirectory: directory.appendingPathComponent("snapshots"))
        _ = try session.scanOnline(mountPath: root.path, timeout: 60)
        let store = try XCTUnwrap(session.searchSource?.store)
        let entries = SourceRegistry.entries(in: store)
        XCTAssertEqual(entries.count, 20)
        for entry in entries {
            XCTAssertFalse(entry.relativePath.hasPrefix("/"))
            XCTAssertFalse(entry.relativePath.contains(root.path))
        }
        session.stop()
    }
}
