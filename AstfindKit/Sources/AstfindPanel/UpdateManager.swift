import AppKit
import OilFindCore

enum UpdateState: Equatable {
    case idle, checking, available, downloading(Double), installing, latest, failed(UpdateFailure)
    var busy: Bool {
        switch self { case .checking, .downloading, .installing: return true; default: return false }
    }
    var installing: Bool {
        switch self { case .downloading, .installing: return true; default: return false }
    }
}

final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()
    /// Astfind 自有更新清单（Info.plist `AstfindUpdateFeedURL`，B1 接线时写入）。
    /// 未配置 = 更新渠道未开通：零网络请求，设置页与菜单的更新入口随之隐藏——
    /// 绝不回退到上游 `find.oiloil.org`（那是 Oil Find 的 appcast，会把上游版本
    /// 当成 Astfind 更新推给用户，2026-10-22 实弹翻车）。
    static let feedURL: URL? = {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "AstfindUpdateFeedURL") as? String,
              let url = URL(string: text), url.scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }()
    /// Astfind 官网（Info.plist `AstfindWebsiteURL`）。
    /// 未配置 = 不展示入口——同样绝不回退上游站点，避免把用户引到别的产品的下载页。
    static let websiteURL: URL? = {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "AstfindWebsiteURL") as? String,
              let url = URL(string: text), url.scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }()
    /// Astfind 自己的更新包身份（必须与 Info.plist 的 bundle ID / 可执行文件名一致）。
    static let applicationIdentity = UpdateApplicationIdentity.astfind
    static var channelConfigured: Bool { feedURL != nil }
    static var current: UpdateVersion {
        UpdateVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.3.0",
                      build: Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "7") ?? 7)
            ?? UpdateVersion("1.3.0", build: 7)!
    }
    @Published private(set) var state: UpdateState = .idle
    @Published private(set) var manifest: UpdateManifest?
    @Published var automatic: Bool { didSet { if !snapshot { preferences.automatic = automatic; schedule() } } }
    var onChange: (() -> Void)?
    private let preferences: UpdatePreferences
    let runningVersion: UpdateVersion
    private let snapshot: Bool
    private var timer: Timer?
    private var windowController: UpdateWindowController?
    private var started = false
    private var readyToRelaunch = false
    var preventsTermination: Bool { state.installing && !readyToRelaunch }
    var canCheck: Bool {
        #if DEBUG
        return false
        #else
        return Self.channelConfigured && !state.busy
        #endif
    }
    init(snapshot: Bool = false, preferences: UpdatePreferences = UpdatePreferences(), current: UpdateVersion = UpdateManager.current) {
        self.snapshot = snapshot; self.preferences = preferences
        runningVersion = current
        automatic = snapshot ? true : preferences.automatic
    }
    func start() {
        #if !DEBUG
        started = true; schedule(delay: 30)
        #endif
    }
    func stop() { timer?.invalidate(); timer = nil; started = false }
    private func schedule(delay: TimeInterval = 86_400) {
        timer?.invalidate(); timer = nil
        guard started, automatic else { return }
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.check(manual: false); self?.schedule()
        }
    }
    func check(manual: Bool = true) {
        #if !DEBUG
        guard let feed = Self.feedURL, !snapshot, !state.busy else { return }
        setState(.checking)
        Task { @MainActor in
            do {
                let latest = try await UpdateClient(version: Self.current.version.text, manifestURL: feed).check()
                if preferences.shouldOffer(latest, current: Self.current, system: ProcessInfo.processInfo.operatingSystemVersion, manual: manual) {
                    manifest = latest; setState(.available); present()
                } else if manual {
                    manifest = nil; setState(.latest); present()
                } else {
                    setState(manifest == nil ? .idle : .available)
                }
            } catch {
                if manual { setState(.failed((error as? UpdateFailure) ?? .other)); present() }
                else { setState(manifest == nil ? .idle : .available) }
            }
        }
        #endif
    }
    func present() {
        if windowController == nil { windowController = UpdateWindowController(model: self) }
        NSApp.activate(ignoringOtherApps: true)
        windowController?.present()
    }
    func dismiss() { windowController?.close() }
    func skip() {
        guard let manifest, !state.busy else { return }
        if !snapshot { preferences.skip(manifest) }
        self.manifest = nil; setState(.idle); dismiss()
    }
    func install() {
        #if !DEBUG
        guard let manifest, let feed = Self.feedURL, !state.busy, !snapshot else { return }
        readyToRelaunch = false
        setState(.downloading(0))
        let current = Self.current, application = Bundle.main.bundleURL
        let identity = Self.applicationIdentity
        Task { @MainActor in
            var archive: URL?
            defer { if let archive { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) } }
            do {
                let client = UpdateClient(version: current.version.text, manifestURL: feed)
                let downloaded = try await client.download(manifest) { [weak self] fraction in
                    DispatchQueue.main.async {
                        if case .downloading = self?.state { self?.setState(.downloading(fraction)) }
                    }
                }
                archive = downloaded; setState(.installing)
                let installation = try await Task.detached(priority: .utility) {
                    try UpdateInstaller(application: application, current: current,
                                        files: SystemUpdateFiles(identity: identity))
                        .install(archive: downloaded, manifest: manifest)
                }.value
                // NSApplication.terminate can exit without unwinding the async task.
                try? FileManager.default.removeItem(at: downloaded.deletingLastPathComponent())
                archive = nil
                do {
                    try UpdateRelauncher().startWaiting(for: ProcessInfo.processInfo.processIdentifier,
                                                        installation: installation,
                                                        executableName: identity.executableName)
                } catch {
                    try UpdateInstaller(application: application, current: current,
                                        files: SystemUpdateFiles(identity: identity)).rollback(installation)
                    throw UpdateFailure.other
                }
                readyToRelaunch = true
                NSApp.terminate(nil)
            } catch { setState(.failed((error as? UpdateFailure) ?? .other)) }
        }
        #endif
    }
    func openWebsite() {
        guard let url = Self.websiteURL else { return }
        NSWorkspace.shared.open(url)
    }
    func reportLaunchFailure(_ failure: UpdateFailure) { setState(.failed(failure)); present() }
    private func setState(_ value: UpdateState) { state = value; onChange?() }
    var menuTitle: String {
        switch state {
        case .downloading(let fraction): return L10n.text("update.downloading", Self.percent(fraction))
        case .installing: return L10n.text("update.installing")
        default: return manifest.map { L10n.text("update.menuAvailable", $0.version) } ?? L10n.text("update.check")
        }
    }
    static func percent(_ fraction: Double) -> String { "\(Int(fraction * 100))%" }
    #if DEBUG
    func prepareSnapshot(_ state: UpdateState, manifest: UpdateManifest?) { self.manifest = manifest; setState(state) }
    #endif
    deinit { timer?.invalidate() }
}
