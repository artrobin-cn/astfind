// D2 证据生成 demo：注册来源 → 在线扫描 → 资产入库 → 模拟离线（目录消失）
// → 离线加载查询 → 换路径重挂载重扫收敛。输出 [PASS]/[FAIL] 与 METRIC 行。
import Foundation
import OilFindCore
import AstfindKit

var failures = 0
func check(_ condition: Bool, _ label: String, _ detail: String = "") {
    if condition { print("  [PASS] \(label)\(detail.isEmpty ? "" : " — \(detail)")") }
    else { failures += 1; print("  [FAIL] \(label)\(detail.isEmpty ? "" : " — \(detail)")") }
}

let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("astfind-d2-demo-\(Int(Date().timeIntervalSince1970))")
let share = base.appendingPathComponent("share")
try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
for i in 1...50 {
    let dir = share.appendingPathComponent("课档\(i % 5)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try "数据\(i)".write(to: dir.appendingPathComponent("资料-\(i).txt"), atomically: true, encoding: .utf8)
}

let registry = try SourceRegistry(databaseURL: base.appendingPathComponent("registry.sqlite"))
let record = try registry.registerSource(kind: .local, locator: share.path, displayName: "D2 Demo Share")
print("registered source \(record.sourceId) locator=\(record.locator)")

let session = try SourceSession(record: record, registry: registry, snapshotDirectory: base.appendingPathComponent("snapshots"))
let begin = Date()
let online = try session.scanOnline(mountPath: share.path, timeout: 120)
check(online != nil, "online scan completes")
print(String(format: "METRIC phase=scan seconds=%.2f", Date().timeIntervalSince(begin)))
check(try registry.liveAssetCount(sourceId: record.sourceId) == 50, "50 assets persisted")
var loaded = try registry.source(id: record.sourceId)
check(loaded?.indexState == .ready, "index_state=ready")
check(loaded?.snapshotRootPath == share.path, "snapshot_root_path recorded")

// 模拟拔盘 + App 重启
session.stop()
let tucked = base.appendingPathComponent("tucked-away")
try FileManager.default.moveItem(at: share, to: tucked)
let freshSession = try SourceSession(record: try registry.source(id: record.sourceId)!, registry: registry,
                                     snapshotDirectory: base.appendingPathComponent("snapshots"))
let offline = try freshSession.loadOffline()
check(offline != nil, "offline load after restart with source absent")
if let offline {
    let result = MultiSearcher.search(Query.parse("资料-33"), in: [offline])
    check((result?.total ?? 0) >= 1, "offline query hits", "total=\(result?.total ?? 0)")
}

// 换挂载点重连重扫
let remounted = base.appendingPathComponent("share-remounted")
try FileManager.default.moveItem(at: tucked, to: remounted)
_ = try freshSession.scanOnline(mountPath: remounted.path, timeout: 120)
check(try registry.liveAssetCount(sourceId: record.sourceId) == 50, "assets converge after remount rescan")
loaded = try registry.source(id: record.sourceId)
check(loaded?.snapshotRootPath == remounted.path, "snapshot root updated to new mount")
freshSession.stop()

try? FileManager.default.removeItem(at: base)
print(failures == 0 ? "== D2 DEMO ALL PASS ==" : "== D2 DEMO \(failures) FAILURES ==")
exit(failures == 0 ? 0 : 1)
