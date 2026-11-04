import Foundation
import OilFindCore

/// M0.6 调度接线：把来源类型、用户开关和前台活动组合成每个 Scanner 的 Pacer 策略。
///
/// - 仅 SMB 来源创建 `ScanPacer`；本地/外置盘返回 nil，零等待直通。
/// - 开关在运行中关闭时唤醒等待者，下一个安全检查点恢复全速。
/// - 状态通知只反映“实际有 SMB 扫描进入降速”，供设置页显示。
final class ScanPacingController: @unchecked Sendable {
    private let coordinator: ForegroundActivityCoordinator
    private let enabledProvider: () -> Bool
    private let suspendedProvider: (() -> Bool)?
    private let notificationCenter: NotificationCenter
    private let lock = NSLock()
    private var throttledPacers: Set<UUID> = []
    private var pacers: [UUID: WeakPacer] = [:]
    private var preferenceObserver: NSObjectProtocol?
    private(set) var createdPacerKinds: [SourceRecord.Kind] = []

    private struct WeakPacer {
        weak var value: ScanPacer?
    }

    init(coordinator: ForegroundActivityCoordinator,
         enabledProvider: @escaping () -> Bool = { ScanPacingPreferences.isEnabled() },
         suspendedProvider: (() -> Bool)? = nil,
         notificationCenter: NotificationCenter = .default) {
        self.coordinator = coordinator
        self.enabledProvider = enabledProvider
        self.suspendedProvider = suspendedProvider
        self.notificationCenter = notificationCenter
        preferenceObserver = notificationCenter.addObserver(
            forName: ScanPacingPreferences.changed, object: nil, queue: nil) { [weak self] _ in
            self?.preferenceChanged()
        }
    }

    deinit {
        if let preferenceObserver { notificationCenter.removeObserver(preferenceObserver) }
    }

    var isThrottled: Bool {
        lock.lock(); defer { lock.unlock() }
        return !throttledPacers.isEmpty
    }

    /// 每个 Scanner 实例调用一次；调用方保证在 `Scanner.run()` 前安装。
    /// 验收标定用参数覆盖；生产默认 25ms / 250ms / 单在飞。
    /// 只影响新创建的 Pacer，不改变已运行的扫描。
    private struct Tuning {
        var batchInterval: TimeInterval
        var maximumWait: TimeInterval
        var maxConcurrentIO: Int
        var intervalScope: ScanPacer.Configuration.IntervalScope
    }

    private static func tuning() -> Tuning {
        let env = ProcessInfo.processInfo.environment
        func number(_ key: String, _ fallback: Double) -> Double {
            guard let raw = env[key], let value = Double(raw), value.isFinite else { return fallback }
            return value
        }
        let scope: ScanPacer.Configuration.IntervalScope =
            env["ASTFIND_M06_INTERVAL_SCOPE"] == "batch" ? .perDirectoryBatch : .perPermit
        return Tuning(
            batchInterval: min(1.0, max(0, number("ASTFIND_M06_BATCH_MS", 25) / 1000)),
            maximumWait: min(5.0, max(0, number("ASTFIND_M06_MAX_WAIT_MS", 250) / 1000)),
            maxConcurrentIO: min(4, max(1, Int(number("ASTFIND_M06_MAX_IN_FLIGHT", 1)))),
            intervalScope: scope)
    }

    func makePacer(for kind: SourceRecord.Kind, sourceId: String) -> ScanPacing? {
        lock.lock()
        createdPacerKinds.append(kind)
        if createdPacerKinds.count > 128 { createdPacerKinds.removeFirst(createdPacerKinds.count - 128) }
        lock.unlock()

        guard kind == .smb else { return nil }
        let id = UUID()
        let tuning = Self.tuning()
        let pacer = ScanPacer(.init(
            batchInterval: tuning.batchInterval,
            maximumWait: tuning.maximumWait,
            maxConcurrentIO: tuning.maxConcurrentIO,
            intervalScope: tuning.intervalScope,
            isThrottled: { [weak self] in self?.isActuallyThrottled ?? false },
            isSuspended: { [weak self] in self?.isActuallySuspended ?? false },
            onThrottleChange: { [weak self] throttled in
                self?.updateThrottle(id: id, sourceId: sourceId, throttled: throttled)
            }))
        NSLog("astfind pacer create source=%@ pacer=%@ batchMs=%d maxWaitMs=%d maxInFlight=%d intervalScope=%@",
              String(sourceId.prefix(8)), String(id.uuidString.prefix(8)),
              Int((tuning.batchInterval * 1000).rounded()),
              Int((tuning.maximumWait * 1000).rounded()), tuning.maxConcurrentIO,
              tuning.intervalScope.rawValue)
        lock.lock()
        if pacers.count > 32 { pacers = pacers.filter { $0.value.value != nil } }
        pacers[id] = WeakPacer(value: pacer)
        lock.unlock()
        return pacer
    }

    private func preferenceChanged() {
        lock.lock()
        let live = pacers.compactMap(\.value.value)
        pacers = pacers.filter { $0.value.value != nil }
        lock.unlock()
        if enabledProvider() {
            for pacer in live { pacer.wake() }
        } else {
            // 逐个撤销本地状态；回调会清理 controller 状态并通知设置页。
            for pacer in live { pacer.forceThrottleOff() }
            lock.lock()
            let changed = !throttledPacers.isEmpty
            throttledPacers.removeAll()
            lock.unlock()
            let globalChanged = ScanPacingStatus.update(false)
            if changed || globalChanged {
                NotificationCenter.default.post(name: ScanPacingPreferences.statusChanged, object: nil,
                                                userInfo: [ScanPacingPreferences.statusKey: false])
            }
        }
    }

    /// 交互状态变化时唤醒所有等待中的 Pacer；暂停/恢复不取消扫描。
    func wakeAll() {
        lock.lock()
        let live = pacers.compactMap(\.value.value)
        pacers = pacers.filter { $0.value.value != nil }
        lock.unlock()
        for pacer in live { pacer.wake() }
    }

    private var isActuallyThrottled: Bool {
        enabledProvider() && coordinator.isInteractive
    }

    private var isActuallySuspended: Bool {
        if let suspendedProvider { return enabledProvider() && suspendedProvider() }
        return enabledProvider() && coordinator.isInteractive
    }

    private func updateThrottle(id: UUID, sourceId: String, throttled: Bool) {
        lock.lock()
        let changed: Bool
        if throttled {
            changed = throttledPacers.insert(id).inserted
        } else {
            changed = throttledPacers.remove(id) != nil
        }
        let current = !throttledPacers.isEmpty
        lock.unlock()
        let globalChanged = ScanPacingStatus.update(current)
        guard changed || globalChanged else { return }
        let prefix = String(sourceId.prefix(8))
        NSLog("astfind pacer %@ source=%@ pacer=%@ active=%d",
              throttled ? "enter" : "exit", prefix, String(id.uuidString.prefix(8)),
              current ? 1 : 0)
        NotificationCenter.default.post(name: ScanPacingPreferences.statusChanged, object: nil,
                                        userInfo: [ScanPacingPreferences.statusKey: current])
    }
}
