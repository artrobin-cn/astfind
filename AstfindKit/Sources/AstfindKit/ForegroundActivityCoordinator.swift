import Foundation

/// 前台活动来源。M0.6 只依赖这个抽象；未来 MCP 活动可增加 `.mcp` 而不改 Scanner。
public enum ForegroundActivity: String, CaseIterable, Sendable {
    case panel
    case search
    case open
    case reveal
    case quickLook
    case mcp
    case externalApp
}

/// 线程安全的前台活动协调器。
///
/// 职责只有“回答当前是否交互、哪些来源活跃、何时截止”：
/// - 不读取文件、不访问 SMB、不调用 Provider；
/// - 不在主线程做同步网络 I/O；
/// - 时间比较使用单调时钟语义，测试可注入时钟。
///
/// 兼容链（PRD FR-6/FR-7）：
/// - 面板显示/隐藏由现有 `setInteractive(visible:typing:)` 映射到 `.panel`/`.search`；
/// - 面板隐藏产生 8 秒宽限，打开/Finder 定位复用该宽限；
/// - QuickLook 由 M0.6 所有的 `QuickLook.swift` 钩子补充，关闭后使用同样的截止机制。
public final class ForegroundActivityCoordinator: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// 面板隐藏后的交互宽限。
        public var panelHideGrace: TimeInterval
        /// QuickLook 关闭后的交互宽限。
        public var quickLookGrace: TimeInterval
        /// 打开/定位等一次性活动的宽限。
        public var activityGrace: TimeInterval

        public init(panelHideGrace: TimeInterval = 8,
                    quickLookGrace: TimeInterval = 8,
                    activityGrace: TimeInterval = 8) {
            self.panelHideGrace = max(0, panelHideGrace)
            self.quickLookGrace = max(0, quickLookGrace)
            self.activityGrace = max(0, activityGrace)
        }
    }

    private let configuration: Configuration
    private let now: () -> TimeInterval
    private let lock = NSLock()
    private var panelVisible = false
    private var searchActive = false
    private var quickLookVisible = false
    private var externalAppActive = false
    private var hideGraceUntil: TimeInterval?
    private var deadlines: [ForegroundActivity: TimeInterval] = [:]
    private var permanent: Set<ForegroundActivity> = []

    public init(configuration: Configuration = Configuration(),
                now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.configuration = configuration
        self.now = now
    }

    /// 面板显示立即生效；隐藏后进入可延长的宽限窗口。
    public func setPanel(visible: Bool) {
        lock.lock()
        if visible {
            panelVisible = true
            hideGraceUntil = nil
        } else {
            panelVisible = false
            searchActive = false
            hideGraceUntil = max(hideGraceUntil ?? 0, now() + configuration.panelHideGrace)
        }
        lock.unlock()
    }

    /// 搜索输入属于持续交互；面板隐藏时由 `setPanel(false)` 一并清除。
    public func setTyping(_ typing: Bool) {
        lock.lock()
        searchActive = typing
        lock.unlock()
    }

    /// QuickLook 可见期间持续交互；关闭后按宽限退出，不依赖主面板是否仍可见。
    public func setQuickLook(visible: Bool) {
        lock.lock()
        quickLookVisible = visible
        if visible {
            permanent.insert(.quickLook)
            deadlines[.quickLook] = nil
        } else {
            permanent.remove(.quickLook)
            deadlines[.quickLook] = max(deadlines[.quickLook] ?? 0,
                                        now() + configuration.quickLookGrace)
        }
        lock.unlock()
    }

    /// 外部预览/播放器（Preview/Finder/QuickTime）在前台时也保持交互；切走后保留宽限。
    public func setExternalAppActive(_ active: Bool) {
        lock.lock()
        externalAppActive = active
        if active {
            deadlines[.externalApp] = nil
        } else {
            deadlines[.externalApp] = max(deadlines[.externalApp] ?? 0,
                                          now() + configuration.activityGrace)
        }
        lock.unlock()
    }

    /// 记录一次打开/定位/MCP 活动。连续活动只会延长，不会缩短已有截止时间。
    public func note(_ activity: ForegroundActivity) {
        guard activity != .panel else { return }
        lock.lock()
        if activity == .search {
            searchActive = true
        } else if activity == .quickLook {
            quickLookVisible = true
            permanent.insert(.quickLook)
            deadlines[.quickLook] = nil
        } else {
            deadlines[activity] = max(deadlines[activity] ?? 0,
                                      now() + configuration.activityGrace)
        }
        lock.unlock()
    }

    /// 结束一次性活动；仍保留一个宽限窗口，让外部应用先完成读取。
    public func end(_ activity: ForegroundActivity) {
        guard activity != .panel else { setPanel(visible: false); return }
        lock.lock()
        if activity == .search {
            searchActive = false
        } else if activity == .quickLook {
            quickLookVisible = false
            permanent.remove(.quickLook)
            deadlines[.quickLook] = max(deadlines[.quickLook] ?? 0,
                                        now() + configuration.quickLookGrace)
        } else {
            permanent.remove(activity)
            deadlines[activity] = max(deadlines[activity] ?? 0,
                                      now() + configuration.activityGrace)
        }
        lock.unlock()
    }

    public var isInteractive: Bool {
        lock.lock(); defer { lock.unlock() }
        if panelVisible || searchActive || quickLookVisible || externalAppActive { return true }
        let current = now()
        if let hideGraceUntil, current < hideGraceUntil { return true }
        return deadlines.values.contains { current < $0 }
    }

    /// 当前活跃来源（诊断用）。quickLook/open/reveal 在宽限内仍算活跃。
    public var activeSources: Set<ForegroundActivity> {
        lock.lock(); defer { lock.unlock() }
        let current = now()
        var result = permanent
        if panelVisible { result.insert(.panel) }
        if searchActive { result.insert(.search) }
        if quickLookVisible { result.insert(.quickLook) }
        if externalAppActive { result.insert(.externalApp) }
        for (activity, deadline) in deadlines where current < deadline {
            result.insert(activity)
        }
        return result
    }

    /// 测试/生命周期复位；不用于常规交互路径。
    public func reset() {
        lock.lock()
        panelVisible = false; searchActive = false; quickLookVisible = false
        externalAppActive = false
        hideGraceUntil = nil; deadlines.removeAll(); permanent.removeAll()
        lock.unlock()
    }
}
