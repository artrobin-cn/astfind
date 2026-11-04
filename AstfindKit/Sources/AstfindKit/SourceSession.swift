import Foundation
import OilFindCore

/// 单个来源的索引会话：驱动 oil-find `IndexManager`，产出可搜索的 `SearchSource`。
///
/// D1 实测结论固化于此：
/// - 离线优先：`loadOffline()` 用**快照构建时的根路径**构造 config（指纹匹配的前提），
///   从不触碰文件系统；结果路径在展示层按当前挂载点重绑。
/// - 网络卷（SMB/AFP）在线时走完整重扫语义（无可靠 FSEvents，ADL-108）；
///   本地卷若游标有效则享受上游的事件重放增量。
/// - `entryID` 只在当次查询内使用，绝不持久化（ADL-109）。
public final class SourceSession {
    public enum SessionState: Equatable, Sendable {
        case idle
        case offlineReady
        case onlineReady
    }

    public let record: SourceRecord
    private let registry: SourceRegistry
    private let snapshotURL: URL
    private var manager: IndexManager?
    /// 正在扫描的 manager（成功后才替换 `manager`）；用于实时计数与取消唤醒。
    private var scanningManager: IndexManager?
    private(set) public var state: SessionState = .idle
    private var activeScanRun: ScanRunRecord?
    private let lock = NSLock()
    /// 外置卷传卷 UUID：快照指纹与根路径无关（重挂载可复用）+ rebase 自动重绑 + 防错认他盘。
    /// local/SMB 传 nil（D0/D4 结论）。
    private let volumeUUID: String?
    /// M0.6 调度接线（由 ScanScheduler 注入；直接构造 SourceSession 的测试保持 nil 直通）。
    var scanPacing: ScanPacingController?

