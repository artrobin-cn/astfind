import XCTest
import OilFindCore
@testable import AstfindKit

/// R1/L2：SMB 共享身份绑定与自动重绑——身份 = smb://host/share，挂载点只是运行态。
/// 背景（实弹取证 2026-10-20）：SMB 挂载点 volumeUUIDString=nil、名字会漂移
/// （teamshare-1 → teamshare），按路径绑定恒离线。
final class SMBIdentityTests: XCTestCase {
    final class FakeSMBResolver: SMBShareResolving {
        var mounts: [SMBShareMount] = []
        func smbShareMounts() -> [SMBShareMount] { mounts }
    }
    final class EmptyVolumeResolver: VolumeIdentityResolving {
        func volumeUUID(atMount path: String) -> String? { nil }
        func mounts() -> [VolumeMount] { [] }
    }

    private var home: URL!
    private var resolver: FakeSMBResolver!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("astfind-r1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        resolver = FakeSMBResolver()
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    /// 建一个"共享"：teamshare/Shared/NAS文件-i.txt（模拟 NAS 目录结构）。
    private func makeShare(_ mountName: String, files: Int = 5) throws -> URL {
        let sourceRoot = home.appendingPathComponent(mountName).appendingPathComponent("Shared")
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        for i in 1...files {
            try "nas \(i)".write(to: sourceRoot.appendingPathComponent("NAS文件-\(i).txt"),
                                 atomically: true, encoding: .utf8)
        }
        return sourceRoot
    }
    private func makeEngine() throws -> AstfindEngine {
        let engine = try AstfindEngine(home: home.appendingPathComponent("data"),
                                       volumeResolver: EmptyVolumeResolver(), smbResolver: resolver)
        // 测试里的 nas.local 是模拟共享（真实主机不存在）；SMB 存活探测注入为真，
        // 避免单测去连真实 445。专门的失联用例会自行覆盖为 false。
        engine.smbServerProbe = { _ in true }
        return engine
    }

    // MARK: 解析器与身份工具（纯函数）

    /// 典型 mount 输出→ 共享身份；非 smbfs 行忽略；剥 DOMAIN;user 凭据。
    func testParsesMountOutput() {
        let output = """
        /dev/disk3s1 on /Volumes/ExternalSSD (apfs, local, journaled, noowners)
        //user@nas.local._smb._tcp.local/teamshare on /Volumes/teamshare (smbfs, nodev, nosuid, quarantine, mounted by user)
        //WORKGROUP;user@192.168.1.8/media on /Volumes/media-1 (smbfs, nodev, nosuid)
        map auto_home on /System/Volumes/Data/home (autofs, automounted)
        """
        XCTAssertEqual(DefaultSMBShareResolver.parse(output), [
            SMBShareMount(shareURL: "smb://nas.local._smb._tcp.local/teamshare", mountPath: "/Volumes/teamshare"),
            SMBShareMount(shareURL: "smb://192.168.1.8/media", mountPath: "/Volumes/media-1"),
        ])
    }

    func testIdentityHelpers() {
        XCTAssertEqual(SMBShareIdentity.shareURL(fromMountSource: "//user:pw@nas.local/share/"), "smb://nas.local/share")
        XCTAssertEqual(SMBShareIdentity.shareURL(fromMountSource: "//nas.local/share"), "smb://nas.local/share")
        XCTAssertNil(SMBShareIdentity.shareURL(fromMountSource: "/dev/disk1s1"), "非 SMB 源串")

        let parts = SMBShareIdentity.parts(ofIdentity: "smb://nas.local/teamshare/Shared/2026")
        XCTAssertEqual(parts?.shareURL, "smb://nas.local/teamshare")
        XCTAssertEqual(parts?.subpath, "Shared/2026")
        XCTAssertEqual(SMBShareIdentity.parts(ofIdentity: "smb://nas.local/teamshare")?.subpath, "")
        XCTAssertEqual(SMBShareIdentity.host(ofIdentity: "smb://nas._smb._tcp.local/teamshare/2026"),
                       "nas._smb._tcp.local")
        XCTAssertNil(SMBShareIdentity.host(ofIdentity: "file:///Volumes/teamshare/Shared"), "非 smb 身份没有主机")
        XCTAssertEqual(SMBServerProbe.candidates(for: "nas._smb._tcp.local"),
                       ["nas.local", "nas._smb._tcp.local"], "Bonjour 服务名 → 优先真实主机名")
        XCTAssertEqual(SMBServerProbe.candidates(for: "nas"), ["nas", "nas.local"])

        XCTAssertNil(SMBShareIdentity.subpath(ofPath: "/Volumes/teamshare-1/x", underMount: "/Volumes/teamshare"),
                     "前缀字符串巧合不算挂载点之下（teamshare-1 ≠ teamshare 子路径）")
        XCTAssertEqual(SMBShareIdentity.subpath(ofPath: "/Volumes/teamshare/Shared", underMount: "/Volumes/teamshare"), "Shared")

        XCTAssertTrue(SMBShareIdentity.matches(shareURL: "smb://NAS.local/Share", locatorShareURL: "smb://nas.local/share"))
    }

    // MARK: 行为级（注入假挂载表，物理目录模拟挂载点漂移）

    /// PRD R1 验收主链路：注册即身份绑定 → 挂载点改名漂移 → refreshMounts 按身份自动重绑在线。
    /// 注册时按 App 添加页的方式报 kind=.external（/Volumes 下一律 external）——引擎按挂载表
    /// 物理事实重分类为 smb（真实 NAS 源即此形态，2026-10-20 实录）。
    func testMountPointDriftAutoRebindsByIdentity() throws {
        let sourceRoot = try makeShare("teamshare-1")
        let shareURL = "smb://nas.local/teamshare"
        resolver.mounts = [SMBShareMount(shareURL: shareURL, mountPath: home.appendingPathComponent("teamshare-1").path)]
        let engine = try makeEngine()
        let record = try engine.register(path: sourceRoot.path, name: "Shared", kind: .external)
        XCTAssertEqual(record.kind, .smb, "位于 SMB 挂载下的来源重分类为 smb（物理事实优先）")
        XCTAssertEqual(record.locator, "smb://nas.local/teamshare/Shared", "注册即存共享身份，不存挂载路径")
        XCTAssertEqual(engine.search("NAS文件")?.total, 5)

        // NAS 重挂：挂载点漂移到无碰撞基础名（整棵目录挪走模拟卸载重挂）
        let newMount = home.appendingPathComponent("teamshare")
        try FileManager.default.moveItem(at: home.appendingPathComponent("teamshare-1"), to: newMount)
        resolver.mounts = [SMBShareMount(shareURL: shareURL, mountPath: newMount.path)]
        engine.refreshMounts()   // 挂载事件驱动（App 内 NSWorkspace didMount）
        XCTAssertTrue(engine.waitForScans(timeout: 60), "重绑后重扫收敛")

        let rebound = try XCTUnwrap(engine.records().first)
        XCTAssertEqual(rebound.locator, shareURL + "/Shared", "身份不变")
        XCTAssertEqual(rebound.mountPath, newMount.appendingPathComponent("Shared").path, "挂载点自动重绑到漂移后的新路径")
        XCTAssertEqual(rebound.onlineState, .online)
        let rows = engine.search("NAS文件")?.rows ?? []
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy { $0.path.hasPrefix(newMount.path) }, "结果路径收敛到新挂载点")
        engine.stop()
    }

