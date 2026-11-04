import XCTest
import OilFindCore
@testable import AstfindPanel

/// C 场景验收（fork 差异）：上游 ExternalDriveCatalog 只给在线盘发搜索源，拔盘即整源消失；
/// Astfind 要求已建索引的外置盘拔出后仍可检索（isOnline=false，面板标「离线」并禁止打开）。
/// 用真实 IndexManager 建索引，再以 discover 返回空模拟拔盘，端到端断言离线命中。
final class ExternalDriveCatalogOfflineTests: XCTestCase {
    private var directory: URL!
    private var root: URL!
    private var uuid: String!
    private var externalDir: URL!

    private final class FakeDriveMonitor: ExternalDriveMonitoring {
        var onChange: (() -> Void)?
        var beforeEject: ((String) -> Void)?
        var beforeUnmount: ((String) -> Void)?
        func start() {}
        func stop() {}
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("astfind-catalog-offline-\(UUID().uuidString)")
        root = directory.appendingPathComponent("ExternalSSD")
        externalDir = directory.appendingPathComponent("external-drives")
        // IndexManager.saveSnapshot 不创建父目录；真实 App 里 persistence.save() 会先建目录
        try FileManager.default.createDirectory(at: externalDir, withIntermediateDirectories: true)
        uuid = UUID().uuidString.uppercased()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("视频"),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0xEF, count: 64).write(to: root.appendingPathComponent("视频/舞台演示.mp4"))
        try "hello\n".write(to: root.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 模拟「曾插盘完成索引 → 拔盘 → App 重启」：catalog 启动时卷不在，离线源仍要可搜。
    func testUnpluggedDriveWithSnapshotRemainsSearchable() throws {
        try buildIndexWhileMounted()
        let catalog = makeCatalog(mounted: false)
        catalog.start()

        let source = try waitUntil("离线源出现") {
            catalog.searchSources().first { $0.id == self.uuid && !$0.isOnline && $0.store != nil }
        }
        let result = try XCTUnwrap(MultiSearcher.search(Query.parse("舞台演示"), in: [source]))
        XCTAssertGreaterThanOrEqual(result.total, 1)
        XCTAssertEqual(result.sources[result.items[0].sourceIndex].isOnline, false)
        let path = result.sources[result.items[0].sourceIndex].store.path(result.items[0].entryID)
        XCTAssertTrue(path.hasPrefix(root.path))

        // 关闭该盘索引 = 用户显式放弃快照，离线源必须随之消失
        catalog.setDriveEnabled(uuid, false)
        XCTAssertTrue(catalog.searchSources().isEmpty)
        catalog.stop()
    }

    /// 模拟运行中插拔转换：在线可搜 → 拔盘仍可搜（离线）→ 重插回在线。
    func testPlugUnplugTransitionsKeepSourceSearchable() throws {
        try buildIndexWhileMounted()
        let box = MountedBox()
        box.mounted = true
        let catalog = makeCatalog(mounted: nil, box: box)
        catalog.start()

        _ = try waitUntil("在线源就绪") { catalog.searchSources().first { $0.id == self.uuid && $0.isOnline } }
        box.mounted = false
        catalog.discoverVolumes()
        let offline = try waitUntil("拔盘后离线源仍在") {
            catalog.searchSources().first { $0.id == self.uuid && !$0.isOnline }
        }
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(MultiSearcher.search(Query.parse("舞台演示"), in: [offline])).total, 1)

        box.mounted = true
        catalog.discoverVolumes()
        _ = try waitUntil("重插回在线") { catalog.searchSources().first { $0.id == self.uuid && $0.isOnline } }
        catalog.stop()
    }

    /// 没建过索引的盘拔着插着都不可搜（不凭空造源）。
    func testNeverIndexedDriveYieldsNoSource() throws {
        let catalog = makeCatalog(mounted: false)
        catalog.start()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))
        XCTAssertTrue(catalog.searchSources().isEmpty)
        catalog.stop()
    }

    // MARK: - Helpers

    /// 测试根目录在系统卷上，无法拥有任选的卷 UUID，而上游 start() 的 mountedVolumeMatches
    /// 守卫会因 UUID 不匹配直接拒绝扫描。该守卫属上游卷身份逻辑（已在外置盘上验证有效），
    /// 这里注入 volumeUUID:nil 跳过它，扫描/落盘/离线加载/检索全部走真实链路。
    /// 预置索引走 catalog 自己的在线会话（插盘扫描 → stop() 落盘），与生产路径完全一致；
    /// 裸建 IndexManager 会在测试宿主里遭遇上游 settings 驱动的状态振荡，不适合做预置。
    private func buildIndexWhileMounted() throws {
        let catalog = makeCatalog(mounted: true)
        catalog.start()
        _ = try waitUntil("在线索引会话就绪") {
            catalog.searchSources().first { $0.id == self.uuid && $0.isOnline && $0.store != nil }
        }
        catalog.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalDir.appendingPathComponent("\(uuid!).oilfind").path))
    }

    private func makeCatalog(mounted: Bool?, box: MountedBox? = nil) -> ExternalDriveCatalog {
        let record = ExternalDriveRecord(id: uuid!, name: "ExternalSSD", path: root.path, lastConnected: Date())
        let discover: () -> [ExternalVolume]
        if let box {
            discover = { box.mounted ? [ExternalVolume(uuid: self.uuid!, name: "ExternalSSD", path: self.root.path)] : [] }
        } else {
            let mounted = mounted ?? false
            discover = { mounted ? [ExternalVolume(uuid: self.uuid!, name: "ExternalSSD", path: self.root.path)] : [] }
        }
        return ExternalDriveCatalog(directory: externalDir!,
                                     monitor: FakeDriveMonitor(),
                                     initialPreferences: ExternalDrivePreferences(drives: [record]),
                                     discover: discover,
                                     makeIndex: { config, url, _ in
                                         IndexManager(config: config, dbURL: url, volumeUUID: nil)
                                     })
    }

    private final class MountedBox {
        var mounted = false
    }

    /// catalog 与 IndexManager 的回调都落主队列，用 RunLoop 自旋等待而不是阻塞睡眠。
    /// 超时即修复失效，必须记为失败（XCTSkip 会把失效伪装成跳过）。
    private func waitUntil<T>(_ label: String, timeout: TimeInterval = 20, _ condition: () -> T?) throws -> T {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if let value = condition() { return value }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        XCTFail("超时：\(label) —— 离线检索修复未生效")
        throw NSError(domain: "astfind.wait", code: 1, userInfo: [NSLocalizedDescriptionKey: label])
    }
}
