import Foundation

/// 扫描 I/O 节流策略（M0.6）。只有 `Scanner` 在安全检查点调用；
/// 协议本身不依赖 AppKit，也不知道来源类型或设置页。
///
/// - `beginIO()` 在目录 `open` / 目录批量读取前调用；返回 `false` 表示扫描已取消，
///   调用方不得再发起系统调用。
/// - `endIO()` 必须在系统调用结束后的所有路径（成功、错误、取消）调用。
/// - `cancel()` 用于停止扫描时唤醒所有等待者，语义与 `Scanner.cancel()` 对齐。
/// - `wake()` 让等待者重新评估当前策略（交互结束/开关关闭），不取消扫描。
public protocol ScanPacing: AnyObject {
    func beginIO() -> Bool
    func endIO()
    func cancel()
    func wake()
    /// 诊断：记录一次成功的目录批量读取（不影响调度）。
    func noteDirectoryBatch()
    /// 诊断：记录一次实际系统调用的耗时（成功、失败、取消路径都应记录）。
    func noteIODuration(_ duration: TimeInterval)
    /// 诊断：分别记录目录 open 与目录批量读取耗时。
    func noteOpenDuration(_ duration: TimeInterval)
    func noteReadDuration(_ duration: TimeInterval)
}

public extension ScanPacing {
    func noteDirectoryBatch() { }
    func noteIODuration(_ duration: TimeInterval) { }
    func noteOpenDuration(_ duration: TimeInterval) { }
    func noteReadDuration(_ duration: TimeInterval) { }
}

public struct ScanPacerMetrics: Equatable, Sendable {
    /// 实际放行的 I/O 次数。
    public var permits = 0
    /// 进入交互节流后调用 `beginIO` 的次数。
    public var throttledCalls = 0
    /// Pacer 主动引入的批次间隔等待（秒），不含系统调用阻塞。
    public var artificialWait: TimeInterval = 0
    /// 等待同实例其他在飞 I/O 结束的时间（秒），用于诊断，不算主动降速。
    public var permitWait: TimeInterval = 0
    /// 因交互暂停而等待的时间/次数（B 方案）。
    public var suspendWait: TimeInterval = 0
    public var suspendCount = 0
    /// 实际系统调用耗时总和（秒），由 Scanner 在 open / sift_read_dir 返回后回报。
    public var ioDuration: TimeInterval = 0
    /// 单次系统调用最大耗时（秒）。
    public var maxIODuration: TimeInterval = 0
    /// 目录 open / 批量读取的独立耗时，用于判断尾延迟来源。
    public var openDuration: TimeInterval = 0
    public var maxOpenDuration: TimeInterval = 0
    public var readDuration: TimeInterval = 0
    public var maxReadDuration: TimeInterval = 0
    public var openCount = 0
    public var readCount = 0
    /// 超过 2s 的 open / read 次数。
    public var slowOpen2s = 0
    public var slowRead2s = 0
    /// 超过 500ms / 1s / 2s 的实际系统调用次数，用于定位单请求尾延迟。
    public var slowIO500Count = 0
    public var slowIO1000Count = 0
    public var slowIO2000Count = 0
    /// 单实例最大在飞 I/O 数（诊断用；SMB 交互时应为 1）。
    public var maxInFlight = 0
    /// 成功返回条目的目录批量读取次数。
    public var directoryBatches = 0
    public var throttleEnterCount = 0
    public var throttleExitCount = 0

    public init() {}

