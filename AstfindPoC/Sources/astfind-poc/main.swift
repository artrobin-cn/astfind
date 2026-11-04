// Astfind D0 PoC — 零侵入验证 oil-find 公开 API 能否承接自定义来源的
// 在线扫描、本地快照持久化、离线加载与查询。
//
// 依赖的全部为 oil-find public API（外部包可见）：
//   IndexConfig / IndexManager / IndexStore.load / buildHash /
//   SearchSource / MultiSearcher / Query
//
// 阶段：
//   PHASE 1  在线：对 100 文件测试目录扫描建索引，MultiSearcher 查询命中
//   PHASE 2  离线：目录“拔掉”（改名），新进程内 startOffline() 加载快照仍可查询，
//            并验证查询路径不触碰源目录（源目录已不存在）
//   PHASE 3  恢复：目录放回原路径，查询结果与路径解析恢复正常
//   PHASE 4  直连：绕过 IndexManager，直接 IndexStore.load + SearchSource 搜索，
//            证明未来 SMB 扫描器可以完全自管快照文件

import Foundation
import OilFindCore

var failures = 0
func check(_ condition: Bool, _ label: String, _ detail: String = "") {
    if condition {
        print("  [PASS] \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    } else {
        failures += 1
        print("  [FAIL] \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

let fm = FileManager.default
let root = NSTemporaryDirectory() + "astfind-poc-source"
let hidden = NSTemporaryDirectory() + "astfind-poc-gone"
let dbURL = URL(fileURLWithPath: NSTemporaryDirectory() + "astfind-poc-index.oilfind")

// MARK: - 测试数据：100 个文件 + 嵌套目录 + 中文名
func makeDataset() throws -> Int {
    if fm.fileExists(atPath: hidden) { try fm.removeItem(atPath: hidden) }
    if fm.fileExists(atPath: root) { try fm.removeItem(atPath: root) }
    try? fm.removeItem(atPath: dbURL.path)
    var count = 0
    for dir in ["docs", "docs/2026", "照片", "照片/毕业典礼", "notes/deep/deeper"] {
        try fm.createDirectory(atPath: root + "/" + dir, withIntermediateDirectories: true)
    }
    for i in 1...90 {
        let dir = ["docs", "docs/2026", "notes/deep/deeper"][i % 3]
        try "astfind sample \(i)\n".write(toFile: root + "/" + dir + "/file-\(i).txt", atomically: true, encoding: .utf8)
        count += 1
    }
    for i in 1...8 {
        try "img".write(toFile: root + "/照片/毕业典礼/合影-\(i).jpg", atomically: true, encoding: .utf8)
        count += 1
    }
    try "marker".write(toFile: root + "/docs/README-poc.md", atomically: true, encoding: .utf8)
    try "中文内容".write(toFile: root + "/照片/课程设计-v2.pdf", atomically: true, encoding: .utf8)
    count += 2
    return count
}

func waitFor(_ manager: IndexManager, _ target: IndexManager.State, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if manager.state == target { Thread.sleep(forTimeInterval: 0.05); return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return manager.state == target
}

func runQuery(_ source: SearchSource, _ raw: String) -> (MultiSearchResult, [String]) {
    let result = MultiSearcher.search(Query.parse(raw), in: [source])!
    let paths = result.items.prefix(10).map { hit in
        result.sources[hit.sourceIndex].store.path(hit.entryID)
    }
    return (result, paths)
}

let t0 = Date()
let expectedFiles = try makeDataset()
print("== Astfind D0 PoC ==")
print("dataset: \(expectedFiles) files at \(root)")
print("snapshot: \(dbURL.path)")

// MARK: - PHASE 1 在线扫描 + 查询
print("\n[PHASE 1] online scan + query")
let scanBegin = Date()
let online = IndexManager(
    config: IndexConfig(rootPath: root),
    dbURL: dbURL,
    volumeUUID: nil,
    settingsDefaults: nil   // 隔离宿主 UserDefaults，保证指纹可复现
)
online.start()
check(waitFor(online, .ready, timeout: 60), "IndexManager.start() reaches .ready", "state=\(online.state)")
let scanSeconds = Date().timeIntervalSince(scanBegin)
let store = online.store
check(store != nil, "store published after scan")
let liveCount = store.map { s -> Int in s.read { s.liveCount } } ?? 0
check(liveCount >= expectedFiles, "indexed entries >= files", "liveCount=\(liveCount) files=\(expectedFiles)")
online.saveNow()
let source1 = store.map { SearchSource(id: "poc-src", displayName: "PoC Source", isOnline: true, store: $0) }!
let (r1, p1) = runQuery(source1, "README-poc")
check(r1.total >= 1, "query 'README-poc' hits", "total=\(r1.total) elapsedMs=\(String(format: "%.2f", r1.elapsedMs))")
check(p1.contains { $0.hasSuffix("docs/README-poc.md") }, "resolved path points into source root", p1.first ?? "")
let (r1zh, _) = runQuery(source1, "毕业")
check(r1zh.total >= 1, "chinese filename query hits", "total=\(r1zh.total)")
print(String(format: "  scan=%.3fs entries=%d snapshot=%d bytes", scanSeconds, liveCount, (try? fm.attributesOfItem(atPath: dbURL.path)[.size] as? Int) ?? 0))

// MARK: - PHASE 2 离线：源目录消失，仅凭本地快照查询
print("\n[PHASE 2] offline: source dir removed, snapshot-only query")
online.stop()
try fm.moveItem(atPath: root, toPath: hidden)
check(!fm.fileExists(atPath: root), "source dir unmounted (renamed away)")

let offline = IndexManager(
    config: IndexConfig(rootPath: root),
    dbURL: dbURL,
    volumeUUID: nil,
    settingsDefaults: nil
)
let loadBegin = Date()
offline.startOffline()
check(waitFor(offline, .ready, timeout: 15), "IndexManager.startOffline() reaches .ready", "state=\(offline.state)")
print(String(format: "  offline load=%.3fs", Date().timeIntervalSince(loadBegin)))
let store2 = offline.store
check(store2 != nil, "offline store loaded from snapshot")
let offlineCount = store2.map { s -> Int in s.read { s.liveCount } } ?? 0
check(offlineCount >= expectedFiles, "offline entries preserved", "liveCount=\(offlineCount)")
let source2 = store2.map { SearchSource(id: "poc-src", displayName: "PoC Source", isOnline: false, store: $0) }!
let (r2, p2) = runQuery(source2, "README-poc")
check(r2.total >= 1, "offline query still hits", "total=\(r2.total) elapsedMs=\(String(format: "%.2f", r2.elapsedMs))")
check(p2.first?.hasPrefix(root) == true, "offline result keeps original root path (for rebind check)", p2.first ?? "")

var latencies: [Double] = []
for _ in 0..<20 { latencies.append(runQuery(source2, "file-4").0.elapsedMs) }
latencies.sort()
print(String(format: "  offline query latency over 20 runs: p50=%.3fms p95=%.3fms", latencies[latencies.count / 2], latencies[min(latencies.count - 1, Int(ceil(Double(latencies.count) * 0.95)) - 1)]))
offline.stop()

// MARK: - PHASE 3 恢复：源目录回到原路径
print("\n[PHASE 3] restore: source dir back at original path")
try fm.moveItem(atPath: hidden, toPath: root)
check(fm.fileExists(atPath: root + "/docs/README-poc.md"), "source dir restored")
let (r3, p3) = runQuery(source2, "README-poc")
check(r3.total >= 1 && p3.first.map { fm.fileExists(atPath: $0) } == true, "restored path resolves to real file", p3.first ?? "")

// MARK: - PHASE 4 直连快照（未来 SMB 扫描器自管快照的形态）
print("\n[PHASE 4] direct IndexStore.load without IndexManager")
let directBegin = Date()
guard let direct = IndexStore.load(from: dbURL.path) else {
    check(false, "IndexStore.load(from:) public static loads snapshot")
    exit(1)
}
direct.write { direct.buildHash() }
print(String(format: "  direct load=%.3fs entries=%d", Date().timeIntervalSince(directBegin), direct.count))
let source4 = SearchSource(id: "poc-smb", displayName: "Simulated SMB", isOnline: true, store: direct)
let (r4, p4) = runQuery(source4, "合影")
check(r4.total >= 8, "direct-store query '合影' hits", "total=\(r4.total)")
check(p4.allSatisfy { $0.hasPrefix(root) }, "direct-store paths under original root", p4.first ?? "")
check(direct.read { direct.containsPath(root + "/照片/毕业典礼/合影-1.jpg") }, "containsPath public lookup works")

// MARK: - 汇总
print("\n== SUMMARY ==")
if failures == 0 {
    print("ALL CHECKS PASSED — Plan A (public SearchSource/IndexStore reuse) is viable at the API level.")
    exit(0)
} else {
    print("\(failures) CHECK(S) FAILED")
    exit(1)
}