    /// 存量路径型 locator（注册时挂载表不可得）→ 可达后自动升级为 smb:// 身份，幂等且不产生重复源。
    func testLegacyPathLocatorMigratesToIdentityIdempotently() throws {
        let sourceRoot = try makeShare("teamshare")
        resolver.mounts = []   // 注册时挂载表不可得（未挂载/刚装）：回退路径型
        let engine = try makeEngine()
        let record = try engine.register(path: sourceRoot.path, name: "Shared", kind: .smb)
        XCTAssertEqual(record.locator, "file://" + sourceRoot.path, "反查不到共享时回退路径型")

        // NAS 挂载出现 → refreshMounts 迁移升级
        resolver.mounts = [SMBShareMount(shareURL: "smb://nas.local/teamshare",
                                         mountPath: home.appendingPathComponent("teamshare").path)]
        engine.refreshMounts()
        engine.refreshMounts()   // 幂等：重复刷新不反复迁移、不产生重复
        let migrated = try XCTUnwrap(engine.records().first)
        XCTAssertEqual(migrated.locator, "smb://nas.local/teamshare/Shared")
        XCTAssertEqual(engine.records().count, 1, "迁移是 UPDATE，绝无重复源")
        XCTAssertTrue(engine.waitForScans(timeout: 60))
        XCTAssertEqual(engine.search("NAS文件")?.total, 5)
        engine.stop()

        // 迁移后再拔线：身份语义下走身份通道（而非路径兜底）
        try FileManager.default.moveItem(at: home.appendingPathComponent("teamshare"),
                                         to: home.appendingPathComponent("tucked"))
        resolver.mounts = []
        let engine2 = try makeEngine()
        engine2.start()
        XCTAssertEqual(engine2.records().first?.onlineState, .offline, "共享不在 = 离线")
        XCTAssertNil(engine2.records().first?.mountPath, "挂载点是运行态，离线即清")
        XCTAssertEqual(engine2.search("NAS文件")?.total, 5, "快照保留可搜（App 重启语义）")
        XCTAssertEqual(engine2.sources().first?.isOnline, false)
        engine2.stop()
    }