    /// 汇总多个 Scanner/pass 的指标；max 类字段取最大值，其余求和。
    public static func + (lhs: ScanPacerMetrics, rhs: ScanPacerMetrics) -> ScanPacerMetrics {
        var result = lhs
        result.permits += rhs.permits
        result.throttledCalls += rhs.throttledCalls
        result.artificialWait += rhs.artificialWait
        result.permitWait += rhs.permitWait
        result.suspendWait += rhs.suspendWait
        result.suspendCount += rhs.suspendCount
        result.ioDuration += rhs.ioDuration
        result.maxIODuration = max(result.maxIODuration, rhs.maxIODuration)
        result.openDuration += rhs.openDuration
        result.maxOpenDuration = max(result.maxOpenDuration, rhs.maxOpenDuration)
        result.readDuration += rhs.readDuration
        result.maxReadDuration = max(result.maxReadDuration, rhs.maxReadDuration)
        result.openCount += rhs.openCount
        result.readCount += rhs.readCount
        result.slowOpen2s += rhs.slowOpen2s
        result.slowRead2s += rhs.slowRead2s
        result.slowIO500Count += rhs.slowIO500Count
        result.slowIO1000Count += rhs.slowIO1000Count
        result.slowIO2000Count += rhs.slowIO2000Count
        result.maxInFlight = max(result.maxInFlight, rhs.maxInFlight)
        result.directoryBatches += rhs.directoryBatches
        result.throttleEnterCount += rhs.throttleEnterCount
        result.throttleExitCount += rhs.throttleExitCount
        return result
    }

    public static func aggregate(_ values: [ScanPacerMetrics]) -> ScanPacerMetrics {
        values.reduce(into: ScanPacerMetrics()) { $0 = $0 + $1 }
    }
}

/// 固定参数安全点节流器。
///
/// 设计约束（PRD FR-11…FR-19）：
/// - 每个 Scanner 独立实例，不共享在飞许可；
/// - 只在安全点等待，绝不持有 Scanner/IndexManager 的锁；
/// - 交互时最多一个 I/O 在飞；非交互时零等待直通；
/// - 批次间隔等待有上限，且可被取消/策略变化唤醒。
public final class ScanPacer: ScanPacing, @unchecked Sendable {
    public struct Configuration {
        public enum IntervalScope: String, Sendable {
            /// 每个 beginIO（目录 open 和每次批量读取）都等待批次间隔。
            case perPermit
            /// 只在目录批量读取之间等待；目录 open 不额外等待。
            case perDirectoryBatch
        }
        /// 交互时两次放行之间的最小间隔。
        public var batchInterval: TimeInterval
        /// Pacer 单次连续主动等待上限；不覆盖内核中不可中断的系统调用。
        public var maximumWait: TimeInterval
        /// 交互时允许的最大在飞 I/O 数；默认 1。验收标定可临时设为 2。
        public var maxConcurrentIO: Int
        /// 批次间隔的作用域；默认保留当前 perPermit 行为，标定可切到 perDirectoryBatch。
        public var intervalScope: IntervalScope
        /// 当前是否应节流（来源为 SMB + 开关开启 + 有效前台活动）。
        public var isThrottled: () -> Bool
        /// B 方案：交互期间是否暂停发放新 I/O；暂停不等于取消。
        public var isSuspended: () -> Bool
        /// 单调时钟；测试注入假时钟。
        public var now: () -> TimeInterval
        /// 进入/退出节流时回调（诊断与状态文案）。
        public var onThrottleChange: ((Bool) -> Void)?

        public init(batchInterval: TimeInterval = 0.025,
                    maximumWait: TimeInterval = 0.25,
                    maxConcurrentIO: Int = 1,
                    intervalScope: IntervalScope = .perPermit,
                    isThrottled: @escaping () -> Bool,
                    isSuspended: @escaping () -> Bool = { false },
                    now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                    onThrottleChange: ((Bool) -> Void)? = nil) {
            self.batchInterval = max(0, batchInterval)
            self.maximumWait = max(0, maximumWait)
            self.maxConcurrentIO = max(1, maxConcurrentIO)
            self.intervalScope = intervalScope
            self.isThrottled = isThrottled
            self.isSuspended = isSuspended
            self.now = now
            self.onThrottleChange = onThrottleChange
        }
    }