    /// - Parameters:
    ///   - snapshotDirectory: 每个 source 一份独立快照文件（`<sourceId>.oilfind`）。
    public init(record: SourceRecord, registry: SourceRegistry, snapshotDirectory: URL) throws {
        self.record = record
        self.registry = registry
        try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: snapshotDirectory.path)
        self.snapshotURL = snapshotDirectory.appendingPathComponent(record.sourceId + ".oilfind")
        self.volumeUUID = record.kind == .external ? record.volumeIdentity : nil
    }

    // MARK: 离线路径（零源 I/O）

    /// 从本地快照恢复可搜索状态。挂载点在不在都行——config 用快照的原始根路径。
    /// 每次重读 registry 最新记录：快照根路径可能由任意一次成功扫描写入（构造时的副本可能过期）。
    public func loadOffline() throws -> SearchSource? {
        try lock.withLock {
            let fresh = try registry.source(id: record.sourceId) ?? record
            guard let snapshotRoot = fresh.snapshotRootPath else { return nil }
            let offline = IndexManager(
                config: IndexConfig(rootPath: snapshotRoot),
                dbURL: snapshotURL,
                volumeUUID: volumeUUID,
                settingsDefaults: nil)   // 隔离宿主 UserDefaults，防指纹漂移（D0 结论）
            offline.startOffline()
            guard waitUntilReady(offline, timeout: 30) else {
                _ = offline.store
                return nil
            }
            guard let store = offline.store else { return nil }
            manager = offline
            state = .offlineReady
            return SearchSource(id: record.sourceId, displayName: record.displayName, isOnline: false, store: store)
        }
    }

    // MARK: 在线路径（完整重扫提交语义）

    /// 挂载点在线时扫描/重扫。scanRun 记账贯穿始终：只有观察到 `.ready` 且重扫真正结束
    /// 才 `endScanRun(success: true)` 并同步资产。任何失败/超时只把来源降为 stale——
    /// 旧快照与资产行不动（离线 ≠ 删除）。
    ///
    /// 关键事实（D4 实测）：无 device 参数的 FSEvents 流会忽略 `sinceWhen` 历史游标
    /// （onApply 恒为 0）——**历史重放不可依赖**。因此权威扫描 = 强制完整重扫提交
    /// （ADL-108 的立场）；上游增量重放仅对带 device 的本地外置卷有效，不在本路径使用。
    @discardableResult
    public func scanOnline(mountPath: String, timeout: TimeInterval = 3600, syncAssets: Bool = true) throws -> SearchSource? {
        let run = try registry.beginScanRun(sourceId: record.sourceId)
        try lock.withLock { activeScanRun = run }
        let hadSnapshot = FileManager.default.fileExists(atPath: snapshotURL.path)
        let online = IndexManager(
            config: IndexConfig(rootPath: mountPath),
            dbURL: snapshotURL,
            volumeUUID: volumeUUID,
            settingsDefaults: nil)
        // 权威重扫与首扫分块必须使用同一策略来源；工厂在每次 Scanner 创建时调用。
        if let scanPacing {
            let kind = record.kind, sourceId = record.sourceId
            online.scanPacerFactory = { [weak scanPacing] in
                scanPacing?.makePacer(for: kind, sourceId: sourceId)
            }
        }
        lock.withLock { scanningManager = online }
        online.beginScanMeasurement()
        defer {
            online.endScanMeasurement()
            lock.withLock { if scanningManager === online { scanningManager = nil } }
        }
        let began = ProcessInfo.processInfo.systemUptime
        NSLog("astfind scan begin source=%@ kind=%@ run=%@ manager=%@ mode=%@ pacer=%@",
              String(record.sourceId.prefix(8)), record.kind.rawValue,
              String(run.scanRunId.prefix(8)), String(describing: ObjectIdentifier(online)),
              hadSnapshot ? "rescan" : "initial",
              scanPacing != nil && record.kind == .smb ? "on" : "off")
        online.start()
        guard waitUntilReady(online, timeout: timeout) else {
            online.stop()
            try registry.endScanRun(run, success: false)
            lock.withLock { state = .idle }
            logScanEnd(online, run: run, began: began, success: false)
            return nil
        }
        if hadSnapshot {
            // start() 走了快照加载路径（快照已在）：强制完整重扫拿到当前真值。
            // 但如果 start() 因快照无效已经实际扫描过，再 rescan() 就是同一 run 内的
            // 第二次完整遍历；用 pass 证据跳过冗余 pass。
            let startPasses = online.lastScanPacerPasses
            let startDidScan = startPasses.contains { $0.kind == .initial && $0.completed }
            if startDidScan {
                NSLog("astfind scan skip redundant rescan source=%@ run=%@ passes=%d scannedEntries=%d",
                      String(record.sourceId.prefix(8)), String(run.scanRunId.prefix(8)),
                      startPasses.count, startPasses.reduce(0) { $0 + $1.scannedEntries })
            } else {
                // 完成信号用 store 对象身份——每次重扫必安装全新 IndexStore 实例，
                // isRescanning 在小树上可能两次轮询间就翻转（实测 <20ms 扫完），不可靠。
                let storeBefore = online.store
                online.rescan()
                guard waitUntilStoreReplaced(online, previous: storeBefore, timeout: timeout) else {
                    online.stop()
                    try registry.endScanRun(run, success: false)
                    lock.withLock { state = .idle }
                    logScanEnd(online, run: run, began: began, success: false)
                    return nil
                }
            }
        }
        waitUntilScanSettles(online, timeout: min(timeout, 30))
        online.saveNow()
        let store = online.store
        let root = store.map { s -> String in s.read { s.rootPath } }
        try registry.endScanRun(run, success: store != nil, snapshotRootPath: root)
        try registry.updateMount(sourceId: record.sourceId, mountPath: mountPath, online: true)
        var entryCount = 0
        if syncAssets, let store {
            let entries = SourceRegistry.entries(in: store)
            entryCount = entries.count
            _ = try registry.syncAssets(sourceId: record.sourceId, scanRunId: run.scanRunId, scanRunCompleted: true, entries: entries)
        }
        lock.withLock {
            manager = online
            state = .onlineReady
            activeScanRun = nil
        }
        logScanEnd(online, run: run, began: began, success: store != nil, entries: entryCount)
        return store.map { SearchSource(id: record.sourceId, displayName: record.displayName, isOnline: true, store: $0) }
    }

    private func logScanEnd(_ manager: IndexManager, run: ScanRunRecord,
                            began: TimeInterval, success: Bool, entries: Int? = nil) {
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        let metrics = manager.lastScanPacerMetrics
        let passes = manager.lastScanPacerPasses
        let scannedPassEntries = passes.reduce(0) { $0 + $1.scannedEntries }
        let scanned = entries ?? scannedPassEntries
        let passText = passes.enumerated().map { index, pass in
            let m = pass.metrics
            return "\(index + 1):\(pass.kind.rawValue):\(pass.scannerIdentity):done=\(pass.completed ? 1 : 0):entries=\(pass.scannedEntries):ms=\(Int(pass.duration * 1000)):pacer=\(pass.pacerInstalled ? 1 : 0):permits=\(m.permits):artMs=\(Int(m.artificialWait * 1000)):permitWaitMs=\(Int(m.permitWait * 1000)):ioMs=\(Int(m.ioDuration * 1000)):openMs=\(Int(m.openDuration * 1000)):maxOpenMs=\(Int(m.maxOpenDuration * 1000)):readMs=\(Int(m.readDuration * 1000)):maxReadMs=\(Int(m.maxReadDuration * 1000)):slowOpen2s=\(m.slowOpen2s):slowRead2s=\(m.slowRead2s):maxIoMs=\(Int(m.maxIODuration * 1000)):slow2s=\(m.slowIO2000Count):maxInFlight=\(m.maxInFlight)"
        }.joined(separator: "|")
        NSLog("astfind scan end source=%@ kind=%@ run=%@ success=%d elapsed=%.2f scanner=%@ passes=%d pacerPasses=%@ entries=%d entriesPerSecond=%.1f scannedPassEntries=%d directoryBatches=%d permits=%d ioPerSecond=%.1f throttled=%d artificialMs=%.1f permitWaitMs=%.1f suspendWaitMs=%.1f suspendCount=%d ioMs=%.1f maxIODurationMs=%.1f openIoMs=%.1f maxOpenMs=%.1f readIoMs=%.1f maxReadMs=%.1f slowOpen2s=%d slowRead2s=%d slow500=%d slow1s=%d slow2s=%d maxInFlight=%d enters=%d exits=%d",
              String(record.sourceId.prefix(8)), record.kind.rawValue, String(run.scanRunId.prefix(8)),
              success ? 1 : 0, elapsed, manager.lastScannerIdentity,
              passes.count, passText,
              scanned, elapsed > 0 ? Double(scanned) / elapsed : 0,
              scannedPassEntries,
              metrics?.directoryBatches ?? 0,
              metrics?.permits ?? 0,
              elapsed > 0 ? Double(metrics?.permits ?? 0) / elapsed : 0,
              metrics?.throttledCalls ?? 0,
              (metrics?.artificialWait ?? 0) * 1000, (metrics?.permitWait ?? 0) * 1000,
              (metrics?.suspendWait ?? 0) * 1000, metrics?.suspendCount ?? 0,
              (metrics?.ioDuration ?? 0) * 1000, (metrics?.maxIODuration ?? 0) * 1000,
              (metrics?.openDuration ?? 0) * 1000, (metrics?.maxOpenDuration ?? 0) * 1000,
              (metrics?.readDuration ?? 0) * 1000, (metrics?.maxReadDuration ?? 0) * 1000,
              metrics?.slowOpen2s ?? 0, metrics?.slowRead2s ?? 0,
              metrics?.slowIO500Count ?? 0, metrics?.slowIO1000Count ?? 0, metrics?.slowIO2000Count ?? 0,
              metrics?.maxInFlight ?? 0, metrics?.throttleEnterCount ?? 0, metrics?.throttleExitCount ?? 0)
    }

    /// 中断当前扫描（用户暂停/拔线）：失败收尾，保快照。
    public func cancelActiveScan() throws {
        try lock.withLock {
            (scanningManager ?? manager)?.stop()
            scanningManager = nil
            if let run = activeScanRun {
                try registry.endScanRun(run, success: false)
                activeScanRun = nil
            }
            state = .idle
        }
    }

    public func stop() {
        lock.withLock {
            scanningManager?.stop()
            scanningManager = nil
            manager?.stop()
            manager = nil
            state = .idle
        }
    }

    /// 当前搜索来源；离线加载后重绑到新挂载点的路径由调用方处理（展示层职责）。
    public var searchSource: SearchSource? {
        lock.withLock {
            guard let manager, let store = manager.store else { return nil }
            return SearchSource(id: record.sourceId, displayName: record.displayName,
                                isOnline: state == .onlineReady, store: store)
        }
    }

    /// 扫描进行中的实时计数（调度器进度展示用）。
    public var scannedCount: Int {
        lock.withLock { (scanningManager ?? manager)?.scannedCount ?? 0 }
    }

    // MARK: - 验收测试只读锚点（不参与产品逻辑）
    var activeScanRunIdForTesting: String? {
        lock.withLock { activeScanRun?.scanRunId }
    }

    var scannerIdentityForTesting: String? {
        lock.withLock {
            let identity = (scanningManager ?? manager)?.lastScannerIdentity
            return identity?.isEmpty == false ? identity : nil
        }
    }

    /// FIX-1/2：最近一次 scanOnline 的 pass 数（1 = 没有冗余重扫）。
    var lastScanPassCountForTesting: Int {
        lock.withLock { (scanningManager ?? manager)?.lastScanPacerPasses.count ?? 0 }
    }

    var isScanningForTesting: Bool {
        lock.withLock { scanningManager != nil }
    }

    // MARK: 私有

    private func waitUntilReady(_ manager: IndexManager, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var seenActive = false   // start() 异步生效前 state 短暂保持 .idle，不能当失败
        while Date() < deadline {
            switch manager.state {
            case .ready:
                Thread.sleep(forTimeInterval: 0.05)
                return true
            case .idle:
                if seenActive { return false }   // 启动后又回到 idle = 扫描失败收尾
            case .loading, .scanning:
                seenActive = true
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return manager.state == .ready
    }

    /// 重扫完成判定：store 已被替换为新实例且无扫描仍在进行。
    private func waitUntilStoreReplaced(_ manager: IndexManager, previous: IndexStore?, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let store = manager.store, store !== previous, !manager.isRescanning {
                Thread.sleep(forTimeInterval: 0.05)   // 让发布块收尾
                return true
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }

    private func waitUntilScanSettles(_ manager: IndexManager, timeout: TimeInterval) {
        var stable = 0, last = -1
        let deadline = Date().addingTimeInterval(min(timeout, 120))
        while Date() < deadline {
            let count = manager.store.map { s -> Int in s.read { s.liveCount } } ?? 0
            if count == last { stable += 1; if stable >= 25 { return } } else { stable = 0; last = count }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
}

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }; return try body()
    }
}
