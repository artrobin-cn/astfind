import Foundation
import Combine
import AppKit
import SwiftUI
import Carbon
import OilFindCore
import AstfindPanel

/// Astfind 在 oil-find App 中的挂载点（D0 验证的公开扩展通道，零侵入上游）。
/// `AppDelegate` 会把 `searchSources()` 并入面板的 additionalSources，
/// 并把 `onSearchSourcesChange` 接到面板刷新——本类只做引擎适配。
///
/// 引擎初始化失败（如数据目录暂被占用）时**绝不静默降级到临时目录**——
/// 那等于把用户数据写进阅后即焚的地方（2026-10-19 SSD 测试丢数据的教训）。
/// 策略：带退避重试；仍失败则无 Astfind 来源运行 + 设置页显式报错横幅。
public final class AstfindAppExtension: ApplicationExtension {
    private var engineBox: AstfindEngine?
    private var engineError: String?
    /// 存储属性（协议默认实现会丢弃 setter）；App 启动后由 AppDelegate 赋值。
    public var onSearchSourcesChange: (() -> Void)?

    public init() {
        seedDefaultHotkey()   // 必须在 AppDelegate 读热键默认值前（本 init 先于 applicationDidFinishLaunching）
        let home = AstfindEngine.defaultHome()
        var lastError: Error?
        for attempt in 0..<3 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.5 * Double(attempt)) }
            if let engine = try? AstfindEngine(home: home) {
                engineBox = engine
                Self.log("engine ready at \(home.path)")
                return
            }
            lastError = NSError(domain: "astfind", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "registry unavailable at \(home.path)"])
        }
        engineError = lastError.map { "\($0.localizedDescription)" } ?? "unknown"
        Self.log("ENGINE INIT FAILED: \(engineError!) — running without Astfind sources (NO fallback temp dir)")
    }

    public func start(chinese: Bool, showSettings: @escaping () -> Void) {
        guard let engine = engineBox else { return }
        engine.onSourcesChange = { [weak self] in
            DispatchQueue.main.async { self?.onSearchSourcesChange?() }
        }
        // 异步语义命中就绪 → 面板重跑当前查询（第二轮走缓存，语义行即时并入）。
        // 复用 sourcesChanged 链路：它本就是「引擎侧世界变了，请面板重跑」的通道。
        engine.onSupplementaryRefresh = { [weak self] in
            DispatchQueue.main.async { self?.onSearchSourcesChange?() }
        }
        engine.start()
        Self.log("app started; content-indexer=\(engine.content != nil) sources=\(engine.sources().map { "\($0.id.prefix(8)):\($0.isOnline)" })")
    }
    /// 内容检索（图片 OCR / 文档全文）接进面板补充通道：文件名先行，内容命中异步追加。
    public var supplementarySearchProvider: SupplementarySearchProvider? { contentProvider }
    private lazy var contentProvider: ContentSupplementaryProvider? = engineBox.map { ContentSupplementaryProvider(engine: $0) }

    /// 面板外置盘 catalog（文件名索引属主）。已启用索引的盘自动建立**内容专用来源**：
    /// 复用 catalog 的索引文件登记资产、只做 OCR/正文抽取（本地推理，零上传）。
    /// catalog 变化（插拔/重扫完成/启停）幂等重同步。
    private var driveCatalog: ExternalDriveCatalogReading?
    private var driveChangesCancellable: AnyCancellable?
    public func attachExternalDrives(_ catalog: ExternalDriveCatalogReading) {
        driveCatalog = catalog
        driveChangesCancellable = catalog.changes.sink { [weak self] in self?.syncDriveContentSources() }
        syncDriveContentSources()
    }
    private func syncDriveContentSources() {
        guard let engine = engineBox, let catalog = driveCatalog else { return }
        for drive in catalog.knownDrives where drive.enabled {
            let storeFile = drive.catalogURL
            DispatchQueue.global(qos: .utility).async { [weak self] in
                do { _ = try engine.ensureContentSource(volumeUUID: drive.id, name: drive.name,
                                                        mountPath: drive.path, storeFile: storeFile) }
                catch { Self.log("content source sync failed for \(drive.name): \(error)") }
                _ = self   // 保持弱引用链可读
            }
        }
    }

    /// 面板主索引（本机盘文件名索引，rootPath="/"）：本机内容范围选择器的资产来源。
    /// 变化驱动的幂等重同步——链在既有 onIndexChange 之后（不吞面板自己的回调），2s 去抖
    /// 合并索引重建期的密集通知；同步走 utility 队列，不碰文件名搜索热路径。
    private var primaryIndex: IndexManager?
    private var localScopeSyncPending: DispatchWorkItem?
    public func attachPrimaryIndex(_ manager: IndexManager) {
        primaryIndex = manager
        let previous = manager.onIndexChange
        manager.onIndexChange = { [weak self] in
            previous?()
            self?.scheduleLocalScopeSync()
        }
        scheduleLocalScopeSync()
    }
    private func scheduleLocalScopeSync() {
        guard engineBox?.localContentScopes().isEmpty == false else { return }
        localScopeSyncPending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let store = self.primaryIndex?.store, let engine = self.engineBox else { return }
            engine.resyncLocalContentScopes(store: store)
        }
        localScopeSyncPending = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: work)
    }

    public func searchSources() -> [SearchSource] {
        guard let engine = engineBox else { return [] }
        let sources = engine.sources()
        // 面板每键/每轮询都拉本方法；逐次写盘曾在索引重建期以 2Hz 刷出近千行。
        // 只在来源状态变化时落一行（插拔/上下线仍可从日志复盘）。
        let description = sources.map { "\($0.id.prefix(8)):\($0.isOnline)" }.joined(separator: ", ")
        if description != lastSourcesDescription {
            lastSourcesDescription = description
            Self.log("sources → [\(description)]")
        }
        return sources
    }
    private var lastSourcesDescription = ""

    /// 面板打开前预检：SMB 服务端失联时宁可提示，也不让 Preview 卡在内核 SMB 重传里。
    public func isSourceReachable(_ source: SearchSource) -> Bool {
        engineBox?.isSourceReachable(source: source) ?? true
    }

    /// M0.6：QuickLook 可见时延长前台活动；关闭后由引擎按宽限退出。
    public func quickLookVisibilityChanged(_ visible: Bool) {
        engineBox?.setQuickLookActive(visible)
    }

    /// Preview/QuickTime 在前台时暂停后台索引；切走后恢复。
    public func setExternalAppActive(_ active: Bool) {
        engineBox?.setExternalAppActive(active)
    }

    /// 首次启动把默认快捷键 ⌥⇧F 写入**应用域**（带一次性种子标志）。
    /// register(defaults:) 注册域方案实测不被热键初始化链路读到（曾致装完唤不出面板）；
    /// 写应用域确定生效，且只在用户未自定义过时写入。
    private func seedDefaultHotkey() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "hotKeyCode") == nil,
              defaults.object(forKey: "hotKeyModifiers") == nil,
              defaults.object(forKey: "astfindHotkeySeeded") == nil else { return }
        defaults.set(NSNumber(value: UInt32(kVK_ANSI_F)), forKey: "hotKeyCode")
        defaults.set(NSNumber(value: Shortcut.astfindModifiers), forKey: "hotKeyModifiers")
        defaults.set(true, forKey: "astfindHotkeySeeded")
        Self.log("seeded default hotkey ⌥⇧F (app domain)")
    }

    /// 轻量诊断日志（排查 GUI 链路；写入 ASTFIND_HOME/debug.log，>256KB 截断防膨胀）。
    static func log(_ message: String) {
        let url = AstfindEngine.defaultHome().appendingPathComponent("debug.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        if let handle = FileHandle(forWritingAtPath: url.path) {
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if fileSize > 262_144 { try? handle.truncate(atOffset: 0) }
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
        // 日志含模式切换/来源 id 等本机状态：仅属主可读。
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func stop() {
        engineBox?.stop()
        Self.log("app stopped")
    }
    public func languageDidChange(chinese: Bool) { }
    public func handle(_ url: URL) { }
    public func settingsSection(window: @escaping () -> NSWindow?) -> AnyView {
        AnyView(AstfindSourceSettings(engine: engineBox, engineError: engineError,
                                      primaryStore: { [weak self] in self?.primaryIndex?.store }))
    }
}

/// 设置页来源清单：标题 + 说明（可添加什么）+ 紧凑列表 + 添加/移除。
/// 布局对齐上游设置窗的间距规范；空态给引导文案而不是把容器撑高。
public struct AstfindSourceSettings: View {
    let engine: AstfindEngine?
    let engineError: String?
    /// 面板主索引当前 store（本机内容范围的资产来源；主索引未就绪时为 nil）
    let primaryStore: () -> IndexStore?
    /// 默认收起：只有用户点开才挂载详情视图（连同轮询一起创建），折叠状态零查询、零重绘。
    @State private var expanded = false
    @State private var sourceCount: Int?
    @State private var statusMessage: String?
    @State private var refreshToken = 0
    @State private var countInFlight = false

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text("统一搜索来源").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if let sourceCount {
                        Text("\(sourceCount) 个来源").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(engine == nil || engineError != nil)
            .accessibilityLabel("统一搜索来源")
            .accessibilityHint(expanded ? "收起来源管理" : "展开来源管理")

            Text("添加本机文件夹、移动硬盘/SSD，或已挂载的 NAS 共享——离线后仍可搜索，重连后自动更新索引。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let engineError {
                Label("Astfind 数据目录不可用：\(engineError)。来源功能未启用，重启应用可重试。", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(8)
                    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            } else {
                HStack(spacing: 12) {
                    Button("添加来源…") { chooseAndAdd() }
                    if let statusMessage {
                        Text(statusMessage).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                }
                if expanded, let engine {
                    SourceSettingsDetail(engine: engine, primaryStore: primaryStore,
                                         sourceCount: $sourceCount, statusMessage: $statusMessage,
                                         refreshToken: refreshToken)
                        .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .onAppear { refreshCount() }
        .onReceive(NotificationCenter.default.publisher(for: .astfindSettingsWillPresent)) { _ in
            expanded = false   // 每次重新打开设置都从收起开始
            refreshCount()
        }
    }

    /// 折叠摘要只读一次来源数（登记表查询，不碰任务表）；之后由详情轮询回写绑定。
    private func refreshCount() {
        guard let engine, !countInFlight else { return }
        countInFlight = true
        DispatchQueue.global(qos: .utility).async {
            let count = engine.records().count
            DispatchQueue.main.async {
                countInFlight = false
                if sourceCount != count { sourceCount = count }
            }
        }
    }

    private func chooseAndAdd() {
        guard let engine else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择要纳入统一搜索的文件夹（本机目录、移动硬盘，或 Finder 里已挂载的 NAS 共享）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let kind: SourceRecord.Kind = url.path.hasPrefix("/Volumes/") ? .external : .local
        do {
            _ = try engine.register(path: url.path, name: url.lastPathComponent, kind: kind, scanNow: false)
            engine.refreshMounts()   // 立即驱动后台扫描（进度由清单实时展示）
            statusMessage = "已添加「\(url.lastPathComponent)」，正在后台建立索引"
        } catch {
            statusMessage = "添加失败：\(error.localizedDescription)"
        }
        refreshCount()
        refreshToken += 1   // 详情若已展开，立即重读而不是等下一次 1.5s 轮询
    }
}

/// 展开后的来源管理详情：轮询只在展开期间存在，折叠即销毁。
private struct SourceSettingsDetail: View {
    let engine: AstfindEngine?
    let primaryStore: () -> IndexStore?
    @Binding var sourceCount: Int?
    @Binding var statusMessage: String?
    let refreshToken: Int
    @State private var records: [SourceRecord] = []
    @State private var localScopes: [SourceRecord] = []
    @State private var scopeMessage: String?
    @State private var loaded = false
    @State private var showProgress = false
    /// 高级端点管理抽屉（默认收起——普通用户不需要看端点列表）
    @State private var showProviders = false
    /// 后台轮询快照：资产数缓存——body 里绝不直查数据库。
    /// 语义入库进度不在这里轮询：它只在「语义模型 → 索引」抽屉展开时由子视图自行查询，
    /// 默认收起时零数据库查询（设置页滚动的卡顿教训，430e788）。
    @State private var assetCounts: [String: Int] = [:]
    @State private var contentPending = 0
    @State private var semanticPending = 0
    @State private var refreshInFlight = false
    /// 视频帧 OCR 开关（默认关；应用域持久化）
    @State private var videoOCR: Bool = UserDefaults.standard.bool(forKey: "astfindVideoOCR")
    /// 正在切换内容索引的来源（清理 pending 可能耗时，避免重复点击）
    @State private var contentToggleBusy: Set<String> = []
    /// M0.8b 人物检索状态（模型/任务/向量数）
    @State private var faceStatus: AstfindEngine.FaceStatus?
    @State private var faceToggleBusy: Set<String> = []
    @State private var faceScopeBusy: Set<String> = []
    @State private var showFaceDeleteConfirm = false
    // A1 Provider 管理（实验）：配置清单 + 探测状态 + 外发授权
    @State private var providerConfigs: [HTTPEmbeddingProvider.Config] = []
    @State private var providerProbeText: [String: String] = [:]   // id → 探测结果摘要
    @State private var allowEgress: Bool = false
    @State private var showAddProvider = false
    @State private var semanticSearch: Bool = UserDefaults.standard.bool(forKey: "astfindSemanticSearch")
    /// 内容索引速度三档（1=省电 2=标准 4=全速）；写应用域持久化，改完下一轮泵即生效
    @State private var lanes: Int = {
        min(4, max(1, UserDefaults.standard.object(forKey: "astfindContentLanes") as? Int ?? 2))
    }()
    // R3 重新链接（PR 式保底）：正在处理的源 + 匹配报告 sheet 状态
    @State private var relinkTarget: SourceRecord?
    @State private var relinkReport: AstfindEngine.RelinkReport?
    @State private var relinkError: String?
    @State private var relinkBusy = false
    /// .default 而非 .common：设置页拖动滚动条/触控板滚动时处于 eventTracking 模式，
    /// 轮询应让路；松手后下一次 tick 自然补上（进度 1.5s 粒度足够）。
    private let refreshTimer = Timer.publish(every: 1.5, on: .main, in: .default).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !loaded {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在读取来源…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else if records.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "externaldrive.badge.plus").foregroundStyle(.secondary)
                    Text("还没有来源。点上方「添加来源…」选择一个文件夹开始。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 16)
                .padding(.horizontal, 10)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            } else {
                VStack(spacing: 0) {
                    ForEach(records) { record in
                        row(record)
                        if record.sourceId != records.last?.sourceId { Divider().padding(.leading, 26) }
                    }
                }
                .padding(.vertical, 2)
                Text("“内容索引”关闭后不再处理新的 OCR、正文和语义任务；已完成结果保留，未处理任务会清理。")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 5)
            }

            if let engine {
                HStack(spacing: 10) {
                    if engine.isSMBScanThrottled {
                        Label("交互优先，后台索引已暂停", systemImage: "pause.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if contentPending + semanticPending > 0 {
                        Label("待索引内容 \(contentPending + semanticPending)", systemImage: "tray.and.arrow.down")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("立即更新") {
                        engine.refreshMounts()
                        engine.kickExtractionPump()
                        engine.kickEmbeddingPump()
                    }
                    .font(.system(size: 11))
                    .controlSize(.small)
                    .help("立即检查来源并恢复/启动后台索引；用户暂停的来源不会被自动恢复")
                }
                .padding(.vertical, 4)
            }

            HStack {
                Text("内容索引速度").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: Binding(
                    get: { lanes },
                    set: { value in
                        lanes = value
                        UserDefaults.standard.set(value, forKey: "astfindContentLanes")
                        engine?.extractionLanes = value
                    })) {
                    Text("省电").tag(1)
                    Text("标准").tag(2)
                    Text("全速").tag(4)
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
            }
            .padding(.top, 4)
            // 视频帧 OCR（L2，默认关——PRD 视频走质量门禁；成本两个数量级于单图，用户知情开启）
            VStack(alignment: .leading, spacing: 3) {
                Toggle(isOn: Binding(
                    get: { videoOCR },
                    set: { value in
                        videoOCR = value
                        engine?.setVideoOCR(enabled: value)
                    })) {
                    Text("视频帧文字识别（mp4 / mov / m4v，实验）").font(.system(size: 11))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                Text("按间隔抽帧做本地 OCR，命中带时间码。每个视频最多识别 120 帧（约 1–2 分钟/视频）；开启后现有来源的视频将排队处理，关闭会清掉未处理的视频任务（已识别结果保留）。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)

            // 抽取进度：再套一层默认收起的抽屉——只有点开才挂载列表、查询任务表。
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { showProgress.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(showProgress ? 90 : 0))
                        Text("内容提取进度").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("内容提取进度")
                .accessibilityHint(showProgress ? "收起提取进度" : "展开提取进度")
                if showProgress, let engine {
                    ExtractionProgressList(engine: engine)
                        .transition(.opacity)
                }
            }

            Divider().padding(.vertical, 2)
            SemanticModelSection(engine: engine, semanticSearch: $semanticSearch, allowEgress: $allowEgress,
                                 onConfigChanged: { providerConfigs = engine?.providers.current.httpEmbeddings ?? [] })
            Divider().padding(.vertical, 2)
            // 高级端点管理默认收起：普通用户只需要上面的语义模型，端点细节按需展开。
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { showProviders.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(showProviders ? 90 : 0))
                        Text("AI 供应商（高级）").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text(providerConfigs.isEmpty ? "无" : "\(providerConfigs.count) 个")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("AI 供应商")
                .accessibilityHint(showProviders ? "收起端点管理" : "展开端点管理")
                if showProviders {
                    Text("自定义或诊断用；语义检索只用上方选中的模型。密钥只存引用名，绝不明文保存。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if providerConfigs.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "brain").foregroundStyle(.secondary)
                            Text("未配置端点").font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(10)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                    } else {
                        VStack(spacing: 0) {
                            ForEach(providerConfigs, id: \.id) { config in
                                providerRow(config)
                                if config.id != providerConfigs.last?.id { Divider().padding(.leading, 26) }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    HStack(spacing: 12) {
                        Button("添加供应商…") { showAddProvider = true }
                        if let scopeMessage, !providerConfigs.isEmpty {
                            Text(scopeMessage).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                    }
                }
            }
            Divider().padding(.vertical, 2)
            Text("本机内容索引").font(.system(size: 13, weight: .semibold))
            Text("选择要让「图片里的文字 / 文档正文」可搜的本机目录（如桌面、下载）。文件名搜索不受影响；只对所选目录做本地 OCR/正文提取，零上传。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if localScopes.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "text.viewfinder").foregroundStyle(.secondary)
                    Text("还没有选择目录。点「添加目录…」把常用文件夹升级为 文档+OCR 级索引。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 10)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            } else {
                VStack(spacing: 0) {
                    ForEach(localScopes) { scope in
                        HStack(spacing: 8) {
                            Image(systemName: "folder.badge.gearshape").foregroundStyle(Color.accentColor)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(scope.displayName).fontWeight(.medium)
                                Text(dirPath(of: scope)).font(.system(size: 10)).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Text("\(assetCounts[scope.sourceId] ?? 0) 个文件")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                            Button("移除") { removeScope(scope) }.controlSize(.small)
                        }
                        .padding(.vertical, 4)
                        if scope.sourceId != localScopes.last?.sourceId { Divider().padding(.leading, 26) }
                    }
                }
                .padding(.vertical, 2)
            }
            HStack(spacing: 12) {
                Button("添加目录…") { chooseLocalContentDir() }
                if let scopeMessage {
                    Text(scopeMessage).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text("\(localScopes.count) 个目录").font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Divider().padding(.vertical, 2)
            HStack(spacing: 8) {
                Text("人物检索（实验）").font(.system(size: 13, weight: .semibold))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { faceStatus?.enabled ?? false },
                    set: { value in setFaceSearch(value) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(faceStatus?.modelAvailable != true)
                    .accessibilityLabel("人物检索")
                    .help("默认关闭；开启后按来源建立本机人脸向量")
            }
            Text("参考照片 → 本机人脸检测 → 向量 → 按资产去重。模型不随 App 分发，零上传；与内容 OCR 开关独立。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let status = faceStatus {
                HStack(spacing: 8) {
                    Image(systemName: status.modelAvailable ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(status.modelAvailable ? Color.green : Color.orange)
                    Text(status.modelAvailable ? "本机模型已就绪" : "本机模型未安装")
                        .font(.system(size: 11))
                    Spacer()
                    Text("向量 \(status.embeddings)").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if status.enabled {
                    HStack(spacing: 8) {
                        Text("召回范围").font(.system(size: 10)).foregroundStyle(.secondary)
                        Picker("", selection: Binding(
                            get: { status.minScore },
                            set: { value in
                                engine?.setFaceMinScore(value)
                                refreshFromEngine()
                            })) {
                            Text("严格").tag(0.60)
                            Text("标准").tag(0.50)
                            Text("宽松").tag(0.35)
                            Text("高召回").tag(0.25)
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.mini)
                        .frame(width: 220)
                    }
                    Text("阈值越低召回越多，误报也越多；当前 \(String(format: "%.2f", status.minScore))")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text("待处理 \(status.counts.pending) · 运行 \(status.counts.running) · 完成 \(status.counts.done) · 失败 \(status.counts.failed) · 已启用 \(status.enabledSources) 个来源")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text("在来源行打开“人脸索引”；默认不建立任何人脸数据。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                if !status.modelAvailable {
                    Text("模型路径：\(engine?.faceModelURL.path ?? "—")")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                if status.enabled || status.embeddings > 0 {
                    HStack {
                        Button("删除全部人脸数据…", role: .destructive) { showFaceDeleteConfirm = true }
                            .controlSize(.small)
                            .disabled(status.embeddings == 0)
                        Spacer()
                    }
                }
            } else {
                Text("正在读取人物索引状态…").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)   // Section 内容边距（用户实测贴边问题，≥5-10px）
        .padding(.vertical, 4)
        .onAppear {
            providerConfigs = engine?.providers.current.httpEmbeddings ?? []
            allowEgress = engine?.providers.egress.allowsRemote ?? false
            refreshFromEngine()
        }
        .onReceive(refreshTimer) { _ in refreshFromEngine() }
        .onChange(of: refreshToken) { _, _ in refreshFromEngine() }
        .sheet(item: $relinkTarget) { record in
            relinkSheet(record)
        }
        .sheet(isPresented: $showAddProvider) {
            AddProviderSheet { config in
                guard let engine else { return }
                do {
                    try engine.providers.addHTTPEmbedding(config)
                    providerConfigs = engine.providers.current.httpEmbeddings
                    probeProvider(id: config.id)
                } catch { scopeMessage = "添加失败：\(error.localizedDescription)" }
            }
        }
        .alert("删除全部人脸数据？", isPresented: $showFaceDeleteConfirm) {
            Button("取消", role: .cancel) { }
            Button("删除", role: .destructive) { deleteFaceData() }
        } message: {
            Text("将删除本机所有人脸向量与未处理人脸任务；文件名、OCR、语义与以图搜图索引不受影响。")
        }
    }

    /// 轮询快照全部在后台队列计算，主线程只做「有变化才赋值」。
    /// 旧实现直接在 onReceive 里同步查询：69 万任务行的 GROUP BY 单次 1.05s，
    /// 每 1.5s 把主线程钉住一次——设置页拖动滚动条会被反复打断（2026-10-22 采样实锤）。
    private func refreshFromEngine() {
        guard let engine, !refreshInFlight else { return }
        refreshInFlight = true
        DispatchQueue.global(qos: .utility).async {
            let newRecords = engine.records()
            let newScopes = engine.localContentScopes()
            var newCounts: [String: Int] = [:]
            for scope in newScopes { newCounts[scope.sourceId] = engine.liveAssetCount(sourceId: scope.sourceId) }
            let newContentPending = (try? engine.content?.pendingCount()) ?? 0
            let newSemanticPending = (try? engine.semantic?.counts())?.pending ?? 0
            let newFaceStatus = engine.faceStatus()
            DispatchQueue.main.async {
                refreshInFlight = false
                if !loaded { loaded = true }
                if newRecords != records { records = newRecords }
                if newScopes != localScopes { localScopes = newScopes }
                if newCounts != assetCounts { assetCounts = newCounts }
                if newContentPending != contentPending { contentPending = newContentPending }
                if newSemanticPending != semanticPending { semanticPending = newSemanticPending }
                if newFaceStatus != faceStatus { faceStatus = newFaceStatus }
                if sourceCount != newRecords.count { sourceCount = newRecords.count }
            }
        }
    }

    // MARK: Provider 行（A1 用户面）

    private func providerRow(_ config: HTTPEmbeddingProvider.Config) -> some View {
        let loopback = ContentEgressPolicy.isLoopback(config.endpoint)
        let status = engine?.providers.semanticStatus()
        let inUse = status?.mode != .off && status?.providerId == config.id
        return HStack(spacing: 8) {
            Image(systemName: loopback ? "desktopcomputer" : "cloud")
                .foregroundStyle(loopback ? Color.accentColor : (allowEgress ? Color.orange : Color.secondary))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(config.displayName).fontWeight(.medium)
                    if inUse {
                        Text("语义模型使用中").font(.system(size: 9)).foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                    Text(providerProbeText[config.id] ?? (loopback ? "本机 · 未探测" : (allowEgress ? "远端 · 未探测" : "远端 · 外发未授权")))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Text("\(config.model) · \(config.endpoint.absoluteString)")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("探测") { probeProvider(id: config.id) }.controlSize(.small)
            Button("移除") {
                try? engine?.providers.remove(id: config.id)
                providerConfigs = engine?.providers.current.httpEmbeddings ?? []
                providerProbeText[config.id] = nil
            }.controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    /// 探测走后台（真发一次最小 embed）；结果摘要回主线程。
    private func probeProvider(id: String) {
        guard let engine, let provider = engine.providers.embeddingProviders.first(where: { $0.id == id }) else { return }
        // 与语义模式一致：当前模式不会用到的端点不探测（关闭=零请求，本地=不碰远端）。
        guard engine.providers.semanticEmbeddingProviders().contains(where: { $0.id == id }) else {
            providerProbeText[id] = "当前模式不使用该端点；切换到对应模式后再探测"
            return
        }
        providerProbeText[id] = "探测中…"
        Task.detached(priority: .utility) {
            let probe = await provider.probe()
            let text: String
            switch probe {
            case .available(let ms, let caps): text = "可用 · \(ms)ms · \(caps.dimensions.map { "\($0) 维" } ?? "维度未知") · \(caps.embedImage ? "文本+图片" : "仅文本")"
            case .unavailable(let error): text = "不可用 · \(describeProviderError(error))"
            }
            await MainActor.run { providerProbeText[id] = text }
        }
    }

    // MARK: 本机内容索引范围（PRD：明确目录 + 成本预估 + 索引等级提示）

    private func dirPath(of scope: SourceRecord) -> String {
        scope.locator.hasPrefix("file://") ? String(scope.locator.dropFirst(7)) : scope.locator
    }

    /// 选目录 → 实地成本预估（后台）→ 确认弹窗（等级提示+预估时长）→ 零双扫登记。
    private func chooseLocalContentDir() {
        guard let engine else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择要做内容索引的本机目录。文件名搜索始终全盘可用；此操作把所选目录升级为「文档+OCR」级（AI 深度索引暂未开放）。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let dir = url.path
        scopeMessage = "正在统计「\(url.lastPathComponent)」…"
        DispatchQueue.global(qos: .userInitiated).async {
            let estimate = engine.localContentEstimate(dirPath: dir)
            DispatchQueue.main.async {
                scopeMessage = nil
                confirmLocalScope(dir: dir, name: url.lastPathComponent, estimate: estimate)
            }
        }
    }

    private func confirmLocalScope(dir: String, name: String, estimate: AstfindEngine.LocalContentEstimate) {
        guard let engine else { return }
        let mb = ByteCountFormatter.string(fromByteCount: estimate.totalBytes, countStyle: .file)
        let seconds = estimate.estimatedSeconds(lanes: lanes)
        let duration = seconds >= 90 ? "\(Int((Double(seconds) / 60).rounded(.up))) 分钟" : "\(seconds) 秒"
        let plus = estimate.truncated ? "+" : ""
        let alert = NSAlert()
        alert.messageText = "将「\(name)」加入内容索引"
        alert.informativeText = """
            约 \(estimate.images)\(plus) 张图片、\(estimate.documents)\(plus) 个文档（共 \(mb)\(plus)）\(estimate.truncated ? "——目录很大，统计已截断" : "")。
            按当前 \(lanes) 路速度预计约 \(duration)\(plus)（后台进行，可随时改档位或暂停）。
            只做本地 OCR/正文提取，零上传；文件名搜索不受影响。
            """
        alert.addButton(withTitle: "开始索引")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let store = primaryStore() else {
            scopeMessage = "主索引尚未就绪，请稍后在「添加目录…」重试"
            return
        }
        scopeMessage = "已加入「\(name)」，后台开始提取"
        DispatchQueue.global(qos: .utility).async {
            _ = try? engine.ensureLocalContentSource(dirPath: dir, displayName: name, store: store)
            DispatchQueue.main.async { localScopes = engine.localContentScopes() }
        }
    }

    private func removeScope(_ scope: SourceRecord) {
        guard let engine else { return }
        do {
            try engine.remove(sourceId: scope.sourceId)
            scopeMessage = "已移除「\(scope.displayName)」（已提取的内容一并清除）"
        } catch {
            scopeMessage = "移除失败：\(error.localizedDescription)"
        }
        localScopes = engine.localContentScopes()
    }

    // MARK: R3 重新链接（PR 式保底）：入口只给离线源；匹配校验走后台队列（热路径红线）

    private func row(_ record: SourceRecord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(for: record))
                .foregroundStyle(record.onlineState == .online ? Color.accentColor : Color.secondary)
                .frame(width: 20)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(record.displayName)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if record.onlineState == .online {
                        Text("在线").font(.system(size: 10)).foregroundStyle(.green)
                    } else {
                        Text("已离线 · 上次连接 \(lastSeen(record))")
                            .font(.system(size: 10)).foregroundStyle(.orange)
                    }
                    Text("索引·\(stateText(record.indexState))")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    // 入口始终可用，实际重绑仍受 90% 匹配率与确认 sheet 保护。
                    if !record.contentOnly {
                        Button("重新链接…") { startRelink(record) }
                            .controlSize(.small)
                    }
                    Button("移除") { remove(record) }
                        .controlSize(.small)
                }
                Text(record.locator)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !record.contentOnly {
                    HStack(spacing: 10) {
                        indexControl(
                            title: "内容索引",
                            enabled: record.contentIndexEnabled,
                            busy: contentToggleBusy.contains(record.sourceId),
                            help: "关闭后不再处理新的 OCR、正文和语义任务；已完成结果保留，未处理任务会清理。",
                            accessibility: "「\(record.displayName)」内容索引",
                            onChange: { value in setContentIndex(record, enabled: value) })
                        indexControl(
                            title: "人脸索引",
                            enabled: record.faceIndexEnabled,
                            busy: faceToggleBusy.contains(record.sourceId),
                            help: "开启后为该来源建立本机人脸向量；默认关闭，与内容 OCR 独立。",
                            accessibility: "「\(record.displayName)」人脸索引",
                            onChange: { value in setFaceIndex(record, enabled: value) })
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 1)
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Text("人脸范围")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Text(record.faceIndexPrefix?.isEmpty == false ? record.faceIndexPrefix! : "整个来源")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        if faceScopeBusy.contains(record.sourceId) {
                            Text("正在更新…").font(.system(size: 9)).foregroundStyle(.secondary)
                        } else {
                            Button("选择…") { chooseFaceScope(record) }
                                .font(.system(size: 9))
                                .controlSize(.mini)
                                .disabled(record.onlineState != .online || record.mountPath == nil)
                            if record.faceIndexPrefix?.isEmpty == false {
                                Button("全部") { applyFaceScope(record, prefix: nil) }
                                    .font(.system(size: 9))
                                    .controlSize(.mini)
                            }
                        }
                    }
                    .padding(.leading, 1)
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 2)
    }

    /// 来源行的索引开关卡片：统一高度、左侧开关、右侧标题/状态，避免两行开关挤在一起。
    private func indexControl(title: String, enabled: Bool, busy: Bool,
                              help: String, accessibility: String,
                              onChange: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { enabled }, set: onChange))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(busy)
                .accessibilityLabel(accessibility)
                .help(help)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 11, weight: .medium))
                Text(busy ? "正在清理…" : (enabled ? "已开启" : "未启用"))
                    .font(.system(size: 9))
                    .foregroundStyle(enabled ? Color.secondary : Color.orange)
            }
            .frame(minWidth: 68, alignment: .leading)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
    }

    /// 内容索引开关：清理 10 万级 pending 可能耗时数秒，必须离开主线程。
    private func setContentIndex(_ record: SourceRecord, enabled: Bool) {
        guard let engine else { return }
        contentToggleBusy.insert(record.sourceId)
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try engine.setContentIndexEnabled(sourceId: record.sourceId, enabled: enabled) }
            DispatchQueue.main.async {
                contentToggleBusy.remove(record.sourceId)
                switch result {
                case .success(let cleared):
                    statusMessage = enabled
                        ? "已开启「\(record.displayName)」内容索引，后台开始补齐"
                        : "已关闭「\(record.displayName)」内容索引，清理 \(cleared) 个待处理任务（已完成结果保留）"
                case .failure(let error):
                    statusMessage = "切换内容索引失败：\(error.localizedDescription)"
                }
                refreshFromEngine()
            }
        }
    }

    private func setFaceSearch(_ enabled: Bool) {
        guard let engine else { return }
        DispatchQueue.global(qos: .utility).async {
            engine.setFaceSearchEnabled(enabled)
            DispatchQueue.main.async { refreshFromEngine() }
        }
    }

    private func deleteFaceData() {
        guard let engine, let face = engine.face else { return }
        DispatchQueue.global(qos: .utility).async {
            let deleted = (try? face.deleteAll()) ?? 0
            DispatchQueue.main.async {
                statusMessage = "已删除 \(deleted) 条人脸向量"
                refreshFromEngine()
            }
        }
    }

    /// 选择来源内的人脸索引目录；选中目录后只索引该目录下的图片/视频。
    private func chooseFaceScope(_ record: SourceRecord) {
        guard let mount = record.mountPath, !mount.isEmpty else {
            statusMessage = "来源离线，无法选择目录"
            return
        }
        let root = URL(fileURLWithPath: mount).standardizedFileURL
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = root
        panel.message = "选择「\(record.displayName)」的人脸索引目录；只索引该目录下的图片/视频。"
        guard panel.runModal() == .OK, let selected = panel.url?.standardizedFileURL else { return }
        let rootPath = root.path.hasSuffix("/") ? String(root.path.dropLast()) : root.path
        guard selected.path == rootPath || selected.path.hasPrefix(rootPath + "/") else {
            statusMessage = "请选择来源目录内的文件夹"
            return
        }
        var prefix = String(selected.path.dropFirst(rootPath.count))
        if prefix.hasPrefix("/") { prefix.removeFirst() }
        if !prefix.isEmpty && !prefix.hasSuffix("/") { prefix += "/" }
        applyFaceScope(record, prefix: prefix.isEmpty ? nil : prefix)
    }

    /// 应用人脸索引范围；选择“整个来源”时用文件数做一次确认，避免误把 9 万张照片全量排队。
    private func applyFaceScope(_ record: SourceRecord, prefix: String?) {
        guard let engine else { return }
        if prefix == nil {
            let count = engine.liveAssetCount(sourceId: record.sourceId)
            let alert = NSAlert()
            alert.messageText = "对整个来源建立人脸索引？"
            alert.informativeText = "「\(record.displayName)」共有 \(count) 个文件。将对该来源下所有图片/视频建立人脸向量，可能耗时较长并占用磁盘。"
            alert.addButton(withTitle: "继续")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        faceScopeBusy.insert(record.sourceId)
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try engine.setFaceIndexPrefix(sourceId: record.sourceId, prefix: prefix) }
            DispatchQueue.main.async {
                faceScopeBusy.remove(record.sourceId)
                switch result {
                case .success(let cleared):
                    statusMessage = prefix == nil
                        ? "已将「\(record.displayName)」人脸范围设为整个来源"
                        : "已将「\(record.displayName)」人脸范围设为 \(prefix ?? "")"
                    if cleared > 0 { statusMessage = (statusMessage ?? "") + "，清理 \(cleared) 个待处理任务" }
                case .failure(let error):
                    statusMessage = "设置人脸范围失败：\(error.localizedDescription)"
                }
                refreshFromEngine()
            }
        }
    }

    /// 人脸索引开关：与内容索引相同，清理 pending 离开主线程。
    private func setFaceIndex(_ record: SourceRecord, enabled: Bool) {
        guard let engine else { return }
        faceToggleBusy.insert(record.sourceId)
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try engine.setFaceIndexEnabled(sourceId: record.sourceId, enabled: enabled) }
            DispatchQueue.main.async {
                faceToggleBusy.remove(record.sourceId)
                switch result {
                case .success(let cleared):
                    statusMessage = enabled
                        ? "已开启「\(record.displayName)」人脸索引，后台开始建向量"
                        : "已关闭「\(record.displayName)」人脸索引，清理 \(cleared) 个待处理任务"
                case .failure(let error):
                    statusMessage = "切换人脸索引失败：\(error.localizedDescription)"
                }
                refreshFromEngine()
            }
        }
    }

    private func lastSeen(_ record: SourceRecord) -> String {
        guard let date = record.lastSuccessfulScanAt else { return "时间未知" }
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }

    /// 选新位置（文件夹或任一同名文件=锚点）→ 后台比对 → sheet 报告确认。
    private func startRelink(_ record: SourceRecord) {
        guard let engine else { return }
        let samples = engine.sampleRelativePaths(sourceId: record.sourceId, count: 3)
            .map { ($0 as NSString).lastPathComponent }.joined(separator: "、")
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "重新链接「\(record.displayName)」— 原始位置：\(record.snapshotRootPath ?? record.locator)"
            + (samples.isEmpty ? "" : "（含文件：\(samples)…）")
            + "。请选择素材新位置的文件夹，或其中任一个原有文件。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        relinkReport = nil
        relinkError = nil
        relinkBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let report = try engine.analyzeRelink(sourceId: record.sourceId, anchor: url)
                DispatchQueue.main.async {
                    relinkBusy = false
                    relinkReport = report
                }
            } catch {
                DispatchQueue.main.async {
                    relinkBusy = false
                    relinkError = "\(error.localizedDescription)\(error)"
                }
            }
        }
    }

    private func relinkSheet(_ record: SourceRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("重新链接「\(record.displayName)」").font(.system(size: 13, weight: .semibold))
            Text("原始位置：\(record.snapshotRootPath ?? record.locator)")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            Divider()
            if let relinkError {
                Label(relinkError, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let report = relinkReport {
                let percent = Int((report.matchRate * 100).rounded())
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(percent)%").font(.system(size: 26, weight: .bold))
                        .foregroundStyle(report.meetsThreshold ? .green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("匹配 \(report.matched) / \(report.sampled)（共 \(report.totalAssets) 个文件）")
                            .font(.system(size: 11))
                        Text("大小不符 \(report.sizeMismatched) 个").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Text("新位置：\(report.candidateRoot)")
                    .font(.system(size: 11)).lineLimit(2).truncationMode(.middle)
                if !report.missingSamples.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("缺失（前 \(report.missingSamples.count) 条）：").font(.system(size: 10)).foregroundStyle(.secondary)
                        ForEach(report.missingSamples.prefix(5), id: \.self) { path in
                            Text("· " + path).font(.system(size: 10)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                if !report.meetsThreshold {
                    Label("匹配率不足 90%——可能选错了位置，请取消后改选素材所在的文件夹", systemImage: "questionmark.circle")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(relinkBusy ? "正在比对快照与所选位置（抽样 ≤500 个文件）…" : "准备中…")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            Divider()
            HStack {
                Text("确认后保留全部索引与内容观测，后台自动重建差异；取消无任何改动。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { relinkTarget = nil }
                Button("确认重绑") { confirmRelink(record) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(relinkBusy || !(relinkReport?.meetsThreshold ?? false))
            }
        }
        .frame(width: 460)
        .padding(16)
    }

    private func confirmRelink(_ record: SourceRecord) {
        guard let engine, let report = relinkReport, report.meetsThreshold else { return }
        let root = report.candidateRoot
        relinkBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try engine.applyRelink(sourceId: record.sourceId, to: root)
                DispatchQueue.main.async {
                    relinkBusy = false
                    relinkTarget = nil
                    statusMessage = "已重绑「\(record.displayName)」，正在后台重建索引"
                    records = engine.records()
                }
            } catch {
                DispatchQueue.main.async {
                    relinkBusy = false
                    relinkError = "重绑失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func icon(for record: SourceRecord) -> String {
        switch record.kind {
        case .smb: return "network"
        case .external: return "externaldrive"
        case .local: return "folder"
        }
    }
    private func stateText(_ state: SourceRecord.IndexState) -> String {
        switch state {
        case .empty: return "未建"; case .partial: return "部分"; case .ready: return "完成"; case .stale: return "待更新"
        }
    }

    private func remove(_ record: SourceRecord) {
        guard let engine else { return }
        do {
            try engine.remove(sourceId: record.sourceId)
            statusMessage = "已移除「\(record.displayName)」"
        } catch {
            statusMessage = "移除失败：\(error.localizedDescription)"
        }
        records = engine.records()
        if sourceCount != records.count { sourceCount = records.count }
    }
}

/// 内容提取进度列表：只在抽屉展开时挂载，因此轮询/任务表查询也只在展开期间发生。
private struct ExtractionProgressList: View {
    let engine: AstfindEngine
    @State private var progress: [AstfindEngine.ExtractionProgress] = []
    @State private var loaded = false
    @State private var refreshInFlight = false
    private let refreshTimer = Timer.publish(every: 1.5, on: .main, in: .default).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !loaded {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在读取提取进度…").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else if progress.isEmpty {
                Text("当前没有进行中的内容提取。").font(.system(size: 10)).foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Spacer()
                    Text(overallProgressText).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                VStack(spacing: 0) {
                    ForEach(progress) { item in
                        progressRow(item)
                        if item.sourceId != progress.last?.sourceId { Divider().padding(.leading, 26) }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .onAppear { refresh() }
        .onReceive(refreshTimer) { _ in refresh() }
    }

    /// 任务表聚合在后台只读连接上跑；主线程只接收结果（覆盖索引见 Migrations v7）。
    private func refresh() {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        DispatchQueue.global(qos: .utility).async {
            let newProgress = engine.extractionProgress()
            DispatchQueue.main.async {
                refreshInFlight = false
                if !loaded { loaded = true }
                if newProgress != progress { progress = newProgress }
            }
        }
    }

    private var overallProgressText: String {
        let remaining = progress.reduce(0) { $0 + $1.remaining }
        guard remaining > 0 else { return "全部完成" }
        let rate = progress.compactMap(\.ratePerMinute).reduce(0, +)
        guard rate > 0 else { return "合计剩余 \(remaining) · 等待处理" }
        return "合计剩余 \(remaining) · 预计 \(durationText(Int((Double(remaining) / rate * 60).rounded(.up))))"
    }

    private func durationText(_ seconds: Int) -> String {
        if seconds >= 5400 { return String(format: "%.1f 小时", Double(seconds) / 3600) }
        if seconds >= 90 { return "\(Int((Double(seconds) / 60).rounded(.up))) 分钟" }
        return "\(max(1, seconds)) 秒"
    }

    private func progressRow(_ item: AstfindEngine.ExtractionProgress) -> some View {
        let finished = item.done + item.failed
        let detail: String = {
            var parts = ["已完成 \(item.done)", "剩余 \(item.remaining)"]
            if item.remaining > 0 {
                parts.append(item.ratePerMinute.map { String(format: "%.0f 个/分", $0) } ?? "速率 —")
                parts.append(item.etaSeconds.map { "预计 \(durationText($0))" } ?? "预计 —")
            }
            return parts.joined(separator: " · ")
        }()
        return HStack(spacing: 8) {
            Image(systemName: item.remaining > 0 ? "arrow.triangle.2.circlepath" : "checkmark.circle")
                .foregroundStyle(item.remaining > 0 ? Color.accentColor : Color.green)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.displayName).fontWeight(.medium)
                    Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                ProgressView(value: Double(finished), total: Double(max(1, item.total)))
                    .controlSize(.small)
            }
            Spacer()
            if item.failed > 0 {
                Button("失败 \(item.failed)") { showFailedSamples(item) }
                    .controlSize(.small)
                    .help("查看失败样本：常见为 ._ 边车/损坏文件，并非内容丢失")
            }
        }
        .padding(.vertical, 4)
    }

    private func showFailedSamples(_ item: AstfindEngine.ExtractionProgress) {
        let samples = engine.failedExtractionSamples(sourceId: item.sourceId, limit: 8)
        let alert = NSAlert()
        alert.messageText = "「\(item.displayName)」失败任务样本（\(item.failed) 个中的前 \(samples.count) 个）"
        alert.informativeText = (samples.isEmpty ? "（无样本）" : samples.map { "· " + $0 }.joined(separator: "\n"))
            + "\n\n失败为终态、不重试：以 ._ 开头的是 exFAT/NAS 元数据边车（无内容可提取），其余多为损坏或不支持的文件。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

// MARK: - 语义模型（关闭 / 远程 / 本地）

/// 语义模型：关闭 / 远程 / 本地。
///
/// 信息层级（开发者反馈：原版太挤、文字噪声多）：
/// 1. 三态选择器是唯一「醒目」元素（整行大号分段控件）；
/// 2. 当前状态单独一张卡，默认只显示模型名 + 连接摘要；点开才有端点、测试、配置、外发授权；
/// 3. 「图片与视频语义索引」是第二层抽屉，展开才轮询入库进度——收起时零数据库查询；
/// 4. 每段最多一句说明，细节留给展开区。
private struct SemanticModelSection: View {
    let engine: AstfindEngine?
    @Binding var semanticSearch: Bool
    @Binding var allowEgress: Bool
    let onConfigChanged: () -> Void

    @State private var mode: SemanticMode = .off
    /// 点中但尚未确认的模式：选择器只做预览，确认后才真正写配置（切换是谨慎动作）
    @State private var pendingMode: SemanticMode?
    /// 配置弹窗针对的模式（当前模式或待切换模式）；保存端点不切换模式
    @State private var configTarget: SemanticMode = .off
    @State private var showDetails = false
    @State private var showIndexing = false
    @State private var probing = false
    @State private var showConfig = false
    @State private var showGuide = false
    @State private var progress: AstfindEngine.EmbedProgress?
    @State private var progressInFlight = false
    /// 本节自己的提示（切换/保存失败、端点为仅文本等）——显示在本节内，不写进收起的高级抽屉。
    @State private var notice: String?
    /// 只在索引抽屉展开时轮询；默认收起时设置页零查询（设置页卡顿教训 430e788）。
    private let progressTimer = Timer.publish(every: 2, on: .main, in: .default).autoconnect()

    private var status: ProviderHub.SemanticStatus? { engine?.providers.semanticStatus() }
    /// 某模式下会被使用的端点（按端点性质取第一个，与 ProviderHub 的候选规则一致）
    private func configFor(_ target: SemanticMode) -> HTTPEmbeddingProvider.Config? {
        guard target != .off else { return nil }
        let loopback = target == .local
        return engine?.providers.current.httpEmbeddings.first {
            ContentEgressPolicy.isLoopback($0.endpoint) == loopback
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("语义模型").font(.system(size: 13, weight: .semibold))
            modeSelector

            if pendingMode == nil {
                Text(modeCaption)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            pendingPanel

            if let notice {
                Text(notice).font(.system(size: 10)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if pendingMode == nil, mode != .off {
                statusCard
                if status?.isConfigured == true {
                    indexingDrawer
                }
            }
        }
        .onAppear { syncFromEngine() }
        .onReceive(NotificationCenter.default.publisher(for: .astfindSettingsWillPresent)) { _ in syncFromEngine() }
        .onReceive(progressTimer) { _ in tickProgress() }
        .onChange(of: showIndexing) { _, expanded in
            if expanded { refreshProgress() } else { progress = nil }
        }
        .onChange(of: semanticSearch) { _, _ in
            if showIndexing { refreshProgress() }
        }
        .sheet(isPresented: $showConfig) {
            SemanticModelSheet(mode: configTarget, existing: configFor(configTarget),
                               allowEgress: engine?.providers.egress.allowsRemote ?? false,
                               onSave: apply)
        }
        .sheet(isPresented: $showGuide) {
            LocalServerGuideSheet(suggestedModel: status?.model ?? "weemm-2b")
        }
    }

    /// 三态选择器：整行等分、大号命中区——本区块唯一需要「醒目」的元素。
    /// 原生 segmented Picker 在 macOS 上按内在宽度居中，不随容器拉伸（实测跑位），故自绘。
    private var modeSelector: some View {
        HStack(spacing: 2) {
            ForEach(SemanticMode.allCases, id: \.self) { item in
                Button {
                    selectMode(item)
                } label: {
                    Text(item.displayName)
                        .font(.system(size: 12, weight: mode == item ? .semibold : (pendingMode == item ? .medium : .regular)))
                        .foregroundStyle(mode == item ? Color.white : (pendingMode == item ? Color.accentColor : Color.primary))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background {
                    if mode == item {
                        RoundedRectangle(cornerRadius: 6).fill(Color.accentColor)
                    } else if pendingMode == item {
                        RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.14))
                    }
                }
                .accessibilityAddTraits(mode == item ? [.isSelected] : [])
                .disabled(engine == nil)
            }
        }
        .padding(3)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("语义模型模式")
    }

    private var modeCaption: String {
        switch mode {
        case .off: return "语义通道关闭，不影响文件名与内容搜索。"
        case .remote: return "图片与查询会发往你的远端端点，需显式授权。"
        case .local: return "只连本机 127.0.0.1，零外发。"
        }
    }

    // MARK: 待确认切换（点一下只预览，确认后才写配置）

    @ViewBuilder
    private var pendingPanel: some View {
        if let target = pendingMode, target != mode {
            let preview = preview(for: target)
            VStack(alignment: .leading, spacing: 7) {
                Text(target == .off ? "关闭语义模型？" : "切换到\(target.displayName)？")
                    .font(.system(size: 11, weight: .semibold))
                HStack(spacing: 6) {
                    Text(preview.name).font(.system(size: 11)).lineLimit(1)
                    if !preview.detail.isEmpty {
                        Text(preview.detail).font(.system(size: 10))
                            .foregroundStyle(preview.configured ? Color.secondary : Color.orange)
                            .lineLimit(1)
                    }
                }
                if let endpoint = preview.endpoint {
                    Text(endpoint).font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Text(pendingImpact(target))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(target == .off ? "关闭语义模型" : "切换到此模式") { commitPending() }
                        .controlSize(.small)
                    if target != .off {
                        Button(preview.configured ? "修改配置…" : "先配置…") {
                            configTarget = target
                            showConfig = true
                        }.controlSize(.small)
                    }
                    Button("取消") { pendingMode = nil }.controlSize(.small)
                    Spacer()
                }
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor.opacity(0.35), lineWidth: 1))
            .transition(.opacity)
        }
    }

    private struct ModePreview {
        let name: String
        let detail: String
        let endpoint: String?
        let configured: Bool
    }

    /// 切换前的只读预览：该模式会用哪个端点、当前连通状态；不探测、不写入。
    private func preview(for target: SemanticMode) -> ModePreview {
        guard let engine else {
            return ModePreview(name: "引擎未就绪", detail: "", endpoint: nil, configured: false)
        }
        guard target != .off else {
            return ModePreview(name: "关闭语义模型", detail: "不影响文件名与内容搜索", endpoint: nil, configured: true)
        }
        guard let config = configFor(target) else {
            return ModePreview(name: target == .local ? "还没有配置本机端点" : "还没有配置远端端点",
                               detail: "可以先配置再切换", endpoint: nil, configured: false)
        }
        var parts = [config.model]
        if let probe = engine.providers.lastProbe(id: config.id) {
            switch probe {
            case .available(_, let caps):
                if let dims = caps.dimensions { parts.append("\(dims) 维") }
                parts.append("已连接")
            case .unavailable(let error):
                parts.append("不可用 · " + describeProviderError(error))
            }
        } else {
            parts.append("未测试")
        }
        if target == .remote, !engine.providers.egress.allowsRemote { parts.append("外发未授权") }
        return ModePreview(name: config.displayName, detail: parts.joined(separator: " · "),
                           endpoint: config.endpoint.absoluteString, configured: true)
    }

    private func pendingImpact(_ target: SemanticMode) -> String {
        switch target {
        case .off: return "当前语义索引会暂停，已有向量保留。"
        case .local: return "检索只使用这个本机端点；当前索引暂停，向量不会自动重建。"
        case .remote: return "检索只使用这个远端端点；当前索引暂停，向量不会自动重建。"
        }
    }

    // MARK: 状态卡

    @ViewBuilder
    private var statusCard: some View {
        if let status, status.isConfigured {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) { showDetails.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        chevron(expanded: showDetails)
                        Text(status.displayName ?? status.providerId ?? "")
                            .font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(probing ? "测试中…" : probeSummary(status))
                            .font(.system(size: 10)).foregroundStyle(probeColor(status)).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 10).padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("语义模型状态")
                .accessibilityHint(showDetails ? "收起详情" : "展开端点与测试")

                if showDetails {
                    Divider().padding(.horizontal, 10)
                    detailContent(status)
                        .padding(.leading, 27).padding(.trailing, 10).padding(.vertical, 9)
                        .transition(.opacity)
                }
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        } else {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
                Text(mode == .local ? "还没有配置本机端点" : "还没有配置远端端点")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("配置…") { configTarget = mode; showConfig = true }.controlSize(.small)
                if mode == .local { Button("启动指引…") { showGuide = true }.controlSize(.small) }
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func detailContent(_ status: ProviderHub.SemanticStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let endpoint = status.endpoint {
                Text(endpoint.absoluteString)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(endpoint.absoluteString)
            }
            if let detail = probeDetail(status) {
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let hint = localDownHint(status) {
                Text(hint).font(.system(size: 10)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button(probing ? "测试中…" : "测试连接") {
                    if let id = status.providerId { probeProvider(id: id) }
                }
                .controlSize(.small).disabled(probing)
                Button("配置…") { configTarget = mode; showConfig = true }.controlSize(.small)
                if mode == .local { Button("启动指引…") { showGuide = true }.controlSize(.small) }
                Spacer()
            }
            if mode == .remote {
                Toggle(isOn: egressBinding) {
                    Text("允许把图片与查询发送到该远端").font(.system(size: 11))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        }
    }

    private var egressBinding: Binding<Bool> {
        Binding(get: { allowEgress }, set: { value in
            do {
                try engine?.providers.setAllowRemoteEgress(value)
                allowEgress = value
                notice = nil
            } catch { notice = "授权切换失败：\(error.localizedDescription)" }
        })
    }

    // MARK: 索引抽屉（展开才轮询）

    private var indexingDrawer: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { showIndexing.toggle() }
            } label: {
                HStack(spacing: 8) {
                    chevron(expanded: showIndexing, size: 9)
                    Text("图片与视频语义索引").font(.system(size: 11))
                    Spacer()
                    Text(semanticSearch ? "已开启" : "未启用")
                        .font(.system(size: 10)).foregroundStyle(semanticSearch ? Color.green : Color.secondary)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 10).padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("图片与视频语义索引")
            .accessibilityHint(showIndexing ? "收起索引设置与进度" : "展开索引设置与进度")

            if showIndexing {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: Binding(
                        get: { semanticSearch },
                        set: { requestIndexing($0) })) {
                        Text("为当前模型建立向量并参与搜索").font(.system(size: 11))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    Text("切换模型后需要重新建立；旧向量保留只读。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let progress {
                        Text(embedProgressText(progress))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary).lineLimit(2)
                    } else if !semanticSearch {
                        Text("未启用：打开开关开始为现有图片建立向量。")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 27).padding(.trailing, 10).padding(.bottom, 8).padding(.top, 2)
                .transition(.opacity)
            }
        }
    }

    private func refreshProgress() {
        guard showIndexing, let engine, semanticSearch, !progressInFlight else { return }
        progressInFlight = true
        DispatchQueue.global(qos: .utility).async {
            let newProgress = engine.embedProgress()
            DispatchQueue.main.async {
                progressInFlight = false
                if newProgress != progress { progress = newProgress }
            }
        }
    }

    private func tickProgress() {
        guard showIndexing else { return }
        guard semanticSearch else {
            if progress != nil { progress = nil }
            return
        }
        refreshProgress()
    }

    private func probeSummary(_ status: ProviderHub.SemanticStatus) -> String {
        guard let probe = status.probe else { return "未测试" }
        switch probe {
        case .available(_, let caps):
            return "已连接" + (caps.dimensions.map { " · \($0) 维" } ?? "")
        case .unavailable(let error):
            return "不可用 · " + describeProviderError(error)
        }
    }

    private func probeDetail(_ status: ProviderHub.SemanticStatus) -> String? {
        guard case .available(let ms, let caps)? = status.probe else { return nil }
        var parts = ["\(ms)ms", caps.embedImage ? "图片" : "仅文本"]
        if caps.batchImages > 1 { parts.append("批量 ×\(caps.batchImages)") }
        return parts.joined(separator: " · ")
    }

    private func probeColor(_ status: ProviderHub.SemanticStatus) -> Color {
        guard let probe = status.probe else { return .secondary }
        switch probe {
        case .available: return .green
        case .unavailable: return .orange
        }
    }

    /// 本地模式连不上时给出可执行提示（「不可用」本身是安全降级，不是阻塞）
    private func localDownHint(_ status: ProviderHub.SemanticStatus) -> String? {
        guard mode == .local, case .unavailable(let error)? = status.probe else { return nil }
        switch error {
        case .unreachable, .timeout: return "本地服务未启动？文件名/OCR 搜索不受影响。"
        default: return nil
        }
    }

    private func chevron(expanded: Bool, size: CGFloat = 9) -> some View {
        Image(systemName: "chevron.right")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(expanded ? 90 : 0))
    }

    // MARK: 动作

    private func syncFromEngine() {
        guard let engine else { return }
        mode = engine.providers.semanticMode()
        semanticSearch = engine.semanticSearchEnabled
        pendingMode = nil
    }

    /// 点分段只进入「待确认」状态：不写配置、不停泵、不弹建库。
    private func selectMode(_ target: SemanticMode) {
        notice = nil
        if target == mode {
            pendingMode = nil
            return
        }
        withAnimation(.easeInOut(duration: 0.16)) { pendingMode = target }
    }

    /// 用户明确确认后才切换：写配置、停掉旧模型的入库泵；建库仍是之后的手动动作。
    private func commitPending() {
        guard let engine, let target = pendingMode else { return }
        pendingMode = nil
        guard target != mode else { return }
        do { try engine.setSemanticMode(target) } catch {
            notice = "切换语义模型失败：\(error.localizedDescription)"
            return
        }
        mode = engine.providers.semanticMode()
        semanticSearch = engine.semanticSearchEnabled   // 切换后恒为 false（需显式开索引）
        showDetails = false
        showIndexing = false
        progress = nil
        notice = nil
        guard target != .off else { return }
        // 只更新状态卡的连通信息，不弹「是否建库」
        if let config = configFor(target) { probeProvider(id: config.id) }
    }

    /// 只探测指定端点并记录结果（状态卡与待切换预览共用），绝不触发建库。
    private func probeProvider(id: String) {
        guard let engine else { return }
        // 探测也是发送（ping + 1×1 探针图）：只允许探测当前模式候选。
        // 关闭 = 零请求；本地 = 绝不探测远端（即使历史上开过外发授权）。
        guard engine.providers.semanticEmbeddingProviders().contains(where: { $0.id == id }),
              let provider = engine.providers.embeddingProviders.first(where: { $0.id == id }) else {
            notice = "已保存。该端点不在当前语义模式内，切换到对应模式后才能测试连通性。"
            return
        }
        probing = true
        Task.detached(priority: .utility) {
            let probe = await provider.probe()
            engine.providers.record(probe: probe, id: provider.id)
            await MainActor.run {
                probing = false
                guard case .available(_, let caps) = probe, !caps.embedImage else { return }
                notice = "该端点不支持图片向量（探测实测）"
            }
        }
    }

    /// 建库是数小时级动作：只在用户主动打开索引开关时确认，绝不由模式切换触发。
    private func requestIndexing(_ enable: Bool) {
        guard enable else {
            semanticSearch = false
            engine?.setSemanticSearch(enabled: false)
            return
        }
        let alert = NSAlert()
        alert.messageText = "开始建立图片与视频索引？"
        var info = "将在后台为现有图片与视频帧建立向量，可能需要数小时；已有向量会复用，可随时关闭开关暂停。"
        switch mode {
        case .local: info += "\n\n只在本机 127.0.0.1 处理，零外发。"
        case .remote: info += "\n\n图片缩略图与查询文本会发送到你的远端端点。"
        case .off: break
        }
        alert.informativeText = info
        alert.addButton(withTitle: "开始")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }   // 取消则开关保持关
        semanticSearch = true
        engine?.setSemanticSearch(enabled: true)
        showIndexing = true
    }

    private func apply(_ config: HTTPEmbeddingProvider.Config, authorizeRemote: Bool) {
        guard let engine else { return }
        let target = configTarget
        do {
            if engine.providers.current.httpEmbeddings.contains(where: { $0.id == config.id }) {
                try engine.providers.updateHTTPEmbedding(id: config.id) { $0 = config }
            } else {
                try engine.providers.addHTTPEmbedding(config)
            }
            if target == .remote, authorizeRemote != engine.providers.egress.allowsRemote {
                try engine.providers.setAllowRemoteEgress(authorizeRemote)
            }
            allowEgress = engine.providers.egress.allowsRemote
            onConfigChanged()
            probeProvider(id: config.id)   // 只刷新状态；不切换模式、不建库
        } catch { notice = "保存失败：\(error.localizedDescription)" }
    }
}

/// 配置语义模型端点：本地强制回环（发送边界），远程可带外发授权。
private struct SemanticModelSheet: View {
    @Environment(\.dismiss) private var dismiss
    let mode: SemanticMode
    let existing: HTTPEmbeddingProvider.Config?
    let onSave: (HTTPEmbeddingProvider.Config, Bool) -> Void

    @State private var endpoint: String
    @State private var model: String
    @State private var keyRef: String
    @State private var batch: String
    @State private var authorize: Bool
    @State private var error: String?

    init(mode: SemanticMode, existing: HTTPEmbeddingProvider.Config?, allowEgress: Bool,
         onSave: @escaping (HTTPEmbeddingProvider.Config, Bool) -> Void) {
        self.mode = mode; self.existing = existing; self.onSave = onSave
        let local = mode == .local
        _endpoint = State(initialValue: existing?.endpoint.absoluteString
            ?? (local ? "http://127.0.0.1:8098/v1/embeddings" : ""))
        _model = State(initialValue: existing?.model ?? (local ? "weemm-2b" : ""))
        _keyRef = State(initialValue: existing?.apiKeyRef ?? "")
        // 本地服务脚本按 ≤8 图批量实现；新配置默认声明 8（探测实测不通过会自动降回串行）
        let batch = existing?.maxBatchImages ?? (existing == nil && local ? 8 : 0)
        _batch = State(initialValue: batch > 1 ? String(batch) : "")
        _authorize = State(initialValue: allowEgress)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(mode == .local ? "配置本地语义模型" : "配置远程语义模型")
                .font(.system(size: 13, weight: .semibold))
            Text(mode == .local
                 ? "只接受本机回环地址（127.0.0.1 / localhost / ::1）——本地模式永不外发。服务用仓库脚本启动，见「如何启动本地服务…」。"
                 : "OpenAI 兼容的 /v1/embeddings 端点，需支持图片向量（data URL 约定，探测会用 1×1 图实测）。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("端点").font(.system(size: 11))
                    TextField(mode == .local ? "http://127.0.0.1:8098/v1/embeddings" : "https://…/v1/embeddings", text: $endpoint)
                }
                GridRow {
                    Text("模型").font(.system(size: 11))
                    TextField(mode == .local ? "weemm-2b" : "模型名", text: $model)
                }
                if mode == .remote {
                    GridRow {
                        Text("密钥引用名").font(.system(size: 11))
                        TextField("留空=无鉴权；如 OPENAI → 读 ASTFIND_SECRET_OPENAI", text: $keyRef)
                    }
                }
                GridRow {
                    Text("批量上限").font(.system(size: 11))
                    TextField("留空=串行；探测实测确认后生效", text: $batch)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11))
            if mode == .remote {
                Toggle(isOn: $authorize) {
                    Text("允许把图片与查询发送到该远端（外发授权）").font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
                if let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
                   url.scheme?.lowercased() == "http", !ContentEgressPolicy.isLoopback(url) {
                    Label("明文 HTTP：图片与查询会以未加密方式经过网络，可被同网段窃听。建议改用 https；只在可信内网使用 http。",
                          systemImage: "lock.open")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button(existing == nil ? "添加并测试" : "保存并测试") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 500)
        .padding(16)
    }

    private func save() {
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedEndpoint), ContentEgressPolicy.isSendableEndpoint(url) else {
            error = "端点需为完整的 http(s) URL（含 http:// 或 https://），且不能在地址里内嵌用户名/密码"; return
        }
        if mode == .local, !ContentEgressPolicy.isLoopback(url) {
            error = "本地模式只接受本机回环地址（127.0.0.1 / localhost / ::1）；远端端点请切到「远程」模式。"; return
        }
        if mode == .remote, ContentEgressPolicy.isLoopback(url) {
            error = "这是本机地址，请切到「本地」模式（远程模式只接受非回环端点）。"; return
        }
        guard !trimmedModel.isEmpty else { error = "模型名不能为空"; return }
        let batchValue = batch.trimmingCharacters(in: .whitespaces)
        var maxBatch: Int?
        if !batchValue.isEmpty {
            guard let value = Int(batchValue), value > 1 else { error = "批量上限需为大于 1 的整数，或留空"; return }
            maxBatch = value
        }
        let ref = keyRef.trimmingCharacters(in: .whitespaces)
        let config = HTTPEmbeddingProvider.Config(
            id: existing?.id ?? (mode == .local ? "semantic-local" : "semantic-remote"),
            displayName: existing?.displayName ?? (mode == .local ? "本机语义模型" : "远程语义模型"),
            endpoint: url, model: trimmedModel,
            apiKeyRef: ref.isEmpty ? nil : ref,
            timeoutSeconds: existing?.timeoutSeconds ?? 30,
            imageInput: .dataURL,   // 语义检索的前提：能嵌图片；探测实测不通过会降级并给出可读错误
            maxImageBytes: existing?.maxImageBytes ?? 8_000_000,
            maxBatchImages: maxBatch)
        onSave(config, authorize)
        dismiss()
    }
}

/// 本地服务启动指引（App 不内置 Python/torch，也不替用户下载权重）
private struct LocalServerGuideSheet: View {
    @Environment(\.dismiss) private var dismiss
    let suggestedModel: String

    private var command: String {
        """
        .venv/bin/python AstfindKit/scripts/a0/a0b-serve-next.py \\
          --backend weemm2b --model-dir /path/to/weemm-2b \\
          --device mps --dtype float16 --port 8098
        """
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("启动本地语义服务").font(.system(size: 13, weight: .semibold))
            Text("Astfind 不内置 Python/torch，也不替你下载模型；本机服务用仓库里的 OpenAI 兼容脚本启动，App 只连回环地址，零外发。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                step(1, "准备模型：SentenceTransformers 格式的 WeMM-2B（约 5.2GB）或 EmbeddingGemma 2（约 1.4GB）。放本机盘或已挂载外置盘；exFAT 盘先删 `._*` 边车文件，否则处理器读取会报错。")
                step(2, "建环境：`python3 -m venv .venv && .venv/bin/pip install torch pillow sentence-transformers`")
                step(3, "启动服务（端口 8098；Gemma 用 `--backend gemma2 --model-dir … --dtype float32 --port 8097`）：")
            }
            Text(command)
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            Text("建议模型名：\(suggestedModel)。服务端会把小于 64px 的探针图抬到 64px、大图按 512px 下采样。启动后回到设置点「测试连接」，看到维度/图片/批量即连通。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("完整说明（模型准备、ExFAT 坑、CPU 回退、停止与回退）：docs/local-semantic-server.md")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 540)
        .padding(16)
    }

    private func step(_ index: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(index).").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 语义入库进度一行报：图片/视频两条线（向量数 + 任务态），后台跑量一眼可读
private func embedProgressText(_ progress: AstfindEngine.EmbedProgress) -> String {
    func jobs(_ c: EmbeddingIndexer.Counts) -> String {
        var parts = ["待 \(c.pending)"]
        if c.running > 0 { parts.append("跑 \(c.running)") }
        if c.failed > 0 { parts.append("败 \(c.failed)") }
        return parts.joined(separator: " / ")
    }
    var lines = ["图片 \(progress.imageVectors) 向量（\(jobs(progress.imageJobs))）"]
    if progress.videoJobs.done + progress.videoJobs.pending + progress.videoJobs.failed > 0 {
        lines.append("视频 \(progress.videoVectors) 帧向量（\(jobs(progress.videoJobs))）")
    }
    return "入库进度 · \(progress.providerId)：" + lines.joined(separator: " · ")
}

/// 失败分类 → 用户可读文案（探测行与语义模型状态共用）
private func describeProviderError(_ error: ProviderError) -> String {
    switch error {
    case .egressDenied: return "外发未授权"
    case .unreachable: return "连不上"
    case .timeout: return "超时"
    case .unauthorized: return "鉴权失败（检查密钥引用）"
    case .quotaExceeded: return "配额用尽"
    case .unsupported(let what): return "不支持（\(what)）"
    case .invalidResponse(let why): return "响应异常（\(why)）"
    case .server(let code): return "服务端错误 \(code)"
    case .cancelled: return "已取消"
    }
}

/// 添加 OpenAI 兼容向量 Provider 的表单（本机 Ollama / LM Studio / vLLM，或远端 API）。
/// 密钥只填引用名；真实密钥放环境变量 ASTFIND_SECRET_<引用名>（钥匙串适配器后续加）。
struct AddProviderSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onAdd: (HTTPEmbeddingProvider.Config) -> Void
    @State private var identifier = "ollama"
    @State private var name = "本机 Ollama"
    @State private var endpoint = "http://127.0.0.1:11434/v1/embeddings"
    @State private var model = "bge-m3"
    @State private var keyRef = ""
    @State private var supportsImages = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("添加向量供应商").font(.system(size: 13, weight: .semibold))
            Text("OpenAI 兼容的 /v1/embeddings 端点。本机地址不算外发；远端地址需先在上方开启「允许外发」。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow { Text("标识").font(.system(size: 11)); TextField("ollama", text: $identifier) }
                GridRow { Text("显示名").font(.system(size: 11)); TextField("本机 Ollama", text: $name) }
                GridRow { Text("端点").font(.system(size: 11)); TextField("http://127.0.0.1:11434/v1/embeddings", text: $endpoint) }
                GridRow { Text("模型").font(.system(size: 11)); TextField("bge-m3", text: $model) }
                GridRow { Text("密钥引用名").font(.system(size: 11)); TextField("留空=无鉴权；如 OPENAI → 读 ASTFIND_SECRET_OPENAI", text: $keyRef) }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11))
            Toggle(isOn: $supportsImages) {
                Text("该服务支持图片向量（data URL 约定，如 WeMM）——探测时会用 1×1 图实测验证").font(.system(size: 11))
            }
            .toggleStyle(.checkbox)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("添加并探测") {
                    let id = identifier.trimmingCharacters(in: .whitespaces)
                    guard !id.isEmpty, let url = URL(string: endpoint.trimmingCharacters(in: .whitespaces)),
                          ContentEgressPolicy.isSendableEndpoint(url) else {
                        error = "标识不能为空；端点需为完整的 http(s) URL，且不能在地址里内嵌用户名/密码"; return
                    }
                    guard !model.trimmingCharacters(in: .whitespaces).isEmpty else { error = "模型名不能为空"; return }
                    let ref = keyRef.trimmingCharacters(in: .whitespaces)
                    onAdd(.init(id: id, displayName: name.isEmpty ? id : name, endpoint: url,
                                model: model.trimmingCharacters(in: .whitespaces), apiKeyRef: ref.isEmpty ? nil : ref,
                                imageInput: supportsImages ? .dataURL : .unsupported))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 480)
        .padding(16)
    }
}
