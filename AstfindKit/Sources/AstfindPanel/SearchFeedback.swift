import Foundation

/// 本地搜索反馈日志（A0-a-2 真值来源）。
///
/// 只记两类信号最强的事件：
/// - `open` / `reveal`：用户实际打开或定位了哪个结果 → 查询与相关文件的正样本；
/// - `zero`：停手后仍为 0 结果的查询 → 召回缺口（最值得看的一类）。
///
/// 仅写本机 JSONL（0600；>4MB 轮转，保留 1 份备份），零外发；设置页可关。
/// 中间键入前缀不记——只记用户真正采取行动的查询，保持数据干净。
final class SearchFeedback {
    static let shared = SearchFeedback()
    static let enabledKey = "astfindSearchFeedback"
    /// 未设置时默认开启（本地工具，数据不出机）。
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Astfind/search-feedback.jsonl")
    }

    struct Entry: Codable, Equatable {
        let t: String
        let event: String
        let query: String
        var path: String?
        var rank: Int?
        var channel: String?
        var count: Int?
        var kind: Int?
    }

    private let fileURL: URL
    private let limit: Int
    private let lock = NSLock()
    private let now: () -> Date

    init(fileURL: URL? = nil, limit: Int = 4 << 20, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        self.limit = limit
        self.now = now
    }

    func logOpen(query: String, path: String, rank: Int, channel: String, count: Int, kind: UInt8?) {
        record(Entry(t: timestamp(), event: "open", query: query, path: path, rank: rank,
                     channel: channel, count: count, kind: kind.map(Int.init)))
    }

    func logReveal(query: String, path: String, rank: Int, channel: String, count: Int, kind: UInt8?) {
        record(Entry(t: timestamp(), event: "reveal", query: query, path: path, rank: rank,
                     channel: channel, count: count, kind: kind.map(Int.init)))
    }

    func logZero(query: String, kind: UInt8?) {
        record(Entry(t: timestamp(), event: "zero", query: query, path: nil, rank: nil,
                     channel: nil, count: 0, kind: kind.map(Int.init)))
    }

    /// 逐条追加（人类操作频率，开-写-关足够；避免长驻 FileHandle 在轮转时的竞态）。
    func record(_ entry: Entry) {
        guard !entry.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(entry) else { return }
        data.append(0x0A)
        lock.lock(); defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            rotateIfNeeded()
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil,
                                               attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // 反馈日志是增强能力：任何 IO 失败都不得影响搜索（静默丢弃本条）。
        }
    }

    /// 超限时滚到 `.1`（覆盖旧备份）：保留最近一轮，磁盘上最多约 2×limit。
    private func rotateIfNeeded() {
        guard let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber,
              size.intValue >= limit else { return }
        let backup = fileURL.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: fileURL, to: backup)
    }

    private func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: now())
    }
}