    private let configuration: Configuration
    private let condition = NSCondition()
    private var cancelled = false
    private var inFlight = 0
    private var lastPermit: TimeInterval?
    private var lastDirectoryBatch: TimeInterval?
    private var throttleState: Bool?
    private var storedMetrics = ScanPacerMetrics()

    public init(_ configuration: Configuration) {
        self.configuration = configuration
    }

    deinit { cancel() }

    public var metrics: ScanPacerMetrics {
        condition.lock(); defer { condition.unlock() }
        return storedMetrics
    }

    public func beginIO() -> Bool {
        let initialThrottled = configuration.isThrottled()
        guard publishThrottle(initialThrottled) else { return false }

        condition.lock()
        guard !cancelled else { condition.unlock(); return false }

        // B 方案：交互期间暂停发放新 I/O。等待可被 cancel/wake 打断；
        // 分片等待让“面板隐藏 + 8s 宽限结束”后无需额外定时器即可恢复。
        if configuration.isSuspended() {
            storedMetrics.suspendCount += 1
            let began = configuration.now()
            let slice = min(0.25, max(0.05, configuration.maximumWait))
            while !cancelled && configuration.isSuspended() {
                _ = condition.wait(until: Date().addingTimeInterval(slice))
            }
            storedMetrics.suspendWait += max(0, configuration.now() - began)
        }
        guard !cancelled else { condition.unlock(); return false }

        // 恢复后重新评估；交互结束后不再施加 per-permit 间隔/单在飞。
        let throttled = configuration.isThrottled()
        if throttled {
            storedMetrics.throttledCalls += 1

            // 1) 批次间隔：只限制 Pacer 自己发放新工作的节奏，单次等待有上限。
            let intervalBegan = configuration.now()
            let intervalDeadline = intervalBegan + configuration.maximumWait
            while !cancelled {
                guard configuration.isThrottled() else { break }
                let now = configuration.now()
                let reference: TimeInterval?
                switch configuration.intervalScope {
                case .perPermit: reference = lastPermit
                case .perDirectoryBatch: reference = lastDirectoryBatch
                }
                let due = (reference ?? (-Double.infinity)) + configuration.batchInterval
                let remaining = min(due - now, intervalDeadline - now)
                if remaining <= 0 { break }
                _ = condition.wait(until: Date().addingTimeInterval(remaining))
            }
            storedMetrics.artificialWait += max(0, min(configuration.now() - intervalBegan,
                                                       configuration.maximumWait))

            // 2) 单在飞：等待同实例已发放的 I/O 结束。等待的是真实系统调用，
            //    不计入 Pacer 主动降速时长；调用方不持有扫描器锁。
            var permitBegan: TimeInterval?
            while !cancelled && inFlight >= configuration.maxConcurrentIO && configuration.isThrottled() {
                if permitBegan == nil { permitBegan = configuration.now() }
                condition.wait()
            }
            if let permitBegan {
                storedMetrics.permitWait += max(0, configuration.now() - permitBegan)
            }
        }

        guard !cancelled else { condition.unlock(); return false }
        inFlight += 1
        storedMetrics.permits += 1
        storedMetrics.maxInFlight = max(storedMetrics.maxInFlight, inFlight)
        lastPermit = configuration.now()
        condition.unlock()
        return true
    }

    public func endIO() {
        condition.lock()
        if inFlight > 0 { inFlight -= 1 }
        condition.broadcast()
        condition.unlock()
    }

    public func cancel() {
        condition.lock()
        let wasThrottled = throttleState == true
        cancelled = true
        throttleState = false
        if wasThrottled { storedMetrics.throttleExitCount += 1 }
        condition.broadcast()
        condition.unlock()
        if wasThrottled { configuration.onThrottleChange?(false) }
    }

    public func wake() {
        condition.lock()
        condition.broadcast()
        condition.unlock()
    }

    public func noteDirectoryBatch() {
        condition.lock()
        storedMetrics.directoryBatches += 1
        lastDirectoryBatch = configuration.now()
        condition.unlock()
    }

