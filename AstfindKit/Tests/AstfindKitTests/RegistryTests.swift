import XCTest
@testable import AstfindKit

final class RegistryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("astfind-kit-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }
    private func makeRegistry() throws -> SourceRegistry {
        try SourceRegistry(databaseURL: directory.appendingPathComponent("registry.sqlite"))
    }

    func testMigrationIsIdempotentAndVersioned() throws {
        let url = directory.appendingPathComponent("migrate.sqlite")
        let database = try Database(url: url)
        try Migrations.apply(to: database)
        let latest = Migrations.all.map(\.version).max() ?? 0
        XCTAssertEqual(database.userVersion, latest, "应用后版本=最新迁移（v2: FTS trigram）")
        try Migrations.apply(to: database)   // 重复应用幂等
        XCTAssertEqual(database.userVersion, latest)
        let tables = try database.query("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name") { $0.columnText(0) }
        for expected in ["storage_sources", "assets", "media_segments", "text_observations",
                         "text_observation_fts", "embedding_profiles", "embeddings", "scan_runs", "index_jobs",
                         "face_embeddings"] {
            XCTAssertTrue(tables.contains(expected), "missing table \(expected)")
        }
        // v7：设置页进度聚合的覆盖索引（无它时 69 万任务行的 GROUP BY 单次 1s+）
        let indexes = try database.query("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='index_jobs'") { $0.columnText(0) }
        XCTAssertTrue(indexes.contains("ix_index_jobs_type_source_state"), "missing progress covering index")
    }

    func testRegisterDuplicateRejectedAndLocatorNormalized() throws {
        let registry = try makeRegistry()
        let first = try registry.registerSource(kind: .smb, locator: "smb://nas.local/share/教学资料/", displayName: "教学 NAS")
        XCTAssertEqual(first.locator, "smb://nas.local/share/教学资料")   // 尾斜杠归一
        XCTAssertThrowsError(try registry.registerSource(kind: .smb, locator: "smb://nas.local/share/教学资料", displayName: "重复")) {
            XCTAssertEqual($0 as? RegistryError, .duplicateSource(kind: "smb", locator: "smb://nas.local/share/教学资料"))
        }
        // 凭据剥离：密码绝不能进库
        let withPassword = try registry.registerSource(kind: .smb, locator: "smb://user:secret@nas2.local/share", displayName: "带密码")
        XCTAssertFalse(withPassword.locator.contains("secret"))
        XCTAssertFalse(withPassword.locator.contains("user"))
        XCTAssertEqual(withPassword.locator, "smb://nas2.local/share")
        // 同 locator 不同 kind 允许共存
        _ = try registry.registerSource(kind: .local, locator: "/Volumes/Data/share", displayName: "本地")
        XCTAssertEqual(try registry.sources().count, 3)
    }

    func testMountUpdateRoundTrip() throws {
        let registry = try makeRegistry()
        let source = try registry.registerSource(kind: .smb, locator: "smb://nas.local/share", displayName: "NAS")
        try registry.updateMount(sourceId: source.sourceId, mountPath: "/Volumes/share", online: true)
        var loaded = try registry.source(id: source.sourceId)
        XCTAssertEqual(loaded?.mountPath, "/Volumes/share")
        XCTAssertEqual(loaded?.onlineState, .online)
        try registry.updateMount(sourceId: source.sourceId, mountPath: nil, online: false)
        loaded = try registry.source(id: source.sourceId)
        XCTAssertEqual(loaded?.mountPath, nil)
        XCTAssertEqual(loaded?.onlineState, .offline)
        XCTAssertThrowsError(try registry.updateMount(sourceId: "no-such", mountPath: "/x", online: true)) {
            XCTAssertEqual($0 as? RegistryError, .unknownSource("no-such"))
        }
    }

    func testContentIndexEnabledDefaultsTrueAndRoundTrips() throws {
        let registry = try makeRegistry()
        let source = try registry.registerSource(kind: .smb, locator: "smb://nas.local/photo", displayName: "照片")
        XCTAssertTrue(source.contentIndexEnabled, "内容索引默认开启，存量行为不变")
        try registry.setContentIndexEnabled(sourceId: source.sourceId, enabled: false)
        XCTAssertFalse(try XCTUnwrap(registry.source(id: source.sourceId)).contentIndexEnabled)
        try registry.setContentIndexEnabled(sourceId: source.sourceId, enabled: true)
        XCTAssertTrue(try XCTUnwrap(registry.source(id: source.sourceId)).contentIndexEnabled)
        XCTAssertThrowsError(try registry.setContentIndexEnabled(sourceId: "no-such", enabled: false)) {
            XCTAssertEqual($0 as? RegistryError, .unknownSource("no-such"))
        }
    }

    func testFaceIndexEnabledDefaultsFalseAndRoundTrips() throws {
        let registry = try makeRegistry()
        let source = try registry.registerSource(kind: .smb, locator: "smb://nas.local/people", displayName: "人物")
        XCTAssertFalse(source.faceIndexEnabled, "人脸索引默认关闭，必须显式开启")
        try registry.setFaceIndexEnabled(sourceId: source.sourceId, enabled: true)
        XCTAssertTrue(try XCTUnwrap(registry.source(id: source.sourceId)).faceIndexEnabled)
        try registry.setFaceIndexEnabled(sourceId: source.sourceId, enabled: false)
        XCTAssertFalse(try XCTUnwrap(registry.source(id: source.sourceId)).faceIndexEnabled)
        XCTAssertThrowsError(try registry.setFaceIndexEnabled(sourceId: "no-such", enabled: true)) {
            XCTAssertEqual($0 as? RegistryError, .unknownSource("no-such"))
        }
    }

    func testSameNameAcrossSourcesNotMerged() throws {
        let registry = try makeRegistry()
        let a = try registry.registerSource(kind: .smb, locator: "smb://nas-a/share", displayName: "A")
        let b = try registry.registerSource(kind: .smb, locator: "smb://nas-b/share", displayName: "B")
        _ = try registry.syncAssets(sourceId: a.sourceId, scanRunId: "run-a", scanRunCompleted: true,
                                    entries: [("docs/report.pdf", "doc", 10, 1)])
        _ = try registry.syncAssets(sourceId: b.sourceId, scanRunId: "run-b", scanRunCompleted: true,
                                    entries: [("docs/report.pdf", "doc", 20, 2)])
        let inA = try registry.assets(sourceId: a.sourceId)
        let inB = try registry.assets(sourceId: b.sourceId)
        XCTAssertEqual(inA.count, 1); XCTAssertEqual(inB.count, 1)
        XCTAssertEqual(inA.first?.size, 10)
        XCTAssertEqual(inB.first?.size, 20)   // 同名跨来源不合并、不互相覆盖
        XCTAssertNotEqual(inA.first?.assetId, inB.first?.assetId)
    }

    func testDeleteConfirmedOnlyOnCompletedScan() throws {
        let registry = try makeRegistry()
        let source = try registry.registerSource(kind: .local, locator: "/data", displayName: "本地")
        typealias Entry = (relativePath: String, kind: String, size: Int64, mtimeNs: Int64?)
        let base: [Entry] = [("a.txt", "doc", 1, 1), ("b.txt", "doc", 2, 2), ("c.txt", "doc", 3, 3)]
        _ = try registry.syncAssets(sourceId: source.sourceId, scanRunId: "run-1", scanRunCompleted: true, entries: base)
        XCTAssertEqual(try registry.liveAssetCount(sourceId: source.sourceId), 3)

        // 断线/部分扫描：只看到 a.txt，未见到的不允许标记删除
        let partial = try registry.syncAssets(sourceId: source.sourceId, scanRunId: "run-2", scanRunCompleted: false,
                                              entries: [("a.txt", "doc", 1, 1)])
        XCTAssertEqual(partial.staleUntouched, 2)
        XCTAssertEqual(partial.confirmedDeleted, 0)
        XCTAssertEqual(try registry.liveAssetCount(sourceId: source.sourceId), 3)

        // 完整扫描只见到 a.txt：b/c 确认删除
        let complete = try registry.syncAssets(sourceId: source.sourceId, scanRunId: "run-3", scanRunCompleted: true,
                                               entries: [("a.txt", "doc", 1, 1)])
        XCTAssertEqual(complete.confirmedDeleted, 2)
        XCTAssertEqual(try registry.liveAssetCount(sourceId: source.sourceId), 1)
        let all = try registry.assets(sourceId: source.sourceId, includeDeleted: true)
        XCTAssertEqual(all.filter { $0.deletedConfirmedAt != nil }.count, 2)

        // b.txt 回来（重连后重扫）：复活，deleted_confirmed_at 清空
        let resurrect = try registry.syncAssets(sourceId: source.sourceId, scanRunId: "run-4", scanRunCompleted: true,
                                                entries: [("a.txt", "doc", 1, 1), ("b.txt", "doc", 2, 2)])
        XCTAssertEqual(resurrect.resurrected, 1)   // b 复活而非新增
        XCTAssertEqual(resurrect.added, 0)
        XCTAssertEqual(resurrect.updated, 1)
        XCTAssertEqual(try registry.liveAssetCount(sourceId: source.sourceId), 2)
    }

    func testScanRunLifecycleAndIndexStates() throws {
        let registry = try makeRegistry()
        let source = try registry.registerSource(kind: .smb, locator: "smb://nas.local/share", displayName: "NAS")
        let run = try registry.beginScanRun(sourceId: source.sourceId)
        XCTAssertEqual(run.status, .running)
        var loaded = try registry.source(id: source.sourceId)
        XCTAssertEqual(loaded?.indexState, .empty)
        XCTAssertNotNil(loaded?.lastScanAt)

        try registry.endScanRun(run, success: false)   // 断线失败：stale，不清 last_successful
        loaded = try registry.source(id: source.sourceId)
        XCTAssertEqual(loaded?.indexState, .stale)
        XCTAssertNil(loaded?.lastSuccessfulScanAt)

        let run2 = try registry.beginScanRun(sourceId: source.sourceId)
        try registry.endScanRun(run2, success: true, snapshotRootPath: "/Volumes/share")
        loaded = try registry.source(id: source.sourceId)
        XCTAssertEqual(loaded?.indexState, .ready)
        XCTAssertEqual(loaded?.snapshotRootPath, "/Volumes/share")
        XCTAssertNotNil(loaded?.lastSuccessfulScanAt)
    }

    func testSourceRemovalCascades() throws {
        let registry = try makeRegistry()
        let source = try registry.registerSource(kind: .smb, locator: "smb://nas.local/share", displayName: "NAS")
        _ = try registry.syncAssets(sourceId: source.sourceId, scanRunId: "r", scanRunCompleted: true,
                                    entries: [("x.txt", "doc", 1, 1)])
        // 有 scan_runs/index_jobs 子行时也必须能删（曾因无级联子表阻塞删除——真 bug 锚定）
        let run = try registry.beginScanRun(sourceId: source.sourceId)
        try registry.endScanRun(run, success: true)
        try registry.removeSource(sourceId: source.sourceId)
        XCTAssertEqual(try registry.sources().count, 0)
        XCTAssertEqual(try registry.liveAssetCount(sourceId: source.sourceId), 0)   // 级联清资产
    }
}
