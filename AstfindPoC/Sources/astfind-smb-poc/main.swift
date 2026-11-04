// Astfind D1 SMB PoC 测试装置
//
// 对任意"来源根目录"（本机目录 / 已挂载 SMB 共享）执行 D1 任务卡要求的实验矩阵。
// 每个模式一次进程调用，天然覆盖"App 重启后仍可查"。
//
// 用法：
//   astfind-smb-poc generate  <root> <count> [--seed N] [--manifest path.tsv]
//   astfind-smb-poc scan      <root> <db> [--kill-after sec]
//   astfind-smb-poc offline   <root> <db> <manifest> [--sample 200] [--runs 50]
//   astfind-smb-poc reconnect <oldRoot> <newRoot> <db> <manifest> [--sample 200]
//   astfind-smb-poc mutate    <root> <manifestOut> --add N --rename M --delete K [--seed N]
//   astfind-smb-poc sync      <root> <db> <manifestAfter> [--sample 200]
//
// 输出：每阶段一行 JSON 指标（便于汇总入报告），校验失败退出码非 0。

import Foundation
import Darwin
import OilFindCore

var failures = 0
func check(_ condition: Bool, _ label: String, _ detail: String = "") {
    if condition { print("  [PASS] \(label)\(detail.isEmpty ? "" : " — \(detail)")") }
    else { failures += 1; print("  [FAIL] \(label)\(detail.isEmpty ? "" : " — \(detail)")") }
}
func metric(_ pairs: [String: Any]) {
    let ordered = pairs.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    print("METRIC \(ordered)")
}
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("ERROR: \(message)\n".utf8))
    exit(2)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let mode = args.first else {
    fail("usage: astfind-smb-poc generate|scan|offline|reconnect|mutate|sync ...")
}
func opt(_ key: String, _ fallback: String) -> String {
    guard let i = args.firstIndex(of: key), i + 1 < args.count else { return fallback }
    return args[i + 1]
}
func optInt(_ key: String, _ fallback: Int) -> Int { Int(opt(key, String(fallback))) ?? fallback }
let positionals: [String] = args.dropFirst().filter { !$0.starts(with: "-") }
func positional(_ index: Int) -> String {
    guard index < positionals.count else { fail("missing positional argument #\(index)") }
    return positionals[index]
}

let fm = FileManager.default
var manager0: IndexManager?   // 供 kill 线程读取 scannedCount

// MARK: - RSS 采样
func currentRSSMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
}
final class RSSMonitor {
    private var peak = 0.0; private var running = true; private var thread: Thread!
    init() {
        thread = Thread { [weak self] in
            while self?.running == true { self?.peak = max(self?.peak ?? 0, currentRSSMB()); Thread.sleep(forTimeInterval: 0.05) }
        }
        thread.start()
    }
    func stop() -> Double { running = false; Thread.sleep(forTimeInterval: 0.1); return peak }
}

// MARK: - 数据生成（确定性，含任务卡要求的边角用例）
struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 { state ^= state << 13; state ^= state >> 7; state ^= state << 17; return state }
    mutating func int(_ upper: Int) -> Int { Int(next() % UInt64(upper)) }
}
let chineseWords = ["教学", "课程", "论文", "实验", "报告", "毕业", "合影", "课件", "作业", "会议", "发票", "笔记", "项目", "资料", "档案", "设计"]
let extensions = ["pdf", "docx", "pptx", "xlsx", "png", "jpg", "mp4", "mov", "zip", "txt", "md", "csv"]

func generate(root: String, count: Int, seed: UInt64, manifestPath: String) throws {
    try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
    var rng = SeededRandom(seed: seed)
    var manifest: [String] = []
    manifest.reserveCapacity(count)
    var madeDirs = Set<String>()   // 网络卷上 createDirectory 也有往返，缓存避免每文件一次
    let dirsPerLevel = 40
    let content = Data("astfind d1 sample\n".utf8)
    let begin = Date()
    for i in 0..<count {
        let dirIndex = i / dirsPerLevel
        let depth = 2 + dirIndex % 4
        var dir = root
        for d in 0..<depth { dir += "/d\(dirIndex)-\(d)" }
        let name: String
        switch i % 97 {
        case 0: name = "report.pdf"                                   // 同名文件跨目录
        case 1: name = "总结 报告(最终版) v\(i % 9 + 1).pdf"           // 空格/括号/中文
        case 2: name = "照片🎬\(i).jpg"                               // emoji
        case 3: name = "很长很长很长很长很长很长很长很长很长很长很长很长很长很长很长名字-\(i).docx"
        default:
            let word = chineseWords[rng.int(chineseWords.count)]
            name = "\(word)-\(i % 1000).\(extensions[rng.int(extensions.count)])"
        }
        let path = dir + "/" + name
        if !madeDirs.contains(dir) {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            madeDirs.insert(dir)
        }
        try content.write(to: URL(fileURLWithPath: path))
        manifest.append(String(path.dropFirst(root.count + 1)))
        if i % 10_000 == 9_999 { try? manifest.joined(separator: "\n").write(toFile: manifestPath + ".partial", atomically: true, encoding: .utf8) }
    }
    try manifest.joined(separator: "\n").write(toFile: manifestPath, atomically: true, encoding: .utf8)
    try? fm.removeItem(atPath: manifestPath + ".partial")
    metric(["phase": "generate", "files": count, "seconds": String(format: "%.1f", Date().timeIntervalSince(begin)), "root": "\"\(root)\""])
}