    public func noteIODuration(_ duration: TimeInterval) {
        recordIODuration(duration, kind: nil)
    }

    public func noteOpenDuration(_ duration: TimeInterval) {
        recordIODuration(duration, kind: true)
    }

    public func noteReadDuration(_ duration: TimeInterval) {
        recordIODuration(duration, kind: false)
    }

    private func recordIODuration(_ duration: TimeInterval, kind: Bool?) {
        guard duration.isFinite, duration >= 0 else { return }
        condition.lock()
        storedMetrics.ioDuration += duration
        storedMetrics.maxIODuration = max(storedMetrics.maxIODuration, duration)
        if duration >= 0.5 { storedMetrics.slowIO500Count += 1 }
        if duration >= 1.0 { storedMetrics.slowIO1000Count += 1 }
        if duration >= 2.0 { storedMetrics.slowIO2000Count += 1 }
        if let kind {
            if kind {
                storedMetrics.openDuration += duration
                storedMetrics.maxOpenDuration = max(storedMetrics.maxOpenDuration, duration)
                storedMetrics.openCount += 1
                if duration >= 2.0 { storedMetrics.slowOpen2s += 1 }
            } else {
                storedMetrics.readDuration += duration
                storedMetrics.maxReadDuration = max(storedMetrics.maxReadDuration, duration)
                storedMetrics.readCount += 1
                if duration >= 2.0 { storedMetrics.slowRead2s += 1 }
            }
        }
        condition.unlock()
    }

    /// 开关关闭时立即撤销本地节流状态，确保重新开启后能再次触发 enter。
    public func forceThrottleOff() {
        condition.lock()
        let wasThrottled = throttleState == true
        throttleState = false
        if wasThrottled { storedMetrics.throttleExitCount += 1 }
        condition.broadcast()
        condition.unlock()
        if wasThrottled { configuration.onThrottleChange?(false) }
    }

    @discardableResult
    private func publishThrottle(_ throttled: Bool) -> Bool {
        condition.lock()
        guard !cancelled else { condition.unlock(); return false }
        let previous = throttleState
        throttleState = throttled
        if throttled, previous != true {
            storedMetrics.throttleEnterCount += 1
        } else if !throttled, previous == true {
            storedMetrics.throttleExitCount += 1
        }
        condition.unlock()
        if previous != throttled { configuration.onThrottleChange?(throttled) }
        return true
    }
}

/// 进程内当前是否有 SMB 扫描实际进入降速（设置页首次打开时读取，避免错过 enter 通知）。
public enum ScanPacingStatus {
    private static let lock = NSLock()
    private static var value = false

    public static var isThrottled: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    /// 返回状态是否发生变化；调用方负责发通知。
    @discardableResult
    public static func update(_ newValue: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard value != newValue else { return false }
        value = newValue
        return true
    }
}

/// M0.6 用户开关与状态通知。默认开启；开关关闭后 `ScanPacer` 在下一个安全点恢复直通。
public enum ScanPacingPreferences {
    public static let enabledKey = "astfindSMBInteractionPriority"
    /// 开关变化（供 Pacer 唤醒等待者）。
    public static let changed = Notification.Name("com.oiloil.find.scanPacing.preferenceChanged")
    /// 实际进入/退出降速（供设置页状态文案）。
    public static let statusChanged = Notification.Name("com.oiloil.find.scanPacing.statusChanged")
    public static let statusKey = "throttled"

    public static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: enabledKey) != nil else { return true }
        return defaults.bool(forKey: enabledKey)
    }

    public static func setEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: enabledKey)
        // 验收证据：F 场景必须能直接看到用户关闭开关，而不是只看到 pacer exit。
        NSLog("astfind pacer preference smbInteractionPriority=%@", enabled ? "on" : "off")
        NotificationCenter.default.post(name: changed, object: defaults,
                                        userInfo: [enabledKey: enabled])
    }
}
