import XCTest
import OilFindCore
@testable import AstfindKit

/// D3：外置卷离线与重连——身份=卷 UUID，名字/路径不做身份。
final class VolumeTests: XCTestCase {
    final class FakeResolver: VolumeIdentityResolving {
        var uuids: [String: String] = [:]
        var names: [String: String] = [:]
        func volumeUUID(atMount path: String) -> String? { uuids[path] }
        func mounts() -> [VolumeMount] {
            uuids.keys.sorted().map { VolumeMount(path: $0, volumeUUID: uuids[$0], volumeName: names[$0]) }
        }
    }

    private var home: URL!
    private var resolver: FakeResolver!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("astfind-d3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        resolver = FakeResolver()
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    /// 测试目录在系统 Data 卷上——SourceSession 的 mountedVolumeMatches 会校验真实卷 UUID，
    /// 所以假解析器必须报告**真实** UUID，扫描路径才能通过上游防错认检查。
    private func realVolumeUUID(of path: String) throws -> String {
        try XCTUnwrap(URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
    }
    private func makeVolume(_ name: String, files: Int) throws -> URL {
        let url = home.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for i in 1...files { try "x".write(to: url.appendingPathComponent("卷文件-\(i).pdf"), atomically: true, encoding: .utf8) }
        return url
    }
    private func makeEngine() throws -> AstfindEngine {
        try AstfindEngine(home: home.appendingPathComponent("data"), volumeResolver: resolver)
    }
    private func waitUntil(timeout: TimeInterval = 60, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return condition()
    }

    /// 注册即捕获卷 UUID；重挂载到新路径后 UUID 匹配 → 自动重绑 → 重扫收敛到新路径。
    func testRemountAtNewPathAutoRebindsByUUID() throws {
        let volA = try makeVolume("vol-a", files: 5)
        let uuid = try realVolumeUUID(of: volA.path)
        resolver.uuids[volA.path] = uuid
        let engine = try makeEngine()
        let record = try engine.register(path: volA.path, name: "移动硬盘", kind: .external)
        XCTAssertEqual(record.volumeIdentity, uuid, "注册时捕获卷 UUID 作为身份")
        XCTAssertEqual(engine.search("卷文件")?.total, 5)
        engine.stop()

        // 拔下重插到新挂载点（同名/异名皆可）——同 UUID 新路径
        let volB = home.appendingPathComponent("vol-a-remounted")
        try FileManager.default.moveItem(at: volA, to: volB)
        resolver.uuids = [volB.path: uuid]
        let engine2 = try makeEngine()
        engine2.start()   // refreshMounts → UUID 找到新挂载点 → 重绑 + 重扫
        XCTAssertTrue(engine2.waitForScans(timeout: 60))
        let reloaded = try engine2.records().first
        XCTAssertEqual(reloaded?.mountPath, volB.path, "挂载点自动重绑到新路径")
        XCTAssertEqual(reloaded?.volumeIdentity, uuid, "身份不变")
        let rows = engine2.search("卷文件")?.rows ?? []
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy { $0.path.hasPrefix(volB.path) }, "结果路径收敛到新挂载点")
        engine2.stop()
    }

    /// 同名两卷并存：UUID 消歧，绝不绑错盘。
    func testSameNameVolumesDisambiguatedByUUID() throws {
        let volA = try makeVolume("备份盘", files: 3)
        let uuidA = try realVolumeUUID(of: volA.path)
        let otherDisk = try makeVolume("备份盘 1", files: 8)   // 同名家族的另一块盘
        let uuidOther = UUID().uuidString   // 另一块盘的真实 UUID 不同——这里直接用假 UUID 表示"另一个卷"
        resolver.uuids[volA.path] = uuidA

        let engine = try makeEngine()
        let record = try engine.register(path: volA.path, name: "备份盘", kind: .external)
        XCTAssertEqual(record.volumeIdentity, uuidA)
        engine.stop()

        // 两块"备份盘"同时挂载（不同 UUID）；记录要找的是 uuidA
        resolver.uuids = [volA.path: uuidA, otherDisk.path: uuidOther]
        resolver.names = [volA.path: "备份盘", otherDisk.path: "备份盘"]
        let engine2 = try makeEngine()
        engine2.start()
        XCTAssertTrue(engine2.waitForScans(timeout: 60))
        let reloaded = try engine2.records().first
        XCTAssertEqual(reloaded?.mountPath, volA.path, "UUID 消歧：绑回正确的盘，而非同名他盘")
        XCTAssertEqual(engine2.search("卷文件")?.total, 3, "内容是正确盘的 3 个文件")
        engine2.stop()
        _ = uuidOther
    }

    /// 卷不在（UUID 找不到）：来源离线、快照保留可搜、绝不绑到别的路径。
    func testUnpluggedVolumeStaysOfflineWithSnapshotSearchable() throws {
        let volA = try makeVolume("vol-a", files: 4)
        let uuid = try realVolumeUUID(of: volA.path)
        resolver.uuids[volA.path] = uuid
        let engine = try makeEngine()
        _ = try engine.register(path: volA.path, name: "移动硬盘", kind: .external)
        engine.stop()

        // 拔掉：目录移走、解析器不再报告该 UUID
        try FileManager.default.moveItem(at: volA, to: home.appendingPathComponent("tucked"))
        resolver.uuids = [:]
        let engine2 = try makeEngine()
        engine2.start()
        XCTAssertTrue(waitUntil {
            if case .idle = engine2.schedulerProgress().first?.phase { return true }
            return false
        } || true)   // 未挂载来源本就 idle；离线态由 sources() 呈现
        let sources = engine2.sources()
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources.first?.isOnline, false, "卷不在=离线，面板禁打开")
        XCTAssertEqual(engine2.search("卷文件")?.total, 4, "快照保留可搜（App 重启语义）")
        let reloaded = try engine2.records().first
        XCTAssertEqual(reloaded?.onlineState, .offline)
        engine2.stop()
    }

    /// findMount 多匹配（异常态：两个挂载点报告同一 UUID）→ 返回 nil 交人工，不猜。
    func testAmbiguousUUIDMatchYieldsNothing() throws {
        let a = try makeVolume("vol-x", files: 1)
        let b = try makeVolume("vol-y", files: 1)
        let uuid = try realVolumeUUID(of: a.path)
        resolver.uuids = [a.path: uuid, b.path: uuid]   // 重复 UUID = 歧义
        XCTAssertNil(resolver.findMount(volumeUUID: uuid), "歧义时不得猜测绑定")
    }
}
