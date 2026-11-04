import Foundation
import AppKit
import OilFindCore

/// 扫描调度器：把"扫描"从阻塞调用升级为可观可控的状态机（D4 核心）。
///
/// 第一性原理约束（每条都有测试锚定）：
/// 1. 来源可能随时消失 → 任何阶段中断，已完成部分保持可查、可断点续扫；
/// 2. 首次扫描耗时长 → 分块引导：顶层子目录逐块扫描，完成一块立即可搜（部分可查），
///    全部完成后一次全量收敛为单一权威快照并清理块快照；平面根（无子目录）直接权威扫描；
/// 3. 删除确认只在完整子树扫描后发生（块级即子树级，D2 语义延伸）；
/// 4. 符号链接不跨块（防越权逃逸）；并发预算限制跨源同时扫描数；
///    挂载来源周期重扫（无 FSEvents 的网络卷靠它收敛）；睡眠唤醒后重评估。
///
/// 职责边界：本类只管扫描生命周期与块资产；**来源呈现（isOnline 等）归 AstfindEngine**。
public final class ScanScheduler {
    public struct Budget {
        /// 跨来源同时进行的扫描数上限（网络 I/O 预算；1 = 串行，慢 NAS 不饿死其他来源）。
        public var maxConcurrentScans = 1
        /// 挂载来源的周期重扫间隔（秒）。
        public var resyncInterval: TimeInterval = 1800
        public init() {}
    }

    public struct SourceProgress: Equatable, Sendable {
        public enum Phase: Equatable, Sendable {
            case idle, bootstrap(chunksDone: Int, chunksTotal: Int), rescan, paused, ready
        }
        public let sourceId: String
        public let displayName: String
        public let phase: Phase
        public let scanned: Int
    }

    /// 状态/进度变化回调（调度线程；UI 层自行转主线程）。
    public var onProgress: ((SourceProgress) -> Void)?

    private let registry: SourceRegistry
    private let snapshotDirectory: URL
    private let budget: Budget
    /// M0.6：SMB 交互优先策略；两条扫描路径共享同一策略来源。
    private let pacing: ScanPacingController?
    private let decisionQueue = DispatchQueue(label: "astfind.scheduler.decision")
    private let workQueue = DispatchQueue(label: "astfind.scheduler.work", qos: .utility)
    /// 进度回调专用队列：绝不占用 decision 队列——回调链可能重入查询（decisionQueue.sync），同队列会死锁/陷阱。
    private let callbackQueue = DispatchQueue(label: "astfind.scheduler.callback")
    private let semaphore: DispatchSemaphore
    private var states: [String: PerSource] = [:]
    private var wakeObserver: NSObjectProtocol?

    private final class PerSource {
        let session: SourceSession
        var displayName: String
        var mountPath: String?
        var phase: SourceProgress.Phase = .idle
        var chunksTotal = 0
        var chunkRoots: [String] = []            // 顶层子目录名（排序后）
        var chunkSources: [SearchSource] = []    // 已完成块（立即可搜）
        var activeChunkManager: IndexManager?
        var resyncTimer: DispatchSourceTimer?
        var paused = false
        var cancelled = false
        /// 单来源同时最多一条扫描管线（幂等防重入：两个 IndexManager 并发写同一快照会损坏文件）。
        var pipelineActive = false
        init(session: SourceSession, displayName: String) {
            self.session = session; self.displayName = displayName
        }
    }

    public convenience init(registry: SourceRegistry, snapshotDirectory: URL, budget: Budget = Budget()) {
        self.init(registry: registry, snapshotDirectory: snapshotDirectory, budget: budget, pacing: nil)
    }

