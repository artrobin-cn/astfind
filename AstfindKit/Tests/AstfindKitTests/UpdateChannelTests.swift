import XCTest
import OilFindCore
@testable import AstfindPanel

/// 更新通道门（2026-10-22）：Astfind 自有渠道接线（B1）前，`AstfindUpdateFeedURL`
/// 缺省 → 更新入口隐藏且 `check()`/`install()` 直接返回——绝不回退上游 find.oiloil.org
/// 的 appcast（上游 Oil Find 1.7.1 曾被当成 Astfind 更新推给用户）。
final class UpdateChannelTests: XCTestCase {
    func testUnconfiguredChannelNeverFallsBackToUpstreamFeed() {
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "AstfindUpdateFeedURL"))
        XCTAssertNil(UpdateManager.feedURL)
        XCTAssertFalse(UpdateManager.channelConfigured)
    }

    func testUnconfiguredManagerStaysIdleOnCheck() {
        let manager = UpdateManager(snapshot: true, current: UpdateVersion("0.2.1", build: 1)!)
        manager.check(manual: true)
        XCTAssertEqual(manager.state, .idle)
        XCTAssertNil(manager.manifest)
    }

    /// 官网同样“未配置即隐藏”：绝不回退上游站点，避免把用户引到别的产品的下载页。
    func testUnconfiguredWebsiteNeverFallsBackToUpstream() {
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "AstfindWebsiteURL"))
        XCTAssertNil(UpdateManager.websiteURL)
    }

    /// 安装器身份参数化：Astfind 的候选包用 Astfind 身份可读，用上游身份必须拒绝。
    /// 这条锚定 B1 接线时不会再因 `com.oiloil.find` 写死而永远装不上。
    func testInstallerIdentityIsParameterized() throws {
        XCTAssertEqual(UpdateManager.applicationIdentity, .astfind)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astfind-update-identity-\(UUID().uuidString)", isDirectory: true)
        let candidate = root.appendingPathComponent("Astfind.app", isDirectory: true)
        let contents = candidate.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plist: [String: Any] = [
            "CFBundleIdentifier": "edu.astfind.app",
            "CFBundleShortVersionString": "0.3.0",
            "CFBundleVersion": "12",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        XCTAssertEqual(try SystemUpdateFiles(identity: .astfind).version(of: candidate),
                       UpdateVersion("0.3.0", build: 12))
        XCTAssertThrowsError(try SystemUpdateFiles(identity: .oilFind).version(of: candidate),
                             "包身份不符必须拒绝，而不是把上游身份套到 Astfind 上")
    }
}
