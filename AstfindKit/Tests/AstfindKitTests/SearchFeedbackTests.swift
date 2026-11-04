import XCTest
@testable import AstfindPanel

/// A0-a-2 本地搜索反馈日志：字段完整、JSONL 可解析、超限轮转、空查询拒写。
final class SearchFeedbackTests: XCTestCase {
    private func tempLog() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("astfind-feedback-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("search-feedback.jsonl")
    }

    private func entries(at url: URL) throws -> [[String: Any]] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    func testOpenEntryIsJSONLineWithFields() throws {
        let url = tempLog()
        let log = SearchFeedback(fileURL: url, now: { Date(timeIntervalSince1970: 1_790_000_000) })
        log.logOpen(query: "蓝鲸发布会", path: "/Volumes/SSD/演示/蓝鲸发布会_主会场.png",
                    rank: 2, channel: "semantic", count: 17, kind: 4)

        let rows = try entries(at: url)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["event"] as? String, "open")
        XCTAssertEqual(rows[0]["query"] as? String, "蓝鲸发布会")
        XCTAssertEqual(rows[0]["path"] as? String, "/Volumes/SSD/演示/蓝鲸发布会_主会场.png")
        XCTAssertEqual(rows[0]["rank"] as? Int, 2)
        XCTAssertEqual(rows[0]["channel"] as? String, "semantic")
        XCTAssertEqual(rows[0]["count"] as? Int, 17)
        XCTAssertEqual(rows[0]["kind"] as? Int, 4)
        XCTAssertEqual(rows[0]["t"] as? String, "2026-09-21T14:13:20Z")
    }

    func testZeroEntryOmitsResultFields() throws {
        let url = tempLog()
        let log = SearchFeedback(fileURL: url)
        log.logZero(query: "不存在的素材", kind: nil)
        let rows = try entries(at: url)
        XCTAssertEqual(rows[0]["event"] as? String, "zero")
        XCTAssertEqual(rows[0]["count"] as? Int, 0)
        XCTAssertNil(rows[0]["path"])
        XCTAssertNil(rows[0]["kind"])
    }

    func testEmptyQueryIsNotRecorded() throws {
        let url = tempLog()
        let log = SearchFeedback(fileURL: url)
        log.logOpen(query: "   ", path: "/tmp/a.png", rank: 1, channel: "name", count: 1, kind: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRotationKeepsOneBackup() throws {
        let url = tempLog()
        let log = SearchFeedback(fileURL: url, limit: 256)
        for index in 0..<10 {
            log.logOpen(query: "查询\(index)", path: "/tmp/文件\(index).png", rank: 1,
                        channel: "name", count: 3, kind: nil)
        }
        let backup = url.appendingPathExtension("1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path), "超限后应滚出 .1 备份")
        let current = try entries(at: url)
        XCTAssertFalse(current.isEmpty, "轮转后当前文件应继续可读")
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        XCTAssertLessThan(size?.intValue ?? .max, 512, "轮转后当前文件应小于 2×limit 量级")
    }

    func testFilePermissionsAreOwnerOnly() throws {
        let url = tempLog()
        SearchFeedback(fileURL: url).logZero(query: "权限检查", kind: nil)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