    /// 真实存量形态还原（2026-10-20 实录）：kind=external + 旧路径 locator + 手工重绑过的
    /// mount_path —— refreshMounts 一次性升级 kind=smb + smb:// 身份（无卷 UUID 的 SMB 挂载）。
    /// 带真实卷 UUID 的外置盘（ExternalSSD）不受影响。
    func testExistingExternalRecordOnSMBMountUpgrades() throws {
        let sourceRoot = try makeShare("teamshare")
        let oldPath = home.appendingPathComponent("teamshare-1").appendingPathComponent("Shared")
        // 直接落库复刻真实 registry：locator=旧挂载路径、mount_path=手工重绑后的新路径
        let registry = try SourceRegistry(databaseURL: home.appendingPathComponent("data").appendingPathComponent("registry.sqlite"))
        _ = try registry.registerSource(kind: .external, locator: oldPath.path, displayName: "Shared")
        let raw = try XCTUnwrap(registry.sources().first)
        try registry.updateMount(sourceId: raw.sourceId, mountPath: sourceRoot.path, online: true)
        _ = registry   // 持有到 end

        resolver.mounts = [SMBShareMount(shareURL: "smb://nas.local/teamshare",
                                         mountPath: home.appendingPathComponent("teamshare").path)]
        let engine = try makeEngine()
        engine.start()
        let upgraded = try XCTUnwrap(engine.records().first)
        XCTAssertEqual(upgraded.kind, .smb, "SMB 挂载下的无 UUID 来源升级为 smb")
        XCTAssertEqual(upgraded.locator, "smb://nas.local/teamshare/Shared")
        XCTAssertEqual(engine.records().count, 1)
        XCTAssertTrue(engine.waitForScans(timeout: 60))
        XCTAssertEqual(engine.search("NAS文件")?.total, 5, "升级后在线可搜")
        engine.stop()
    }

    /// 同共享双挂载（歧义）：取排序第一个并继续工作，不猜其余。
    func testAmbiguousDoubleMountTakesFirstSorted() throws {
        let sourceRoot = try makeShare("teamshare")
        let shell = home.appendingPathComponent("teamshare-2").appendingPathComponent("Shared")
        try FileManager.default.createDirectory(at: shell, withIntermediateDirectories: true)   // 空壳同构目录
        let shareURL = "smb://nas.local/teamshare"
        resolver.mounts = [
            SMBShareMount(shareURL: shareURL, mountPath: home.appendingPathComponent("teamshare-2").path),
            SMBShareMount(shareURL: shareURL, mountPath: home.appendingPathComponent("teamshare").path),
        ]
        let engine = try makeEngine()
        _ = try engine.register(path: sourceRoot.path, name: "Shared", kind: .smb)
        engine.refreshMounts()
        XCTAssertTrue(engine.waitForScans(timeout: 60))
        let bound = try XCTUnwrap(engine.records().first)
        XCTAssertEqual(bound.mountPath, sourceRoot.path, "歧义取排序第一个（teamshare < teamshare-2），数据仍可搜")
        XCTAssertEqual(engine.search("NAS文件")?.total, 5)
        engine.stop()
    }

    /// 身份挂载存在但子路径消失（共享重整目录）：离线保快照，不绑到共享根。
    func testShareMountedButSubpathMissingStaysOffline() throws {
        let sourceRoot = try makeShare("teamshare")
        let shareURL = "smb://nas.local/teamshare"
        resolver.mounts = [SMBShareMount(shareURL: shareURL, mountPath: home.appendingPathComponent("teamshare").path)]
        let engine = try makeEngine()
        _ = try engine.register(path: sourceRoot.path, name: "Shared", kind: .smb)
        engine.stop()

        // 共享挂载还在，但 Shared 子目录被挪走（模拟 NAS 端目录重组）
        try FileManager.default.moveItem(at: sourceRoot, to: home.appendingPathComponent("tucked"))
        let engine2 = try makeEngine()
        engine2.start()
        XCTAssertEqual(engine2.records().first?.onlineState, .offline, "子路径不可达 = 离线，绝不绑到共享根猜内容")
        XCTAssertEqual(engine2.search("NAS文件")?.total, 5, "快照保留可搜")
        engine2.stop()
    }

    /// NAS 掉线但 smbfs 挂载点仍残留（macOS 常见）：必须判离线并保留 mountPath，
    /// 不能只凭 fileExists 在线——否则打开结果会卡在内核 SMB 重传里。
    func testSMBServerDownMarksOfflineEvenWhenMountPointRemains() throws {
        let sourceRoot = try makeShare("teamshare")
        let shareURL = "smb://nas.local/teamshare"
        resolver.mounts = [SMBShareMount(shareURL: shareURL, mountPath: home.appendingPathComponent("teamshare").path)]
        let engine = try makeEngine()
        _ = try engine.register(path: sourceRoot.path, name: "Shared", kind: .smb)
        engine.stop()

        let engine2 = try makeEngine()
        engine2.smbServerProbe = { _ in false }
        engine2.start()
        let record = try XCTUnwrap(engine2.records().first)
        XCTAssertEqual(record.onlineState, .offline, "服务端失联 = 离线")
        XCTAssertEqual(record.mountPath, sourceRoot.path, "保留挂载点，服务端恢复后可继续用")
        XCTAssertEqual(engine2.sources().first?.isOnline, false)
        XCTAssertFalse(engine2.isSourceReachable(sourceId: record.sourceId))
        XCTAssertEqual(engine2.search("NAS文件")?.total, 5, "离线仍可搜快照")
        engine2.stop()
    }
}