// MARK: - 扫描（经 IndexManager，公开 API 路径）
func waitFor(_ manager: IndexManager, _ target: IndexManager.State, timeout: TimeInterval) -> (Bool, IndexManager.State) {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if manager.state == target { Thread.sleep(forTimeInterval: 0.05); return (true, manager.state) }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return (manager.state == target, manager.state)
}
func makeManager(root: String, db: String) -> IndexManager {
    IndexManager(config: IndexConfig(rootPath: root), dbURL: URL(fileURLWithPath: db), volumeUUID: nil, settingsDefaults: nil)
}

// MARK: - 主分发
switch mode {
case "generate":
    let root = positional(0), count = Int(positional(1)) ?? 0
    if count <= 0 { fail("count must be > 0") }
    try generate(root: root, count: count, seed: UInt64(optInt("--seed", 42)), manifestPath: opt("--manifest", root + "/../astfind-manifest.tsv"))
    exit(0)

case "scan":
    let root = positional(0), db = positional(1)
    let killAtCount = optInt("--kill-at-count", 0)
    if killAtCount > 0 {
        Thread.detachNewThread {
            // 按扫描进度自杀：确定性命中"扫描中途被拔线/崩溃"，比定时更准
            let deadline = Date().addingTimeInterval(600)
            while Date() < deadline {
                if manager0 != nil, (manager0?.scannedCount ?? 0) >= killAtCount {
                    print("KILLING SELF mid-scan at scannedCount=\(killAtCount) (simulating unplug/crash)")
                    kill(getpid(), SIGKILL)
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
    }
    let monitor = RSSMonitor()
    let manager = makeManager(root: root, db: db)
    manager0 = manager
    let begin = Date()
    manager.start()
    let (loaded, loadedState) = waitFor(manager, .ready, timeout: 3600)
    if killAtCount > 0, loaded {
        manager.rescan()   // 已有有效快照时强制真实重扫，保证 kill 落在扫描中；rescan 期间 state 保持 .ready
        var sawRescan = false
        let beginDeadline = Date().addingTimeInterval(10)
        while Date() < beginDeadline {
            if manager.isRescanning { sawRescan = true; break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        check(sawRescan, "rescan actually started (for interruption test)")
        // 等待被 kill 线程终结；若扫描快于 kill（小数据集），则等 rescan 完成后正常收尾
        while manager.isRescanning { Thread.sleep(forTimeInterval: 0.01) }
    }
    let (ok, state) = (loaded, loadedState)
    let seconds = Date().timeIntervalSince(begin)
    let entries = manager.store.map { s -> Int in s.read { s.liveCount } } ?? 0
    let peak = monitor.stop()
    manager.saveNow()
    manager.stop()
    metric(["phase": "scan", "seconds": String(format: "%.2f", seconds), "entries": entries,
            "entriesPerSec": Int(Double(entries) / max(seconds, 0.001)), "peakRSSMB": String(format: "%.0f", peak), "state": "\"\(state)\""])
    check(ok, "scan reaches ready", "state=\(state)")
    exit(failures == 0 ? 0 : 1)

case "offline":
    let root = positional(0), db = positional(1), manifestPath = positional(2)
    let sample = optInt("--sample", 200), runs = optInt("--runs", 50)
    guard !fm.fileExists(atPath: root) else { fail("offline mode requires the source root to be ABSENT (rename it away first)") }
    let manager = makeManager(root: root, db: db)
    let begin = Date()
    manager.startOffline()
    let (ok, state) = waitFor(manager, .ready, timeout: 30)
    metric(["phase": "offline-load", "seconds": String(format: "%.3f", Date().timeIntervalSince(begin)), "state": "\"\(state)\""])
    guard ok, let store = manager.store else { check(false, "offline load ready with store", "state=\(state)"); exit(1) }
    let source = SearchSource(id: "smb", displayName: "SMB", isOnline: false, store: store)
    let manifest = try String(contentsOfFile: manifestPath, encoding: .utf8).split(separator: "\n").map(String.init)
    var rng = SeededRandom(seed: 7)
    var missing = 0
    for _ in 0..<min(sample, manifest.count) {
        let rel = manifest[rng.int(manifest.count)]
        let query = Query.parse(URL(fileURLWithPath: rel).lastPathComponent)
        let found = MultiSearcher.search(query, in: [source]).map { result in
            result.items.contains { result.sources[$0.sourceIndex].store.path($0.entryID) == root + "/" + rel }
        } ?? false
        if !found { missing += 1 }
    }
    check(missing == 0, "offline sampled queries resolve to original paths", "sample=\(sample) missing=\(missing)")
    var latencies: [Double] = []
    for _ in 0..<runs {
        let rel = manifest[rng.int(manifest.count)]
        let began = CFAbsoluteTimeGetCurrent()
        _ = MultiSearcher.search(Query.parse(URL(fileURLWithPath: rel).lastPathComponent), in: [source])
        latencies.append((CFAbsoluteTimeGetCurrent() - began) * 1000)
    }
    latencies.sort()
    metric(["phase": "offline-query", "runs": runs,
            "p50ms": String(format: "%.3f", latencies[latencies.count / 2]),
            "p95ms": String(format: "%.3f", latencies[min(latencies.count - 1, Int(ceil(Double(latencies.count) * 0.95)) - 1)])])
    manager.stop()
    exit(failures == 0 ? 0 : 1)

case "reconnect":
    let oldRoot = positional(0), newRoot = positional(1), db = positional(2), manifestPath = positional(3)
    let sample = optInt("--sample", 200)
    guard fm.fileExists(atPath: newRoot) else { fail("reconnect mode requires newRoot to EXIST (the remounted share)") }
    guard let store = IndexStore.load(from: db) else { fail("cannot load snapshot at \(db)") }
    store.write { store.buildHash() }
    let source = SearchSource(id: "smb", displayName: "SMB", isOnline: true, store: store)
    let manifest = try String(contentsOfFile: manifestPath, encoding: .utf8).split(separator: "\n").map(String.init)
    var rng = SeededRandom(seed: 11)
    var staleOldRoot = 0, opened = 0
    for _ in 0..<min(sample, manifest.count) {
        let rel = manifest[rng.int(manifest.count)]
        let query = Query.parse(URL(fileURLWithPath: rel).lastPathComponent)
        guard let result = MultiSearcher.search(query, in: [source]),
              let hit = result.items.first(where: { result.sources[$0.sourceIndex].store.path($0.entryID) == oldRoot + "/" + rel })
        else { continue }
        let recorded = result.sources[hit.sourceIndex].store.path(hit.entryID)
        if recorded.hasPrefix(oldRoot) { staleOldRoot += 1 }
        let rebound = newRoot + "/" + rel
        if fm.fileExists(atPath: rebound) { opened += 1 }
    }
    metric(["phase": "reconnect", "sample": min(sample, manifest.count), "pathsRecordedUnderOldRoot": staleOldRoot, "reboundFilesExist": opened])
    check(opened == min(sample, manifest.count), "all sampled results rebind to real files at new mount")
    exit(failures == 0 ? 0 : 1)

case "mutate":
    let root = positional(0), manifestOut = positional(1)
    let add = optInt("--add", 0), rename = optInt("--rename", 0), delete = optInt("--delete", 0)
    guard fm.fileExists(atPath: root) else { fail("mutate requires root to exist (second client changes)") }
    var rng = SeededRandom(seed: UInt64(optInt("--seed", 99)))
    var changes = 0
    for i in 0..<add {
        let path = root + "/second-client/new-\(i).txt"
        try? fm.createDirectory(atPath: root + "/second-client", withIntermediateDirectories: true)
        try? "added by second client\n".write(toFile: path, atomically: true, encoding: .utf8); changes += 1
    }
    let dirGuess = (0..<20).map { root + "/d\($0)-0" }
    let runTag = Int(Date().timeIntervalSince1970) % 100_000
    for i in 0..<rename {
        guard let dir = dirGuess.randomElement() else { continue }
        let from = dir + "/\(i).renamed-from.txt"
        try? "x".write(toFile: from, atomically: true, encoding: .utf8)
        try? fm.moveItem(atPath: from, toPath: dir + "/renamed-\(runTag)-\(i)-to.txt"); changes += 1
    }
    // 优先删除快照中真实存在的文件（manifest 提供时），才能真正测到收敛的 removed
    let manifestPath = opt("--manifest", "")
    let candidates: [String] = manifestPath.isEmpty ? [] : (try? String(contentsOfFile: manifestPath, encoding: .utf8))?
        .split(separator: "\n").map(String.init).shuffled() ?? []
    for i in 0..<delete {
        if i < candidates.count {
            try? fm.removeItem(atPath: root + "/" + candidates[i]); changes += 1
        } else {
            let path = root + "/second-client/doomed-\(runTag)-\(i).txt"
            try? "doomed\n".write(toFile: path, atomically: true, encoding: .utf8)
            try? fm.removeItem(atPath: path); changes += 1
        }
    }
    // manifestOut：重扫后的期望全集由 sync 现场枚举得出，这里只记录操作数
    try "\(changes)\n".write(toFile: manifestOut, atomically: true, encoding: .utf8)
    metric(["phase": "mutate", "add": add, "rename": rename, "delete": delete])
    exit(0)

case "sync":
    let root = positional(0), db = positional(1)
    _ = positional(2) // manifestAfter：当前实现直接以文件系统为准
    let sample = optInt("--sample", 200)
    guard let before = IndexStore.load(from: db) else { fail("cannot load pre-sync snapshot") }
    // 收敛对比必须按相对路径：重挂载后 store 根路径变化，绝对路径不可比（Astfind 身份= source_id+relative_path）
    func relativePaths(of store: IndexStore) -> Set<String> {
        let root = store.rootPath == "/" ? "" : store.rootPath
        return Set((1..<store.count).filter { store.isLive(UInt32($0)) }.map { String(store.path(UInt32($0)).dropFirst(root.count + 1)) })
    }
    let beforePaths = relativePaths(of: before)
    let manager = makeManager(root: root, db: db)
    let begin = Date()
    manager.start()
    let (ok, state) = waitFor(manager, .ready, timeout: 3600)
    guard ok else { check(false, "sync reaches ready", "state=\(state)"); exit(1) }
    if args.contains("--rescan") {
        // 后台 rescan 期间 state 仍为 .ready，必须盯 isRescanning + store 内容稳定
        manager.rescan()
        var sawRescan = false
        let beginDeadline = Date().addingTimeInterval(10)
        while Date() < beginDeadline {
            if manager.isRescanning { sawRescan = true; break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        check(sawRescan, "rescan actually started")
        let finishDeadline = Date().addingTimeInterval(600)
        while Date() < finishDeadline && manager.isRescanning { Thread.sleep(forTimeInterval: 0.05) }
        var stable = 0, last = -1
        let settleDeadline = Date().addingTimeInterval(30)
        while Date() < settleDeadline {
            let count = manager.store.map { s -> Int in s.read { s.liveCount } } ?? 0
            if count == last { stable += 1; if stable >= 10 { break } } else { stable = 0; last = count }
            Thread.sleep(forTimeInterval: 0.1)
        }
    } else {
        // 本地卷：start() 加载快照后由 FSEvents 重放增量；等待 liveCount 稳定再比较
        var stable = 0, last = -1
        let settleDeadline = Date().addingTimeInterval(60)
        while Date() < settleDeadline {
            let count = manager.store.map { s -> Int in s.read { s.liveCount } } ?? 0
            if count == last { stable += 1; if stable >= 50 { break } } else { stable = 0; last = count }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
    let seconds = Date().timeIntervalSince(begin)
    guard let after = manager.store else { check(false, "sync store available"); exit(1) }
    manager.saveNow(); manager.stop()
    let afterPaths = relativePaths(of: after)
    let added = afterPaths.subtracting(beforePaths), removed = beforePaths.subtracting(afterPaths)
    // 断线安全反例：确认 sync 是完整扫描后的提交（此处为本地验证机械，SMB 断线注入在真实环境用 --kill-after + offline 组合）
    metric(["phase": "sync", "seconds": String(format: "%.2f", seconds), "before": beforePaths.count, "after": afterPaths.count,
            "added": added.count, "removed": removed.count])
    let missingAdded = added.filter { !fm.fileExists(atPath: root + "/" + $0) }
    check(missingAdded.isEmpty, "all added entries exist on source", missingAdded.isEmpty ? "" : "phantom: \(Array(missingAdded.prefix(3)))")
    check(removed.allSatisfy { !fm.fileExists(atPath: root + "/" + $0) }, "all removed entries absent on source")
    exit(failures == 0 ? 0 : 1)

default:
    fail("unknown mode \(mode)")
}
