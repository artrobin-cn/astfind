import XCTest
@testable import AstfindKit

/// R1a：扫描就绪 → 内容提取全自动（无需手动 extractContent）。
final class AutoExtractTests: XCTestCase {
    func testScanReadyTriggersContentExtractionAutomatically() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("astfind-autoextract-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let share = home.appendingPathComponent("share")
        try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
        try "自动提取验证 发票存根编号77".write(to: share.appendingPathComponent("自动.txt"),
                                                 atomically: true, encoding: .utf8)

        let engine = try AstfindEngine(home: home.appendingPathComponent("data"))
        _ = try engine.register(path: share.path, name: "自动源")
        // 不调用 extractContent——等待钩子自动完成提取
        let deadline = Date().addingTimeInterval(30)
        var hits = 0
        while Date() < deadline {
            hits = engine.contentSearch("发票存根").count
            if hits > 0 { break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertEqual(hits, 1, "扫描就绪后内容观察自动入库可搜")
        engine.stop()
    }
}