    init(registry: SourceRegistry, snapshotDirectory: URL, budget: Budget = Budget(),
         pacing: ScanPacingController?) {
        self.registry = registry
        self.snapshotDirectory = snapshotDirectory
        self.budget = budget
        self.pacing = pacing
        self.semaphore = DispatchSemaphore(value: max(1, budget.maxConcurrentScans))
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.decisionQueue.async { self?.rescheduleAll() }
        }
    }
    deinit {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        states.values.forEach { $0.resyncTimer?.cancel() }
    }

    // MARK: - 生命周期

    /// 注册来源（幂等，同步完成：loadOffline 离线优先加载 + 块快照离线恢复）。
    /// 快照布局沿用 D2 约定：`<sourceId>.oilfind` + `<sourceId>.boot.<i>.oilfind`。
    public func attach(record: SourceRecord) {
        var attachedNewly = false
        decisionQueue.sync {
            guard states[record.sourceId] == nil,
                  let session = try? SourceSession(record: record, registry: registry,
                                                   snapshotDirectory: snapshotDirectory)
            else { return }
            session.scanPacing = pacing
            let state = PerSource(session: session, displayName: record.displayName)
            // 离线也恢复已完成块（部分可查不依赖挂载——核心价值）：
            // 块快照文件名即断点状态，来源未挂载时 chunksTotal 未知，挂载后由 beginWork 补全。
            if !hasCanonicalSnapshot(sourceId: record.sourceId) {
                state.chunkSources = Self.restoreChunkSources(sourceId: record.sourceId,
                                                              displayName: record.displayName,
                                                              snapshotDirectory: snapshotDirectory)
            }
            states[record.sourceId] = state
            attachedNewly = true
        }
        // 只对新 attach 的来源做离线加载——重复 attach（如 engine.start 复查）绝不能
        // 把已在线扫描完的 session 盖回 offline 态（曾因此导致 isOnline 恒 false）。
        if attachedNewly {
            _ = try? session(sourceId: record.sourceId)?.loadOffline()
        }
    }

    public func shutdown() {
        decisionQueue.sync {
            for state in states.values {
                state.cancelled = true
                state.resyncTimer?.cancel()
                state.activeChunkManager?.stop()
                state.session.stop()
            }
            states.removeAll()
        }
    }

    /// 移除单个来源的调度状态（引擎 remove 时调用；不动其他来源）。
    public func shutdownSource(sourceId: String) {
        decisionQueue.sync {
            guard let state = states.removeValue(forKey: sourceId) else { return }
            state.cancelled = true
            state.resyncTimer?.cancel()
            state.activeChunkManager?.stop()
            state.session.stop()
        }
    }

    public func session(sourceId: String) -> SourceSession? {
        decisionQueue.sync { states[sourceId]?.session }
    }

    // MARK: - 挂载事件

    public func handleMounted(record: SourceRecord, mountPath: String) {
        decisionQueue.async { [weak self] in
            guard let self, let state = self.states[record.sourceId] else { return }
            state.mountPath = mountPath
            state.displayName = record.displayName
            state.cancelled = false
            guard !state.paused else { return }
            self.beginWork(state, sourceId: record.sourceId)
        }
    }

    public func handleUnmounted(sourceId: String) {
        decisionQueue.async { [weak self] in
            guard let self, let state = self.states[sourceId] else { return }
            state.mountPath = nil
            state.pipelineActive = false   // 待处理的工作块会因挂载检查空转退出
            state.resyncTimer?.cancel(); state.resyncTimer = nil
            state.activeChunkManager?.stop()   // 已完成块保留（引擎按挂载态重算 isOnline）
            // M0.6：拔盘优先于保底放行，必须唤醒正在等待的 Pacer/扫描。
            try? state.session.cancelActiveScan()
            state.phase = .idle
            self.emitProgress(sourceId, state)
        }
    }

    // MARK: - 暂停 / 恢复

    public func pause(sourceId: String) {
        decisionQueue.async { [weak self] in
            guard let self, let state = self.states[sourceId] else { return }
            state.paused = true
            state.resyncTimer?.cancel(); state.resyncTimer = nil
            state.activeChunkManager?.stop()
            try? state.session.cancelActiveScan()   // 失败收尾：保快照、降 stale——不删任何数据
            state.phase = .paused
            self.emitProgress(sourceId, state)
        }
    }

    public func resume(sourceId: String) {
        decisionQueue.async { [weak self] in
            guard let self, let state = self.states[sourceId] else { return }
            state.paused = false
            if state.mountPath != nil {
                self.beginWork(state, sourceId: sourceId)   // 剩余块续扫 / 重新收敛
            }
        }
    }

    // MARK: - 查询（供引擎呈现）

    /// 引导期已完成的块来源（部分可查的载体）。权威快照存在后返回空。
    public func chunkSources(sourceId: String) -> [SearchSource] {
        decisionQueue.sync {
            guard !hasCanonicalSnapshot(sourceId: sourceId) else { return [] }
            return states[sourceId]?.chunkSources ?? []
        }
    }

    public func progress() -> [SourceProgress] {
        decisionQueue.sync {
            states.map { sourceId, state in
                SourceProgress(sourceId: sourceId, displayName: state.displayName,
                               phase: state.phase, scanned: state.session.scannedCount)
            }.sorted { $0.sourceId < $1.sourceId }
        }
    }

    public func isScanning(sourceId: String) -> Bool {
        decisionQueue.sync {
            switch states[sourceId]?.phase {
            case .bootstrap, .rescan: return true
            default: return false
            }
        }
    }

    // MARK: - 工作流（decision 线程）

    private func beginWork(_ state: PerSource, sourceId: String) {
        guard let mount = state.mountPath, !state.paused, !state.cancelled else { return }
        // 管线幂等：进行中（bootstrap/rescan/pipelineActive）不再起第二条
        if case .bootstrap = state.phase { return }
        if case .rescan = state.phase { return }
        guard !state.pipelineActive else { return }
        if hasCanonicalSnapshot(sourceId: sourceId) {
            runCanonical(state, sourceId: sourceId, mountPath: mount)
            return
        }
        // 首扫：分块引导。断点续扫 = 块快照文件存在即已完成（上游只在扫描完成才落盘）。
        if state.chunkRoots.isEmpty {
            state.chunkRoots = Self.enumerateChunks(root: mount)
            state.chunksTotal = state.chunkRoots.count
            state.chunkSources = state.chunkRoots.enumerated().compactMap { index, _ in
                Self.loadChunkSource(sourceId: sourceId, displayName: state.displayName,
                                     chunkIndex: index, snapshotDirectory: snapshotDirectory)
            }
        }
        let done = Set(state.chunkSources.map(\.id))
        let remaining = state.chunkRoots.enumerated().filter { index, _ in
            !done.contains(chunkSourceId(sourceId: sourceId, index: index))
        }
        guard !remaining.isEmpty else {
            runCanonical(state, sourceId: sourceId, mountPath: mount)   // 块全完成（或无子目录）→ 收敛
            return
        }
        state.phase = .bootstrap(chunksDone: state.chunkSources.count, chunksTotal: state.chunksTotal)
        emitProgress(sourceId, state)
        runNextChunk(state, sourceId: sourceId)
    }

    private func runNextChunk(_ state: PerSource, sourceId: String) {
        state.pipelineActive = true
        workQueue.async { [weak self] in
            guard let self else { return }
            self.semaphore.wait()
            defer { self.semaphore.signal() }
            let next: (name: String, index: Int)? = self.decisionQueue.sync {
                guard !state.paused, !state.cancelled, state.mountPath != nil else { return nil }
                let done = Set(state.chunkSources.map(\.id))
                for (index, chunk) in state.chunkRoots.enumerated()
                where !done.contains(self.chunkSourceId(sourceId: sourceId, index: index)) {
                    return (chunk, index)
                }
                return nil
            }
            guard let next, let mount = state.mountPath else {
                self.decisionQueue.async { [weak self] in
                    guard let self else { return }
                    state.pipelineActive = false
                    guard state.mountPath != nil, !state.paused, !state.cancelled else {
                        self.emitProgress(sourceId, state); return
                    }
                    self.runCanonical(state, sourceId: sourceId, mountPath: state.mountPath!)
                }
                return
            }
            self.scanChunk(state, sourceId: sourceId, mount: mount,
                           chunkName: next.name, chunkIndex: next.index)
            self.decisionQueue.async { [weak self] in
                guard let self else { return }
                guard state.mountPath != nil, !state.paused, !state.cancelled else {
                    state.pipelineActive = false
                    self.emitProgress(sourceId, state); return
                }
                self.runNextChunk(state, sourceId: sourceId)
            }
        }
    }

    private func scanChunk(_ state: PerSource, sourceId: String, mount: String,
                           chunkName: String, chunkIndex: Int) {
        let chunkRoot = mount + "/" + chunkName
        let dbURL = snapshotDirectory.appendingPathComponent("\(sourceId).boot.\(chunkIndex).oilfind")
        let manager = IndexManager(config: IndexConfig(rootPath: chunkRoot), dbURL: dbURL,
                                   volumeUUID: nil, settingsDefaults: nil)
        if let pacing {
            let kind = state.session.record.kind
            manager.scanPacerFactory = { [weak pacing] in
                pacing?.makePacer(for: kind, sourceId: sourceId)
            }
        }
        decisionQueue.sync { state.activeChunkManager = manager }
        manager.beginScanMeasurement()
        defer { manager.endScanMeasurement() }
        let began = ProcessInfo.processInfo.systemUptime
        NSLog("astfind scan chunk begin source=%@ kind=%@ run=boot-%d manager=%@ pacer=%@",
              String(sourceId.prefix(8)), state.session.record.kind.rawValue, chunkIndex,
              String(describing: ObjectIdentifier(manager)),
              pacing != nil && state.session.record.kind == .smb ? "on" : "off")
        manager.start()
        guard waitUntilReady(manager, timeout: 3600), let store = manager.store else {
            decisionQueue.sync { state.activeChunkManager = nil }
            logChunkEnd(manager, sourceId: sourceId, kind: state.session.record.kind,
                        chunkIndex: chunkIndex, began: began, success: false, entries: nil)
            return   // 单块失败跳过，收敛扫描兜底；不阻塞其余块
        }
        manager.saveNow()
        decisionQueue.sync { state.activeChunkManager = nil }
        // 块=该子树的完整扫描 → 其范围内可确认删除；资产带前缀入库（不虚报 source 级 index_state）
        let prefix = chunkName + "/"
        let entries = SourceRegistry.entries(in: store).map { entry in
            (relativePath: prefix + entry.relativePath, kind: entry.kind, size: entry.size, mtimeNs: entry.mtimeNs)
        }
        _ = try? registry.syncAssets(sourceId: sourceId, scanRunId: "boot-\(chunkIndex)",
                                     scanRunCompleted: true, entries: entries)
        logChunkEnd(manager, sourceId: sourceId, kind: state.session.record.kind,
                    chunkIndex: chunkIndex, began: began, success: true, entries: entries.count)
        let source = SearchSource(id: chunkSourceId(sourceId: sourceId, index: chunkIndex),
                                  displayName: state.displayName, isOnline: true, store: store)
        decisionQueue.sync {
            state.chunkSources.append(source)
            state.phase = .bootstrap(chunksDone: state.chunkSources.count, chunksTotal: state.chunksTotal)
            self.emitProgress(sourceId, state)
        }
    }

    private func logChunkEnd(_ manager: IndexManager, sourceId: String, kind: SourceRecord.Kind,
                             chunkIndex: Int, began: TimeInterval, success: Bool, entries: Int?) {
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        let metrics = manager.lastScanPacerMetrics
        let passes = manager.lastScanPacerPasses
        let scannedPassEntries = passes.reduce(0) { $0 + $1.scannedEntries }
        let scanned = entries ?? scannedPassEntries
        NSLog("astfind scan chunk end source=%@ kind=%@ run=boot-%d success=%d elapsed=%.2f scanner=%@ passes=%d entries=%d entriesPerSecond=%.1f scannedPassEntries=%d directoryBatches=%d permits=%d ioPerSecond=%.1f throttled=%d artificialMs=%.1f permitWaitMs=%.1f suspendWaitMs=%.1f suspendCount=%d ioMs=%.1f maxIODurationMs=%.1f openIoMs=%.1f maxOpenMs=%.1f readIoMs=%.1f maxReadMs=%.1f slowOpen2s=%d slowRead2s=%d slow500=%d slow1s=%d slow2s=%d maxInFlight=%d enters=%d exits=%d",
              String(sourceId.prefix(8)), kind.rawValue, chunkIndex,
              success ? 1 : 0, elapsed, manager.lastScannerIdentity, passes.count, scanned,
              elapsed > 0 ? Double(scanned) / elapsed : 0,
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

    private func runCanonical(_ state: PerSource, sourceId: String, mountPath: String) {
        state.pipelineActive = true
        state.phase = .rescan
        emitProgress(sourceId, state)
        workQueue.async { [weak self] in
            guard let self else { return }
            self.semaphore.wait()
            defer { self.semaphore.signal() }
            guard !state.paused, !state.cancelled else {
                self.decisionQueue.async { state.pipelineActive = false }
                return
            }
            let source = try? state.session.scanOnline(mountPath: mountPath, timeout: 3600)
            self.decisionQueue.async { [weak self] in
                guard let self else { return }
                state.pipelineActive = false
                if source != nil {
                    state.phase = .ready
                    self.cleanupBootstrapChunks(sourceId)
                    state.chunkSources = []
                    state.chunkRoots = []
                    self.scheduleResync(state, sourceId: sourceId, mountPath: mountPath)
                } else if state.mountPath == nil {
                    state.phase = .idle   // 扫描中拔线：块/旧快照保留，等重挂
                } else {
                    state.phase = .paused // 扫描失败：暂停等待重试（用户/周期/唤醒）
                }
                self.emitProgress(sourceId, state)
            }
        }
    }

    private func scheduleResync(_ state: PerSource, sourceId: String, mountPath: String) {
        guard state.resyncTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: decisionQueue)
        timer.schedule(deadline: .now() + budget.resyncInterval, repeating: budget.resyncInterval)
        timer.setEventHandler { [weak self] in
            guard let self, state.mountPath != nil, !state.paused, !state.cancelled else { return }
            self.runCanonical(state, sourceId: sourceId, mountPath: mountPath)
        }
        state.resyncTimer = timer
        timer.resume()
    }

    private func cleanupBootstrapChunks(_ sourceId: String) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: snapshotDirectory.path)) ?? []
        for file in files where file.hasPrefix("\(sourceId).boot.") && file.hasSuffix(".oilfind") {
            try? FileManager.default.removeItem(at: snapshotDirectory.appendingPathComponent(file))
        }
    }

    private func rescheduleAll() {
        for (sourceId, state) in states where state.mountPath != nil && !state.paused {
            beginWork(state, sourceId: sourceId)
        }
    }

    // MARK: - 工具

    /// 已有权威快照（哪怕正在重扫）。面板据此在重扫窗口内继续把源标为在线，
    /// 否则 9 万文件的 NAS 重扫期间所有结果都会灰成「离线」，设置页也不会给重链接入口。
    public func hasCanonicalSnapshot(sourceId: String) -> Bool {
        FileManager.default.fileExists(
            atPath: snapshotDirectory.appendingPathComponent(sourceId + ".oilfind").path)
    }

    private func chunkSourceId(sourceId: String, index: Int) -> String { "\(sourceId)#boot\(index)" }

    /// 顶层真实子目录为块；符号链接跳过（lstat 判 S_IFDIR——symlink 返回 S_IFLNK，天然排除），
    /// 隐藏项不单独成块（收敛扫描仍覆盖）。
    static func enumerateChunks(root: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return names.filter { name in
            guard !name.hasPrefix(".") else { return false }
            var st = stat()
            guard lstat((root + "/" + name), &st) == 0 else { return false }
            return (st.st_mode & S_IFMT) == S_IFDIR
        }.sorted()
    }

    static func loadChunkSource(sourceId: String, displayName: String, chunkIndex: Int,
                                snapshotDirectory: URL) -> SearchSource? {
        let path = snapshotDirectory.appendingPathComponent("\(sourceId).boot.\(chunkIndex).oilfind").path
        guard let store = IndexStore.load(from: path) else { return nil }
        store.write { store.buildHash() }
        return SearchSource(id: "\(sourceId)#boot\(chunkIndex)", displayName: displayName,
                            isOnline: true, store: store)
    }

    /// 从磁盘枚举全部块快照恢复（attach 离线路径用；不依赖挂载点存在）。
    static func restoreChunkSources(sourceId: String, displayName: String,
                                    snapshotDirectory: URL) -> [SearchSource] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: snapshotDirectory.path)) ?? []
        return files.filter { $0.hasPrefix("\(sourceId).boot.") && $0.hasSuffix(".oilfind") }
            .compactMap { file -> SearchSource? in
                guard let index = Int(file.dropFirst("\(sourceId).boot.".count).dropLast(".oilfind".count)) else { return nil }
                return loadChunkSource(sourceId: sourceId, displayName: displayName,
                                       chunkIndex: index, snapshotDirectory: snapshotDirectory)
            }
            .sorted { $0.id < $1.id }
    }

    private func waitUntilReady(_ manager: IndexManager, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var seenActive = false
        while Date() < deadline {
            switch manager.state {
            case .ready: Thread.sleep(forTimeInterval: 0.05); return true
            case .idle: if seenActive { return false }
            case .loading, .scanning: seenActive = true
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return manager.state == .ready
    }

    private func emitProgress(_ sourceId: String, _ state: PerSource) {
        let progress = SourceProgress(sourceId: sourceId, displayName: state.displayName,
                                      phase: state.phase, scanned: state.session.scannedCount)
        callbackQueue.async { [weak self] in self?.onProgress?(progress) }
    }
}
