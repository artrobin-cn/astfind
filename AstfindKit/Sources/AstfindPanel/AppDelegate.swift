import AppKit
import Carbon
import ServiceManagement
import os
import OilFindCore

enum AppLog {
    static let logger = Logger(subsystem: "com.oiloil.find", category: "app")
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, FinderServiceDelegate {
    private let externalDrives: ExternalDriveCatalog
    private let appExtension: ApplicationExtension?
    init(appExtension: ApplicationExtension? = nil, externalDrives: ExternalDriveCatalog = ExternalDriveCatalog()) {
        self.externalDrives = externalDrives
        self.appExtension = appExtension
        super.init()
        // 服务可能用于冷启动（Astfind 未运行时从 Finder 右键触发）：provider 必须在 finishLaunching
        // 处理 Services AppleEvent 之前就注册；放在 init 里是最早的安全点。
        finderService.delegate = self
        NSApplication.shared.servicesProvider = finderService
    }
    private let panel = SearchPanel()
    private let finderService = FinderServiceProvider()
    private var pendingFinderServiceURL: URL?
    private var finderServiceReady = false
    private let topics = AITopicManager()
    private lazy var topicSearch = AITopicSearchProvider(manager: topics)
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var settingsItem: NSMenuItem?, extensionItem: NSMenuItem?
    private var localizedMenuItems: [(String, NSMenuItem)] = []
    private var languageObserver: NSObjectProtocol?
    private var workspaceObserver: NSObjectProtocol?
    private var hotKey: HotKey?
    private var manager: IndexManager?
    private var settingsController: SettingsWindowController?
    private var updateItem: NSMenuItem?, checkUpdateItem: NSMenuItem?, quitItem: NSMenuItem?
    private var secondaryInstance = false
    private var openItem: NSMenuItem?, hotKeyFailureItem: NSMenuItem?
    private var permissionTimer: Timer?
    private var welcomeController: WelcomeWindowController?
    private var welcomeState: WelcomeState?
    private var indexStateStartedAt = ProcessInfo.processInfo.systemUptime
    private var limited = false
    private var countItem: NSMenuItem?, limitedItem: NSMenuItem?, loginItem: NSMenuItem?, rescanItem: NSMenuItem?
    static let dbURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Astfind/index.oilfind")
    private static let showRequest = Notification.Name("com.oiloil.find.show")
    func applicationDidFinishLaunching(_ notification: Notification) {
        LegacyAuthorizationCleanup.run()
        DispatchQueue.global(qos: .utility).async { _ = Pinyin.shared }
        if let id = Bundle.main.bundleIdentifier, NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            secondaryInstance = true
            DistributedNotificationCenter.default().postNotificationName(Self.showRequest, object: nil, userInfo: nil, deliverImmediately: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
            return
        }
        // ADR-121: 上游更新器已禁用（Astfind 走自建渠道，0.4.1 起启用；未配置
        // AstfindUpdateFeedURL 时 UpdateManager 零网络，设置页/菜单更新入口隐藏——
        // 绝不请求上游 find.oiloil.org appcast）
        UpdateManager.shared.start()
        UpdateManager.shared.onChange = { [weak self] in self?.refreshUpdateMenu() }
        NSApp.setActivationPolicy(.accessory)
        // Finder → 服务/快速操作 → 在 Astfind 中找相似（NSServices 入口）。
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(reopenRequested(_:)), name: Self.showRequest, object: nil)
        let defaults = UserDefaults.standard
        let key = (defaults.object(forKey: "hotKeyCode") as? NSNumber)?.uint32Value ?? UInt32(kVK_ANSI_F)
        let modifiers = (defaults.object(forKey: "hotKeyModifiers") as? NSNumber)?.uint32Value ?? Shortcut.astfindModifiers
        hotKey = HotKey(keyCode: key, modifiers: modifiers) { [weak self] in self?.handleHotKey() }
        buildMenu(keyCode: key, modifiers: modifiers)
        panel.searchController.supplementaryProvider = appExtension?.supplementarySearchProvider
        // M0.6：QuickLook 可见期间产生前台活动信号（不触碰 M0.7 独占的 SearchViewController 逻辑）。
        panel.searchController.quickLook.onVisibilityChanged = { [weak self] visible in
            self?.appExtension?.quickLookVisibilityChanged(visible)
        }
        // M0.6b：Preview/QuickTime 在前台时保持后台暂停；不把 Finder 常驻前台当作读取。
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] _ in
            self?.refreshExternalAppActivity()
        }
        refreshExternalAppActivity()
        panel.searchController.sourceReachability = { [weak self] source in
            self?.appExtension?.isSourceReachable(source) ?? true
        }
        panel.searchController.additionalSearchProvider = topicSearch
        topics.start()
        panel.searchController.additionalSources = { [weak self] in (self?.externalDrives.searchSources() ?? []) + (self?.appExtension?.searchSources() ?? []) }
        let sourcesChanged: () -> Void = { [weak self] in
            self?.panel.searchController.sourcesChanged()
            self?.settingsController?.model.refresh()
        }
        externalDrives.onSourcesChange = sourcesChanged
        appExtension?.onSearchSourcesChange = sourcesChanged
        appExtension?.attachExternalDrives(externalDrives)
        externalDrives.start()
        appExtension?.start(chinese: L10n.chinese, showSettings: { [weak self] in self?.presentSettings() })
        panel.searchController.onSettings = { [weak self] in self?.showSettings() }
        let fullDiskAccess = Permissions.hasFullDiskAccess()
        var state = WelcomeState(didFinishOnboarding: defaults.bool(forKey: "didFinishOnboarding"), skippedFullDiskAccess: defaults.bool(forKey: "skippedFullDiskAccess"), granted: fullDiskAccess)
        let indexRequest = state.launch()
        welcomeState = state
        AppLog.logger.info("launch hotkeyRegistered=\(self.hotKey != nil, privacy: .public) granted=\(fullDiskAccess, privacy: .public) welcome=\(state.isShowing, privacy: .public)")
        if state.isShowing {
            let controller = WelcomeWindowController(granted: fullDiskAccess)
            welcomeController = controller
            controller.model.onStart = { [weak self] in self?.finishWelcome() }
            controller.model.onSettings = { [weak self] in self?.showSettings() }
            controller.present()
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                guard let self else { return }
                let granted = Permissions.hasFullDiskAccess()
                self.welcomeController?.model.granted = granted
                if granted { self.welcomeController?.model.waiting = false }
                if let limited = self.welcomeState?.permissionDetected(granted) { self.startIndex(limited: limited) }
            }
        }
        if let limited = indexRequest { startIndex(limited: limited) }
        if let failure = SystemUpdateFiles().cleanupAfterLaunch(application: Bundle.main.bundleURL, current: UpdateManager.current) {
            UpdateManager.shared.reportLaunchFailure(failure)
        }
        finderServiceReady = true
        if let pending = pendingFinderServiceURL {
            pendingFinderServiceURL = nil
            handleFinderServiceURL(pending)
        }
    }
    private func finishWelcome(source: PanelSource = .welcome) {
        guard welcomeState?.isShowing == true else { return }
        let detected = welcomeState?.permissionDetected(Permissions.hasFullDiskAccess())
        let finished = welcomeState?.finish()
        let request = detected ?? finished
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "didFinishOnboarding")
        defaults.set(welcomeState?.skippedFullDiskAccess == true, forKey: "skippedFullDiskAccess")
        permissionTimer?.invalidate(); permissionTimer = nil
        welcomeController?.finish(); welcomeController = nil
        if let limited = request { startIndex(limited: limited) }
        panel.show(source: source)
    }
    private func handleHotKey() {
        if welcomeState?.isShowing == true { finishWelcome(source: .hotkey) }
        else { panel.toggle(source: .hotkey) }
    }

    private func startIndex(limited: Bool) {
        guard manager == nil else { return }
        self.limited = limited
        let manager = IndexManager(config: SettingsPreferences.indexConfig(limited: limited), dbURL: Self.dbURL)
        self.manager = manager; panel.searchController.manager = manager
        settingsController?.model.manager = manager
        appExtension?.attachPrimaryIndex(manager)   // 本机内容范围：零双扫登记资产 + 变化驱动重同步
        panel.searchController.setState(.indexing)
        panel.searchController.searchField.focus()
        indexStateStartedAt = ProcessInfo.processInfo.systemUptime
        manager.onStateChange = { [weak self, weak manager] state in
            guard let self, let manager else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let count = manager.store.map { store in store.read { store.liveCount } } ?? manager.scannedCount
            let name = String(describing: state)
            AppLog.logger.info("index state=\(name, privacy: .public) entries=\(count, privacy: .public) elapsed=\(now - self.indexStateStartedAt, privacy: .public)s")
            self.indexStateStartedAt = now
            self.panel.searchController.managerStateChanged(state)
            if state == .scanning && self.welcomeState?.isShowing != true { self.panel.show(source: .indexing) }
        }
        manager.onIndexChange = { [weak self] in self?.panel.searchController.indexChanged() }
        manager.start()
    }
    private func buildMenu(keyCode: UInt32, modifiers: UInt32) {
        statusItem = NSStatusBar.system.statusItem(withLength: MenuBarIcon.statusItemLength)
        statusItem?.button?.image = MenuBarIcon.image
        statusItem?.menu = makeMenu(keyCode: keyCode, modifiers: modifiers, hotKeyAvailable: hotKey != nil)
    }
    func makeMenu(keyCode: UInt32 = UInt32(kVK_ANSI_F), modifiers: UInt32 = Shortcut.astfindModifiers, hotKeyAvailable: Bool = true) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false; menu.delegate = self
        statusMenu = menu
        localizedMenuItems.removeAll()
        extensionItem = nil
        func item(_ key: String, _ action: Selector?, _ equivalent: String = "") -> NSMenuItem {
            let value = NSMenuItem(title: L10n.text(key), action: action, keyEquivalent: equivalent)
            value.target = self; value.isEnabled = action != nil; menu.addItem(value)
            localizedMenuItems.append((key, value)); return value
        }
        hotKeyFailureItem = item("menu.hotkeyFailed", nil)
        hotKeyFailureItem?.isHidden = hotKeyAvailable
        openItem = item("menu.open", #selector(showSearch), Shortcut.keyEquivalent(keyCode))
        openItem?.keyEquivalentModifierMask = HotKey.modifierFlags(modifiers)
        menu.addItem(.separator())
        countItem = item("menu.indexing", nil)
        limitedItem = item("menu.limited", #selector(openPermissions))
        rescanItem = item("menu.rescan", #selector(rescan))
        menu.addItem(.separator())
        loginItem = item("menu.loginItem", #selector(toggleLogin))
        settingsItem = item("menu.settings", #selector(showSettings), ",")
        refreshExtensionMenu()
        checkUpdateItem = item("update.check", #selector(checkUpdates))
        updateItem = item("update.check", #selector(presentUpdate))
        refreshUpdateMenu()
        menu.addItem(.separator()); quitItem = item("menu.quit", #selector(quit), "q")
        appExtension?.onSettingsMenuItemChange = { [weak self] in self?.refreshExtensionMenu() }
        if languageObserver == nil {
            languageObserver = NotificationCenter.default.addObserver(forName: L10n.changed, object: nil, queue: .main) { [weak self] _ in
                self?.appExtension?.languageDidChange(chinese: L10n.chinese)
                self?.localizeMenu()
            }
        }
        return menu
    }
    private func localizeMenu() {
        for (key, item) in localizedMenuItems { item.title = L10n.text(key) }
        if let menu = statusMenu { menuWillOpen(menu) }
        refreshUpdateMenu()
    }
    private func registerHotKey(keyCode: UInt32, modifiers: UInt32) -> Bool {
        hotKey?.unregister()
        hotKey = HotKey(keyCode: keyCode, modifiers: modifiers) { [weak self] in self?.handleHotKey() }
        hotKeyFailureItem?.isHidden = hotKey != nil
        if hotKey != nil {
            openItem?.keyEquivalent = Shortcut.keyEquivalent(keyCode)
            openItem?.keyEquivalentModifierMask = HotKey.modifierFlags(modifiers)
        }
        if hotKey != nil { welcomeController?.model.updateShortcut(keyCode, modifiers) }
        return hotKey != nil
    }
    @objc func showSettings() { presentSettings() }
    private func presentSettings() {
        topics.refreshProviderAvailability()
        panel.hide(source: .settings)
        NSApp.activate(ignoringOtherApps: true)
        if settingsController == nil {
            let model = SettingsModel(topics: topics); model.manager = manager
            model.suspendHotKey = { [weak self] in self?.hotKey?.unregister(); self?.hotKey = nil }
            model.registerHotKey = { [weak self] code, mask in self?.registerHotKey(keyCode: code, modifiers: mask) ?? false }
            model.onConfigChange = { [weak self] in
                guard let self else { return }
                self.manager?.updateConfig(SettingsPreferences.indexConfig(limited: self.limited))
            }
            model.onPinyinChange = { [weak self] in self?.panel.searchController.startSearch(preserveSelection: true) }
            settingsController = SettingsWindowController(model: model, appExtension: appExtension, externalDrives: externalDrives)
        }
        settingsController?.present()
    }
    func menuWillOpen(_ menu: NSMenu) {
        refreshExtensionMenu()
        refreshUpdateMenu()
        if let store = manager?.store { countItem?.title = L10n.text("menu.indexed", Presentation.countText(store.read { store.liveCount })) }
        else { countItem?.title = L10n.text("menu.indexing") }
        limitedItem?.isHidden = !limited
        rescanItem?.isEnabled = manager?.state == .ready && manager?.isRescanning == false
        loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
    private func refreshExtensionMenu() {
        guard let menu = statusMenu, let settingsItem else { return }
        guard let supplied = appExtension?.settingsMenuItem else {
            if let extensionItem { menu.removeItem(extensionItem) }
            extensionItem = nil
            return
        }
        if extensionItem == nil {
            let item = NSMenuItem(title: supplied.title, action: #selector(performExtensionMenuAction), keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: menu.index(of: settingsItem) + 1)
            extensionItem = item
        }
        extensionItem?.title = supplied.title
        extensionItem?.isHidden = !supplied.isVisible
    }
    @objc private func performExtensionMenuAction() { appExtension?.settingsMenuItem?.action() }
    private func refreshUpdateMenu() {
        let update = UpdateManager.shared
        checkUpdateItem?.isHidden = !UpdateManager.channelConfigured
        checkUpdateItem?.isEnabled = update.canCheck
        updateItem?.isHidden = update.manifest == nil
        updateItem?.title = update.menuTitle
        updateItem?.isEnabled = !update.state.busy
        quitItem?.isEnabled = !update.preventsTermination
    }
    @objc private func checkUpdates() { UpdateManager.shared.check() }
    @objc private func presentUpdate() { UpdateManager.shared.present() }
    @objc private func showSearch() {
        if welcomeState?.isShowing == true { welcomeController?.present() }
        else { panel.show(source: .menu) }
    }
    @objc private func reopenRequested(_ notification: Notification) {
        AppLog.logger.info("reopen requested")
        if welcomeState?.isShowing == true { welcomeController?.present() }
        else { panel.show(source: .reopen) }
    }

    // MARK: - Finder Service（方案 A：NSServices，不做 Finder Sync 扩展）

    func finderService(_ service: FinderServiceProvider, findSimilar url: URL) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.finderServiceReady else {
                // 冷启动时 Services 事件可能早于 applicationDidFinishLaunching：先排队，
                // 等补充 Provider / 面板接线完成后再发起图片查询。
                self.pendingFinderServiceURL = url
                return
            }
            self.handleFinderServiceURL(url)
        }
    }

    private func handleFinderServiceURL(_ url: URL) {
        AppLog.logger.info("finder service find-similar")
        if welcomeState?.isShowing == true { finishWelcome(source: .interaction) }
        panel.searchController.prepareFinderServiceImage(url)
        panel.show(source: .interaction)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        reopenRequested(Notification(name: Self.showRequest)); return true
    }
    @objc private func openPermissions() { Permissions.openSettings() }
    @objc private func rescan() { manager?.rescan() }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSSound.beep() }
        loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        UpdateManager.shared.preventsTermination ? .terminateCancel : .terminateNow
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { appExtension?.handle(url) }
    }
    /// 只把会读取原文件的预览/播放器当作外部前台活动；Finder 浏览不常驻暂停。
    private func refreshExternalAppActivity() {
        let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let active = id == "com.apple.Preview"
            || id == "com.apple.QuickTimePlayerX"
            || id == "com.apple.QuickTimePlayer"
        appExtension?.setExternalAppActive(active)
    }

    func applicationWillTerminate(_ notification: Notification) { if !secondaryInstance { topics.stop(); appExtension?.stop(); externalDrives.stop(); UpdateManager.shared.stop() }; settingsController?.model.stopRefreshing(); permissionTimer?.invalidate(); hotKey?.unregister(); manager?.stop() }
    deinit {
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
    }
}
