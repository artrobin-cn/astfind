import AppKit
import Quartz
import Darwin
import UniformTypeIdentifiers
import OilFindCore

private final class SupplementarySearchBox { var hits: [SupplementaryHit] = [] }
private final class AdditionalSearchBox { var items: [AdditionalSearchItem] = []; var failed = false; var elapsedMs: Double = 0 }
private final class ImageSearchBox {
    var hits: [SupplementaryHit] = []
    var phase: ImageQueryPhase = .idle
    var jointPhase: JointImageQueryPhase = .idle
    var joint = false
    var elapsedMs: Double = 0
}

private final class SearchGeneration {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    func current(_ token: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return value == token }
}

final class SearchViewController: NSViewController, NSWindowDelegate, NSMenuDelegate {
    let searchField = SearchField(frame: .zero)
    let filters = FilterBar(frame: .zero)
    let results = ResultsView(frame: .zero)
    let footer = FooterBar(frame: .zero)
    let quickLook = QuickLook()
    private let topLine = SeparatorView(), bottomLine = SeparatorView()
    private let empty = StateView(.empty), indexing = StateView(.indexing)
    private let imageState = ImageStateView()
    let facePicker = FacePickerBar(frame: .zero)
    private var imagePicking = false
    private var imageOpenPanel: NSOpenPanel?
    private var imageElapsedMs: Double = 0
    private let videoPlayback = VideoPlaybackCoordinator()
    private var findSimilarBusy = false
    private var jointDebounce: DispatchWorkItem?
    private var jointDebouncing = false
    private var jointQueryPending = false
    private var jointStartedAt: Date?
    private var jointMode: JointQueryMode?
    private var jointFallback: JointQueryFallback?
    /// 面板真实可见态（show/hide 钩子维护）。后台索引刷新时 `window.isVisible` 可能瞬时为 false，
    /// 不能拿它决定后台 OCR 是否让路，否则面板开着也会恢复抽取。
    private var panelVisible = false
    let syntax = SyntaxReference(frame: .zero)
    private(set) var syntaxVisible = false
    private var diagnostics: [QueryDiagnostic] = []
    private var snapshotNoAccess = false
    private let snapshot: Bool
    private let preferences: UserDefaults
    private let queue = DispatchQueue(label: "com.oiloil.find.search", qos: .userInteractive)
    private let generation = SearchGeneration(), cache = SearchCache()
    private var timer: Timer?
    private var stateView: NSView?
    private var languageObserver: NSObjectProtocol?
    private var menuTracking = false, dragging = false
    private var trashing: Set<URL> = []
    private var selectionAnchor: (sourceID: String, store: IndexStore, id: UInt32, path: String)?
    private var additionalSearchFailed = false
    private var additionalPending = false
    private var pendingNewSearch: Bool?
    private var zeroFeedbackWork: DispatchWorkItem?
    private var zeroFeedbackQuery: String?
    private var lastZeroFeedbackQuery: String?
    private(set) var browsingResults = false
    var previewWithSpace: Bool { preferences.object(forKey: "previewWithSpace") as? Bool ?? true }
    private func setBrowsing(_ browsing: Bool) {
        browsingResults = browsing
        footer.spacePreview = browsing && previewWithSpace
    }
    var manager: IndexManager?
    var supplementaryProvider: SupplementarySearchProvider? {
        didSet {
            imageProvider?.onImageQueryChange = { [weak self] in self?.imageQueryDidChange() }
            if isViewLoaded {
                syncImagePreview()
                updateImageEntryVisibility()
            }
        }
    }
    private var imageProvider: ImageQuerySearchProvider? { supplementaryProvider as? ImageQuerySearchProvider }
    private func syncImagePreview() {
        searchField.imagePreview = imageProvider?.imagePreview
        searchField.personPreview = imageProvider?.isPersonQueryActive ?? false
        refreshFacePicker()
    }

    private func refreshFacePicker() {
        guard isViewLoaded else { return }
        let previews = imageProvider?.personFacePreviews ?? []
        let personActive = imageProvider?.isPersonQueryActive == true
        imageState.personMode = personActive
        let active = personActive && previews.count > 1
        facePicker.configure(previews: previews,
                             selected: imageProvider?.selectedPersonFaceIndex ?? 0)
        facePicker.isHidden = !active
        view.needsLayout = true
    }
    private var jointProvider: JointImageSearchProvider? { supplementaryProvider as? JointImageSearchProvider }
    private var imageModeActive: Bool { imageProvider?.imagePreview != nil }
    private var jointText: String { searchField.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var jointActive: Bool { imageModeActive && !jointText.isEmpty }
    private var imageQueryBusy: Bool {
        if findSimilarBusy || jointDebouncing || jointQueryPending { return true }
        if imageProvider?.imageQueryPhase.isBusy == true { return true }
        return jointActive && jointProvider?.jointQueryPhase.isBusy == true
    }
    /// 打开前预检（SMB 服务端存活）。nil = 不预检；返回 false 时面板保持可见并提示来源不可用。
    var sourceReachability: ((SearchSource) -> Bool)?
    var additionalSearchProvider: AdditionalSearchProvider? {
        didSet {
            oldValue?.onChange = nil; oldValue?.visibilityChanged(false)
            additionalSearchProvider?.onChange = { [weak self] in self?.additionalChanged() }
            if isViewLoaded { additionalChanged() }
        }
    }
    private func refreshAdditionalFilter() {
        guard isViewLoaded else { return }
        filters.additionalTitle = additionalSearchProvider?.isEnabled == true ? additionalSearchProvider?.title : nil
        searchField.placeholder = filters.additionalSelected ? additionalSearchProvider?.placeholder : nil
        updateImageEntryVisibility()
    }
    private func additionalChanged() {
        refreshAdditionalFilter()
        _ = generation.next(); results.cancelPendingRefresh(); results.cancelPress()
        if additionalSearchProvider?.isEnabled != true { additionalPending = false }
        if let provider = additionalSearchProvider, let result = results.result,
           let filtered = result.removingUnavailableAdditionalItems(using: provider, options: filters.options) {
            results.refresh(filtered, applyingAvailabilityImmediately: true)
            resultDidChange(filtered)
        }
        if view.window?.isVisible == true { startSearch(preserveSelection: true) }
    }
    func panelDidHide() {
        panelVisible = false
        additionalSearchProvider?.visibilityChanged(false)
        // 隐藏后保留宽限：用户很可能正在等 Preview/Finder 打开刚选中的文件。
        supplementaryProvider?.userActivity(visible: false, typing: false)
    }
    private let additionalQueue = DispatchQueue(label: "com.oiloil.find.additional", qos: .userInitiated)
    private let supplementQueue = DispatchQueue(label: "com.oiloil.find.supplement", qos: .userInteractive)
    var additionalSources: (() -> [SearchSource])?
    private var sourceCaches: [String: SearchCache] = [:]
    private var sourceCacheStores: [String: ObjectIdentifier] = [:]
    private var searchSources: [SearchSource] {
        let primary = manager?.store.map { SearchSource(id: "startup", displayName: "", isOnline: true, store: $0) }
        return primary.map { [$0] + (additionalSources?() ?? []) } ?? (additionalSources?() ?? [])
    }
    func sourcesChanged() {
        refreshAdditionalFilter()
        refreshProgress()
        syncImagePreview()
        updateImageEntryVisibility()
        supplementaryProvider?.sourcesDidChange(searchSources)
        _ = generation.next(); results.cancelPendingRefresh(); results.cancelPress()
        if supplementaryProvider?.isEnabled != true, let result = results.result, result.hasSupplements {
            let base = result.withoutSupplements()
            let row = results.selectedItem.flatMap { base.index(sourceID: $0.source.id, store: $0.source.store, id: $0.id, path: $0.path) } ?? 0
            present(base, selection: row, resetScroll: false)
        }
        // Invalidate displayed actions immediately, including while the panel is hidden.
        if results.selectedItem?.source.isOnline != true { quickLook.close() }
        if let presented = results.result, let multi = presented.multiple {
            let current = Set(searchSources.map(\.id))
            if multi.sources.contains(where: { !current.contains($0.id) }) && current.isEmpty {
                results.clear(preservingViewport: true); setState(.empty)
                footer.text = L10n.text("footer.results", Presentation.countText(0), Presentation.elapsedText(0))
            }
        }
        results.localize()
        startSearch(preserveSelection: true)
    }
    var forceEntryIcons = false

    var hidePanel: (() -> Void)?
    var onSettings: (() -> Void)?
    init(snapshot: Bool, preferences: UserDefaults = .standard) {
        self.snapshot = snapshot
        self.preferences = preferences
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() { view = PanelSurface(snapshot: snapshot) }
    override func viewDidLoad() {
        super.viewDidLoad()
        [searchField, topLine, filters, facePicker, results, empty, indexing, imageState, bottomLine, footer, syntax].forEach(view.addSubview)
        syntax.isHidden = true
        imageState.isHidden = true
        facePicker.isHidden = true
        syntax.onExample = { [weak self] example in
            guard let self else { return }
            if self.imageModeActive {
                self.imageProvider?.clearImageQuery(); self.syncImagePreview()
            }
            self.setBrowsing(false); self.searchField.text = example; self.toggleSyntax(false); self.searchField.focus(); self.startSearch()
        }
        (view as? PanelSurface)?.onImageDrop = { [weak self] source in self?.acceptImageSource(source) ?? false }
        searchField.onSelectionChange = { [weak self] in
            guard let self, !self.imageModeActive else { return }
            self.refreshDiagnostics()
        }
        searchField.onChange = { [weak self] in
            guard let self else { return }
            if self.imageModeActive {
                // 参考图存在时继续输入 = 图 + 文联合查询，绝不清掉图片。
                // IME 组合中的半截中文不触发查询，等上屏后的 change 再走。
                guard !self.searchField.editor.hasMarkedText() else { return }
                self.imageElapsedMs = 0
                self.jointDebounce?.cancel()
                _ = self.generation.next()
                self.results.cancelPendingRefresh(); self.results.cancelPress()
                if self.jointText.isEmpty {
                    self.jointDebouncing = false
                    self.jointStartedAt = nil
                    self.startSearch()
                } else {
                    // 防抖期间保留上一轮结果 + 显示 analyzing；代次已推进，旧结果不得回写。
                    if self.jointStartedAt == nil { self.jointStartedAt = Date() }
                    self.jointDebouncing = true
                    self.footer.warning = false
                    self.footer.text = L10n.text("footer.jointAnalyzing")
                    self.refreshProgress()
                    let work = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        self.jointDebouncing = false
                        self.startSearch()
                    }
                    self.jointDebounce = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)
                }
                return
            }
            self.setBrowsing(false); self.startSearch()
        }
        searchField.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        searchField.onPickImage = { [weak self] in self?.pickImageFile() }
        searchField.onClearImage = { [weak self] in self?.clearImageQuery() }
        imageState.onChooseImage = { [weak self] in self?.pickImageFile() }
        searchField.onPickPerson = { [weak self] in self?.pickPersonFile() }
        facePicker.onSelect = { [weak self] index in
            guard let self, let provider = self.imageProvider else { return }
            provider.selectPersonFace(index)
            self.refreshFacePicker()
            self.startSearch(preserveSelection: true)
        }
        imageState.onOpenSettings = { [weak self] in self?.onSettings?() }
        imageProvider?.onImageQueryChange = { [weak self] in self?.imageQueryDidChange() }
        filters.onChange = { [weak self] in
            guard let self else { return }
            if self.filters.additionalSelected, self.imageModeActive {
                self.jointDebounce?.cancel(); self.jointDebouncing = false
                self.jointMode = nil; self.jointFallback = nil
                self.imageProvider?.clearImageQuery()
                self.syncImagePreview()
            }
            self.refreshAdditionalFilter(); self.updateImageEntryVisibility(); self.searchField.focus(); self.startSearch()
        }
        filters.onSortChange = { [weak self] in
            guard let self, !self.snapshot else { return }
            UserDefaults.standard.set(FilterBar.sortName(self.filters.options.sort), forKey: "sortKey")
            UserDefaults.standard.set(self.filters.options.ascending, forKey: "sortAscending")
        }
        filters.onMenuTracking = { [weak self] tracking in
            self?.menuTracking = tracking
            if !tracking { self?.hideIfInactive() }
        }
        if !snapshot { results.currentSource = { [weak self] id in self?.searchSources.first { $0.id == id } } }
        results.onPointerSelection = { [weak self] in self?.setBrowsing(true) }
        results.onOpen = { [weak self] in self?.openSelected() }
        results.onSelection = { [weak self] in
            self?.quickLook.refresh()
            self?.footer.fileActions = self?.results.selectedAdditional == nil
            if let self, let item = self.results.selectedItem {
                self.selectionAnchor = (item.source.id, item.source.store, item.id, item.path)
            }
        }
        results.onContextMenu = { [weak self] _ in self?.contextMenu() }
        results.onRefreshApplied = { [weak self] result in self?.resultDidChange(result) }
        results.onDragging = { [weak self] active in
            self?.dragging = active
            if !active { self?.hideIfInactive() }
        }
        quickLook.selectedURL = { [weak self] in
            guard let self, self.results.selectedItem?.source.isOnline == true else { return nil }
            return self.selectedURL
        }
        quickLook.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        footer.onSettings = { [weak self] in self?.onSettings?() }
        languageObserver = NotificationCenter.default.addObserver(forName: L10n.changed, object: nil, queue: .main) { [weak self] _ in self?.localize() }
        setState(.indexing)
        if !snapshot {
            filters.options = SettingsPreferences.searchOptions()
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.refreshProgress() }
        }
        localize()
        refreshAdditionalFilter()
        syncImagePreview()
        updateImageEntryVisibility()
    }
    deinit {
        timer?.invalidate()
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
    }
    private func localize() {
        footer.spacePreview = browsingResults && previewWithSpace
        filters.localize(); footer.localize(); empty.localize(); indexing.localize(); syntax.localize(); results.localize()
        imageState.localize()
        facePicker.localize()
        searchField.localize()
        refreshAdditionalFilter()
        if let result = results.result { updateFooter(result) }
        else if stateView === indexing { footer.text = L10n.text("footer.indexing", Presentation.countText(indexing.count)) }
        refreshProgress()
        view.needsLayout = true
    }
    override func viewDidLayout() {
        super.viewDidLayout()
        let w = view.bounds.width, h = view.bounds.height, px = Theme.pixel(view)
        searchField.frame = NSRect(x: 0, y: 0, width: w, height: 64)
        topLine.frame = NSRect(x: 0, y: 64, width: w, height: px)
        filters.frame = NSRect(x: 0, y: 64 + px, width: w, height: 40)
        var top: CGFloat = 104 + px
        if !facePicker.isHidden {
            facePicker.frame = NSRect(x: 0, y: top, width: w, height: 56)
            top += 56
        }
        let region = NSRect(x: 0, y: top, width: w, height: max(0, h - top - 34 - px))
        [results, empty, indexing, syntax, imageState].forEach { $0.frame = region }
        bottomLine.frame = NSRect(x: 0, y: h - 34 - px, width: w, height: px)
        footer.frame = NSRect(x: 0, y: h - 34, width: w, height: 34)
    }
    func setState(_ state: StateView.State?) {
        setDisplayed(state == .empty ? empty : state == .indexing ? indexing : nil)
    }
    private func setDisplayed(_ target: NSView?) {
        _ = view
        let previous: NSView = stateView ?? (results as NSView)
        stateView = target
        let targetView: NSView = target ?? (results as NSView)
        footer.actionable = !syntaxVisible && stateView == nil && (results.result?.total ?? 0) > 0
        guard previous !== targetView else { return }
        let animate = !snapshot && view.window?.isVisible == true
        for item in [results, empty, indexing, imageState] as [NSView] {
            let visible = item === targetView
            if visible { item.isHidden = false }
            Theme.Motion.opacity(item, to: visible ? 1 : 0, using: animate ? Theme.Motion.basic(Theme.Motion.crossfade) : nil)
            if !visible {
                if animate {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.crossfade) { [weak self, weak item] in
                        guard let self, let item else { return }
                        let current: NSView = self.stateView ?? (self.results as NSView)
                        if item !== current { item.isHidden = true }
                    }
                } else { item.isHidden = true }
            }
        }
    }
    func panelWillShow() {
        panelVisible = true
        additionalSearchProvider?.visibilityChanged(true)
        setBrowsing(false)
        syncImagePreview()
        updateImageEntryVisibility()
        supplementaryProvider?.userActivity(visible: true, typing: false)
        let currentQuery = Query.parse(searchField.text, store: manager?.store)
        let sources = searchSources
        if additionalSearchProvider?.isEnabled != true { additionalPending = false }
        if !imageModeActive, additionalSearchProvider?.isEnabled != true, let result = results.result, result.isCurrent(sources),
           (result.single != nil || result.multiple != nil || sources.isEmpty),
           result.query.raw == currentQuery.raw, !currentQuery.isTimeDependent,
           Date().timeIntervalSince(result.createdAt) <= 600 { return }
        startSearch(preserveSelection: true)
    }
    func indexChanged() {
        refreshProgress()
        supplementaryProvider?.sourcesDidChange(searchSources)
        guard view.window?.isVisible == true else { return }
        // 扫描期间索引通知可能每秒一次；图片/联合查询在途时不要推进代次，
        // 否则远端图片/文本向量化永远跑不完（2026-10-31 实弹：footer 永远“正在联合检索”）。
        if imageModeActive && imageQueryBusy { return }
        refreshSearch()
    }
    func managerStateChanged(_ state: IndexManager.State) {
        refreshProgress()
        if imageModeActive { return }
        if manager?.store == nil && !filters.additionalSelected && results.result?.hasAdditional != true { setState(.indexing) }
    }
    private func refreshProgress() {
        let imageBusy = imageQueryBusy
        if imageModeActive, jointActive, let started = jointStartedAt {
            footer.warning = false
            footer.text = L10n.text("footer.jointAnalyzingProgress",
                                    String(format: "%.1f", Date().timeIntervalSince(started)))
        }
        if let result = results.result, result.query.isEmpty, !imageModeActive { updateFooter(result) }
        searchField.indexing = imageBusy || additionalPending
        guard let manager else { return }
        supplementaryProvider?.backgroundIndexingChanged(manager.state == .loading || manager.state == .scanning || manager.isRescanning)
        additionalSearchProvider?.backgroundIndexingChanged(manager.state == .loading || manager.state == .scanning || manager.isRescanning)
        searchField.indexing = imageBusy || additionalPending || !filters.additionalSelected && (manager.state == .scanning || manager.isRescanning)
        if manager.store == nil && !filters.additionalSelected && !imageModeActive {
            let count = manager.scannedCount
            indexing.updateCount(count); footer.text = L10n.text("footer.indexing", Presentation.countText(count))
        }
    }
    func startSearch(preserveSelection: Bool = false) {
        if jointDebouncing {
            jointDebounce?.cancel()
            jointDebouncing = false
        }
        pendingNewSearch = preserveSelection
        results.cancelPendingRefresh()
        search(refresh: false, preserveSelection: preserveSelection)
    }
    private func refreshSearch() {
        // Index notifications must not turn an uncommitted user query into a refresh.
        if let preserveSelection = pendingNewSearch {
            search(refresh: false, preserveSelection: preserveSelection)
        } else if results.result == nil {
            startSearch()
        } else {
            search(refresh: true, preserveSelection: false)
        }
    }
    private func search(refresh: Bool, preserveSelection: Bool) {
        supplementaryProvider?.userActivity(visible: panelVisible, typing: !refresh && !preserveSelection)
        let token = generation.next()
        if imageModeActive {
            searchImage(token: token, refresh: refresh, preserveSelection: preserveSelection)
            return
        }
        let sources = filters.additionalSelected ? [] : searchSources
        let store = sources.first?.store
        var options = filters.options
        if !snapshot { options.pinyin = UserDefaults.standard.bool(forKey: "pinyinEnabled") }
        let query = editingQuery(store: store), previous = results.result
        let cancelled = { [generation] in !generation.current(token) }
        let supplementary = filters.additionalSelected ? nil : supplementaryProvider?.prepareSearch(query, options: options, sources: sources, isCancelled: cancelled)
        let additional = additionalSearchProvider.flatMap { provider in
            provider.isEnabled && (filters.additionalSelected || options.kind == nil) ? provider.prepareSearch(query, isCancelled: cancelled) : nil
        }
        additionalSearchFailed = false
        additionalPending = additional != nil
        if sources.isEmpty && additional == nil {
            pendingNewSearch = nil
            results.clear(preservingViewport: true)
            setState(manager != nil && manager?.store == nil ? .indexing : .empty)
            footer.text = L10n.text("footer.results", Presentation.countText(0), Presentation.elapsedText(0))
            refreshProgress(); return
        }
        refreshProgress()
        let additionalBox = AdditionalSearchBox()
        let group = DispatchGroup()
        let box = SupplementarySearchBox()
        if let supplementary {
            group.enter()
            supplementQueue.async { box.hits = supplementary(); group.leave() }
        }
        if let additional {
            group.enter()
            additionalQueue.async {
                let began = CFAbsoluteTimeGetCurrent()
                do { additionalBox.items = try additional() } catch { additionalBox.failed = true }
                additionalBox.elapsedMs = (CFAbsoluteTimeGetCurrent() - began) * 1000
                group.leave()
            }
        }
        let anchor = refresh || preserveSelection ? selectionAnchor : nil
        queue.async { [weak self] in
            guard let self, self.generation.current(token) else { return }
            let found: SearchPresentation
            if sources.isEmpty { found = SearchPresentation(query: query) }
            else if sources.count == 1 && sources[0].id == "startup", let store {
                if !self.sourceCaches.isEmpty { self.sourceCaches.removeAll(); self.sourceCacheStores.removeAll() }
                if previous?.single?.store !== store { self.cache.removeAll() }
                guard let result = self.cache.lookup(query: query, options: options, store: store)
                    ?? Searcher.search(query, options: options, in: store, previous: previous?.single, isCancelled: { !self.generation.current(token) }), self.generation.current(token) else { return }
                self.cache.insert(result); found = SearchPresentation(result)
            } else {
                if previous?.single != nil { self.cache.removeAll() }
                self.sourceCaches = self.sourceCaches.filter { key, _ in sources.contains { $0.id == key } }
                self.sourceCacheStores = self.sourceCacheStores.filter { key, _ in sources.contains { $0.id == key } }
                for source in sources {
                    let identity = ObjectIdentifier(source.store)
                    if self.sourceCacheStores[source.id] != identity {
                        self.sourceCaches[source.id] = SearchCache(); self.sourceCacheStores[source.id] = identity
                    }
                }
                guard let result = MultiSearcher.search(query, options: options, in: sources, previous: previous?.multiple, caches: self.sourceCaches, isCancelled: { !self.generation.current(token) }), self.generation.current(token) else { return }
                found = SearchPresentation(result)
            }
            let anchoredRow = anchor.flatMap { found.index(sourceID: $0.sourceID, store: $0.store, id: $0.id, path: $0.path) }
            let row = anchoredRow ?? 0
            let deferNames = sources.isEmpty && additional != nil || previous?.query.raw == query.raw && ((refresh || preserveSelection) && previous?.hasAdditional == true || anchor != nil && anchoredRow == nil && supplementary != nil)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation.current(token) else { return }
                self.diagnostics = query.diagnostics
                if deferNames { return }
                if refresh {
                    self.results.refresh(found)
                } else {
                    self.pendingNewSearch = nil
                    if preserveSelection, self.results.result != nil { self.results.refresh(found) }
                    else { self.present(found, selection: row, resetScroll: !preserveSelection) }
                }
            }
            if supplementary != nil || additional != nil {
                group.notify(queue: self.queue) { [weak self] in
                    guard let self, self.generation.current(token) else { return }
                    if additional == nil && box.hits.isEmpty && !deferNames { return }
                    let files = box.hits.isEmpty ? found : found.supplement(box.hits, options: options)
                    let combined = files.including(additionalBox.items, options: options, elapsedMs: additionalBox.elapsedMs)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation.current(token), combined.isCurrent(self.searchSources) else { return }
                        self.pendingNewSearch = nil; self.additionalPending = false; self.additionalSearchFailed = additionalBox.failed
                        if additionalBox.failed, previous?.query.raw == query.raw, previous?.hasAdditional == true {
                            self.refreshProgress()
                            self.footer.warning = true; self.footer.text = self.additionalSearchProvider?.status ?? L10n.text("search.failed")
                            return
                        }
                        if sources.isEmpty && !refresh && !preserveSelection { self.present(combined) }
                        else { self.results.refresh(combined) }
                        if additionalBox.failed { self.footer.warning = true; self.footer.text = L10n.text("search.failed") }
                    }
                }
            }
        }
    }
    // MARK: - 以图搜图

    /// 图片/联合模式：结果全部来自向量命中（无文件名基座）。向量化在后台，先显示分析中；
    /// 完成经 provider 的 onImageQueryChange / onJointQueryComplete 触发重跑，第二轮走引擎缓存即时出结果。
    private func searchImage(token: Int, refresh: Bool, preserveSelection: Bool) {
        guard let provider = imageProvider else { return }
        additionalPending = false
        additionalSearchFailed = false
        let sources = searchSources
        let options = filters.options
        let cancelled = { [generation] in !generation.current(token) }
        let term = jointText
        let joint = (term.isEmpty || provider.isPersonQueryActive) ? nil : jointProvider
        jointQueryPending = joint != nil
        if joint != nil {
            if jointStartedAt == nil { jointStartedAt = Date() }
            footer.warning = false
            footer.text = L10n.text("footer.jointAnalyzing")
        } else {
            jointStartedAt = nil
        }
        refreshProgress()
        let box = ImageSearchBox()
        box.joint = joint != nil
        let began = CFAbsoluteTimeGetCurrent()
        supplementQueue.async {
            if let joint {
                let result = joint.jointImageHits(for: term, sources: sources, kind: options.kind, isCancelled: cancelled)
                box.hits = result.hits
                box.jointPhase = result.phase
            } else {
                let result = provider.imageQueryHits(for: sources, kind: options.kind, isCancelled: cancelled)
                box.hits = result.hits
                box.phase = result.phase
            }
            box.elapsedMs = (CFAbsoluteTimeGetCurrent() - began) * 1000
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation.current(token) else { return }
                self.applyImageSearch(box, sources: sources, options: options,
                                      refresh: refresh, preserveSelection: preserveSelection)
            }
        }
    }

    private func applyImageSearch(_ box: ImageSearchBox, sources: [SearchSource], options: SearchOptions,
                                  refresh: Bool, preserveSelection: Bool) {
        imageElapsedMs = box.elapsedMs
        syncImagePreview()
        pendingNewSearch = nil
        diagnostics = []
        let base = SearchPresentation(sources: sources, query: Query.parse(""))
        // 相关度=相似度顺序；用户切换名称/时间/大小排序时按该列重排（排序菜单不是死控件）。
        let combined = base.supplement(box.hits, options: options, preserveHitOrder: options.sort == .relevance)
        // 以图/联合结果来自向量命中，扫描期间 store.version 会持续变化，不能用 isCurrent 的版本相等
        // 把整批结果丢掉（用户只看到“正在联合检索…”却永远不刷新）。只有来源集合被替换（增删/重绑）
        // 才重跑；仅版本推进时照常展示。
        guard combined.sameStores(as: searchSources) else {
            AppLog.logger.info("image/joint results dropped: source set changed, retrying")
            startSearch(preserveSelection: true)
            return
        }
        jointQueryPending = false
        jointStartedAt = nil
        if box.joint {
            applyJointSearch(box, combined: combined, refresh: refresh, preserveSelection: preserveSelection)
            return
        }
        jointMode = nil; jointFallback = nil
        switch box.phase {
        case .analyzing, .unavailable, .failed:
            results.clear(preservingViewport: true)
            imageState.configure(box.phase)
            setDisplayed(imageState)
            updateFooter(combined)
        case .ready(let count):
            if count == 0 {
                results.clear(preservingViewport: true)
                imageState.configure(.ready(0))
                setDisplayed(imageState)
                updateFooter(combined)
            } else {
                setDisplayed(nil)
                if refresh { results.refresh(combined) }
                else { present(combined, selection: 0, resetScroll: !preserveSelection) }
            }
        case .idle:
            results.clear(preservingViewport: true)
            setDisplayed(nil)
        }
        refreshProgress()
    }

    private func applyJointSearch(_ box: ImageSearchBox, combined: SearchPresentation,
                                  refresh: Bool, preserveSelection: Bool) {
        jointMode = nil; jointFallback = nil
        switch box.jointPhase {
        case .analyzing:
            // 防抖/向量化期间保留上一轮结果，不显示“无结果”；footer + 进度环表示 analyzing。
            if (results.result?.total ?? 0) > 0 {
                updateFooter(combined)
            } else {
                results.clear(preservingViewport: true)
                imageState.configure(.analyzing)
                setDisplayed(imageState)
                updateFooter(combined)
            }
        case .unavailable(let reason):
            results.clear(preservingViewport: true)
            imageState.configure(.unavailable(reason))
            setDisplayed(imageState)
            updateFooter(combined)
        case .failed(let reason):
            results.clear(preservingViewport: true)
            imageState.configure(.failed(reason))
            setDisplayed(imageState)
            updateFooter(combined)
        case .ready(let count, let mode, let fallback):
            jointMode = mode; jointFallback = fallback
            if count == 0 {
                results.clear(preservingViewport: true)
                imageState.configure(.ready(0))
                setDisplayed(imageState)
                updateFooter(combined)
            } else {
                setDisplayed(nil)
                if refresh { results.refresh(combined) }
                else { present(combined, selection: 0, resetScroll: !preserveSelection) }
            }
        case .idle:
            results.clear(preservingViewport: true)
            setDisplayed(nil)
        }
        refreshProgress()
    }

    private func imageQueryDidChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.syncImagePreview()
            self.updateImageEntryVisibility()
            // 正在防抖时不抢跑：等用户停手后由 debounce 统一发联合查询。
            if self.jointDebouncing { self.refreshProgress(); return }
            if self.imageModeActive || self.results.result != nil { self.startSearch(preserveSelection: true) }
            self.refreshProgress()
        }
    }

    private func updateImageEntryVisibility() {
        guard isViewLoaded else { return }
        if forceEntryIcons {
            searchField.imageEntryVisible = true
            searchField.personEntryVisible = true
            return
        }
        let enabled: Bool
        switch imageProvider?.imageEntryAvailability ?? .unavailable("") {
        case .available, .unknown: enabled = true
        case .unavailable: enabled = false
        }
        searchField.imageEntryVisible = enabled && !snapshot && !filters.additionalSelected
            && supplementaryProvider?.isEnabled == true
        let personEnabled: Bool
        switch imageProvider?.personEntryAvailability ?? .unavailable("") {
        case .available, .unknown: personEnabled = true
        case .unavailable: personEnabled = false
        }
        searchField.personEntryVisible = personEnabled && !snapshot && !filters.additionalSelected
            && supplementaryProvider?.isEnabled == true
    }

    /// Finder 服务入口：用外部图片作为新的参考图，清空旧文字并回到“全部”类别。
    /// 文件读取仍走 acceptImageSource 的后台看门狗，主线程不碰 SMB/NAS I/O。
    func prepareFinderServiceImage(_ url: URL) {
        _ = view
        jointDebounce?.cancel(); jointDebouncing = false; jointQueryPending = false
        jointStartedAt = nil
        jointMode = nil; jointFallback = nil
        setBrowsing(false)
        if syntaxVisible { toggleSyntax(false) }
        searchField.text = ""
        if filters.additionalSelected || filters.options.kind != nil {
            filters.select(0, notify: false)
            refreshAdditionalFilter()
            updateImageEntryVisibility()
        }
        _ = acceptImageSource(.file(url))
    }

    private func acceptImageSource(_ source: ImagePasteSource) -> Bool {
        switch source {
        case .data(let data):
            return acceptImageData(data)
        case .file(let url):
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let data = ImagePasteboard.readData(at: url)
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let data { _ = self.acceptImageData(data) }
                    else { self.footer.warning = true; self.footer.text = L10n.text("image.readFailed") }
                }
            }
            return true
        }
    }

    @discardableResult
    private func acceptImageData(_ data: Data) -> Bool {
        guard let provider = imageProvider, provider.acceptImageQuery(data) else {
            footer.warning = true; footer.text = L10n.text("image.readFailed")
            return false
        }
        setBrowsing(false)
        imageElapsedMs = 0
        jointDebounce?.cancel(); jointDebouncing = false
        jointMode = nil; jointFallback = nil
        if syntaxVisible { toggleSyntax(false) }
        // M0.7b：粘贴新图片保留当前文字，立即按“新图 + 文字”联合查询。
        if filters.options.sort != .relevance {
            filters.options.sort = .relevance; filters.options.ascending = false
        }
        if filters.additionalSelected || (filters.options.kind != nil && filters.options.kind != 4 && filters.options.kind != 5) {
            filters.select(0, notify: false)
            refreshAdditionalFilter()
            updateImageEntryVisibility()
        }
        syncImagePreview()
        searchField.focus()
        startSearch()
        return true
    }

    private func acceptPersonSource(_ source: ImagePasteSource) -> Bool {
        switch source {
        case .data(let data):
            return acceptPersonData(data)
        case .file(let url):
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let data = ImagePasteboard.readData(at: url)
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let data { _ = self.acceptPersonData(data) }
                    else { self.footer.warning = true; self.footer.text = L10n.text("image.readFailed") }
                }
            }
            return true
        }
    }

    @discardableResult
    private func acceptPersonData(_ data: Data) -> Bool {
        guard let provider = imageProvider, provider.acceptPersonQuery(data) else {
            footer.warning = true; footer.text = L10n.text("image.readFailed")
            return false
        }
        setBrowsing(false)
        imageElapsedMs = 0
        jointDebounce?.cancel(); jointDebouncing = false
        jointQueryPending = false
        jointStartedAt = nil
        jointMode = nil; jointFallback = nil
        searchField.text = ""
        if filters.options.sort != .relevance {
            filters.options.sort = .relevance; filters.options.ascending = false
        }
        if filters.additionalSelected || filters.options.kind != nil {
            filters.select(0, notify: false)
            refreshAdditionalFilter()
            updateImageEntryVisibility()
        }
        syncImagePreview()
        searchField.focus()
        startSearch()
        return true
    }

    private func pickPersonFile() {
        guard !imagePicking, imageProvider != nil, view.window != nil else { return }
        imagePicking = true
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = L10n.text("image.personPick")
        panel.level = .modalPanel
        imageOpenPanel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard let self else { return }
            self.imagePicking = false
            self.imageOpenPanel = nil
            let restore = self.view.window?.isVisible == true && (self.view.window as? SearchPanel)?.hiding != true
            if restore {
                self.view.window?.makeKeyAndOrderFront(nil)
                self.searchField.focus()
            }
            guard response == .OK, let url = panel.url else { return }
            _ = self.acceptPersonSource(.file(url))
        }
    }

    private func pickImageFile() {
        guard !imagePicking, imageProvider != nil, view.window != nil else { return }
        imagePicking = true
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = L10n.text("image.pickPrompt")
        // 搜索面板是 floating level；文件面板不抬高就会被压在下面，
        // 用户看到的是“面板关不掉”，实际是文件选择器藏在后面。
        panel.level = .modalPanel
        imageOpenPanel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard let self else { return }
            self.imagePicking = false
            self.imageOpenPanel = nil
            let restore = self.view.window?.isVisible == true && (self.view.window as? SearchPanel)?.hiding != true
            if restore {
                self.view.window?.makeKeyAndOrderFront(nil)
                self.searchField.focus()
            }
            guard response == .OK, let url = panel.url else { return }
            _ = self.acceptImageSource(.file(url))
        }
    }

    /// 面板被 hide 时取消尚未结束的文件选择，避免留下一个孤立的 NSOpenPanel。
    func cancelImagePickerForHide() {
        guard imagePicking else { return }
        imageOpenPanel?.cancel(nil)
    }

    private func clearImageQuery() {
        jointDebounce?.cancel(); jointDebouncing = false
        jointQueryPending = false
        jointStartedAt = nil
        jointMode = nil; jointFallback = nil
        imageProvider?.clearImageQuery()
        syncImagePreview()
        setDisplayed(nil)
        updateImageEntryVisibility()
        startSearch()
        searchField.focus()
    }

    func present(_ result: SearchResult, selection: Int = 0, resetScroll: Bool = true) { present(SearchPresentation(result), selection: selection, resetScroll: resetScroll) }
    func present(_ result: SearchPresentation, selection: Int = 0, resetScroll: Bool = true) {
        results.show(result, selection: selection, resetScroll: resetScroll)
        resultDidChange(result)
    }
    private func editingQuery(store: IndexStore?) -> Query {
        Query.parse(searchField.text, store: store, editingRange: searchField.input.currentEditor() == nil ? nil : searchField.editor.selectedRange(), isComposing: searchField.editor.hasMarkedText(), pathExists: { [self] path in
            if searchSources.contains(where: { source in source.store.read { source.store.containsPath(path) } }) { return true }
            var info = stat(); return path.withCString { stat($0, &info) == 0 }
        })
    }
    private func refreshDiagnostics() {
        guard !imageModeActive else { return }
        let query = editingQuery(store: manager?.store ?? results.result?.store)
        guard let result = results.result, result.query.raw == query.raw else { return }
        diagnostics = query.diagnostics
        configureEmpty(result); updateFooter(result)
    }
    private func configureEmpty(_ result: SearchPresentation) {
        empty.configure(diagnostic: diagnostics.first, hasNoAccess: snapshotNoAccess || result.sources.contains { source in source.store.read { source.store.coverage[.noAccess].count > 0 } })
    }
    func toggleSyntax(_ show: Bool? = nil) {
        let visible = show ?? !syntaxVisible
        syntaxVisible = visible
        footer.actionable = !visible && stateView == nil && (results.result?.total ?? 0) > 0
        syntax.isHidden = false
        Theme.Motion.opacity(syntax, to: visible ? 1 : 0, using: snapshot ? nil : Theme.Motion.chip)
        if let layer = syntax.layer { Theme.Motion.animate(layer, "transform.translation.y", to: visible ? 0 : 8, using: snapshot ? nil : Theme.Motion.chip) }
        if !visible {
            if snapshot { syntax.isHidden = true }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.chip.settlingDuration) { [weak self] in if self?.syntaxVisible == false { self?.syntax.isHidden = true } } }
        }
    }
    private func resultDidChange(_ result: SearchPresentation) {
        if imageModeActive {
            updateImageState(result)
            updateFooter(result)
            refreshProgress()
            return
        }
        configureEmpty(result)
        setState(result.total == 0 ? .empty : nil)
        updateFooter(result)
        refreshProgress()
        scheduleZeroFeedback(result)
    }
    private func updateImageState(_ result: SearchPresentation) {
        if jointActive, let phase = jointProvider?.jointQueryPhase {
            switch phase {
            case .analyzing:
                imageState.configure(.analyzing); setDisplayed(imageState)
            case .unavailable(let reason):
                imageState.configure(.unavailable(reason)); setDisplayed(imageState)
            case .failed(let reason):
                imageState.configure(.failed(reason)); setDisplayed(imageState)
            case .ready(let count, _, _) where count == 0 || result.total == 0:
                imageState.configure(.ready(0)); setDisplayed(imageState)
            default:
                setDisplayed(nil)
            }
            return
        }
        let phase = imageProvider?.imageQueryPhase ?? .idle
        switch phase {
        case .analyzing, .unavailable, .failed:
            imageState.configure(phase); setDisplayed(imageState)
        case .ready(let count) where count == 0 || result.total == 0:
            imageState.configure(.ready(0)); setDisplayed(imageState)
        default:
            setDisplayed(nil)
        }
    }

    // MARK: - 本地搜索反馈（A0-a-2 真值：查询→相关文件 / 零结果召回缺口）
    // 只记用户真正采取行动的查询，不记键入中间态；快照渲染与用户关闭开关时不写。

    private func scheduleZeroFeedback(_ result: SearchPresentation) {
        guard !imageModeActive else {
            zeroFeedbackWork?.cancel(); zeroFeedbackWork = nil; zeroFeedbackQuery = nil
            return
        }
        let raw = result.query.raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !snapshot, SearchFeedback.isEnabled, raw.count >= 2, result.total == 0, raw != lastZeroFeedbackQuery else {
            zeroFeedbackWork?.cancel(); zeroFeedbackWork = nil; zeroFeedbackQuery = nil
            return
        }
        // 同一查询的重复刷新（索引通知/进度回调会高频触发）不重置计时器，
        // 否则后台扫描期间零结果事件永远等不到 4 秒静置（2026-10-22 实弹）。
        if zeroFeedbackQuery == raw, let work = zeroFeedbackWork, !work.isCancelled { return }
        zeroFeedbackWork?.cancel()
        zeroFeedbackQuery = raw
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // 4s 静置后仍为零：容忍内容通道异步追加（OCR 毫秒级、语义二波秒级）。
            guard self.results.result?.query.raw.trimmingCharacters(in: .whitespacesAndNewlines) == raw,
                  self.results.result?.total == 0 else { return }
            self.lastZeroFeedbackQuery = raw
            SearchFeedback.shared.logZero(query: raw, kind: self.filters.options.kind)
        }
        zeroFeedbackWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    /// 命中通道：补充命中按详情前缀归类，其余视为文件名命中。
    private func feedbackChannel(for item: ResultItem) -> String {
        switch item.detail?.detail {
        case let detail? where detail.hasPrefix("【语义"): return "semantic"
        case let detail? where detail.hasPrefix("【视频帧"): return "video"
        case let detail? where detail.hasPrefix("【图片OCR"): return "ocr"
        case let detail? where detail.hasPrefix("【正文"): return "text"
        default: return "name"
        }
    }

    /// 记录一次「用户确实用了这条结果」。必须在打开/定位成功之后调用。
    private func logResultAction(_ event: String) {
        guard !snapshot, SearchFeedback.isEnabled,
              let presented = results.result, let item = results.selectedItem else { return }
        let query = presented.query.raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        let rank = results.selectedRow + 1
        let channel = feedbackChannel(for: item)
        let count = presented.total
        let kind = filters.options.kind
        if event == "reveal" {
            SearchFeedback.shared.logReveal(query: query, path: item.path, rank: rank,
                                            channel: channel, count: count, kind: kind)
        } else {
            SearchFeedback.shared.logOpen(query: query, path: item.path, rank: rank,
                                          channel: channel, count: count, kind: kind)
        }
    }
    private func updateFooter(_ result: SearchPresentation) {
        if imageModeActive {
            footer.warning = false
            if jointActive, let phase = jointProvider?.jointQueryPhase {
                switch phase {
                case .analyzing:
                    footer.text = L10n.text("footer.jointAnalyzing")
                case .unavailable(let reason), .failed(let reason):
                    footer.warning = true; footer.text = reason
                case .ready(_, let mode, let fallback):
                    jointMode = mode; jointFallback = fallback
                    var text = L10n.text("footer.jointResults", Presentation.countText(result.total),
                                         Presentation.elapsedText(imageElapsedMs))
                    if let fallback { text += " · " + L10n.text(Self.fallbackMessageKey(fallback)) }
                    footer.text = text
                case .idle:
                    footer.text = ""
                }
                return
            }
            switch imageProvider?.imageQueryPhase ?? .idle {
            case .analyzing:
                footer.text = L10n.text(imageProvider?.isPersonQueryActive == true ? "footer.personAnalyzing" : "footer.imageAnalyzing")
            case .unavailable(let reason), .failed(let reason):
                footer.warning = true; footer.text = reason
            case .ready:
                footer.text = L10n.text(imageProvider?.isPersonQueryActive == true ? "footer.personResults" : "footer.imageResults",
                                        Presentation.countText(result.total), Presentation.elapsedText(imageElapsedMs))
            case .idle:
                footer.text = ""
            }
            return
        }
        footer.warning = !diagnostics.isEmpty
        if let diagnostic = diagnostics.first { footer.text = L10n.diagnostic(diagnostic); return }
        if additionalSearchFailed { footer.warning = true; footer.text = L10n.text("search.failed"); return }
        if filters.additionalSelected {
            footer.text = L10n.text("footer.results", Presentation.countText(result.total), Presentation.elapsedText(result.elapsedMs))
            if let status = additionalSearchProvider?.status { footer.text = status }
        } else if result.query.isEmpty {
            let count = Presentation.countText(result.sources.reduce(0) { count, source in count + source.store.read { source.store.liveCount } })
            footer.text = L10n.text("footer.recent", count)
        } else {
            footer.text = L10n.text(result.sortedCount < result.total ? "footer.partial" : "footer.results", Presentation.countText(result.total), Presentation.elapsedText(result.elapsedMs))
        }
    }
    private static func fallbackMessageKey(_ fallback: JointQueryFallback) -> String {
        switch fallback {
        case .textNoMatch: return "image.textNoMatch"
        case .textVectorUnavailable, .fusionUnavailable: return "image.textVectorUnavailable"
        case .searchFailed: return "image.jointSearchFailed"
        }
    }

    /// 调试快照：以图搜图状态（参考图 + 真实向量命中 + 视频时间码）。不走面板热路径。
    func prepareImageSnapshot(imageURL: URL, store: IndexStore?, additionalSources: [SearchSource], selection: Int) throws {
        _ = view
        guard let data = try? Data(contentsOf: imageURL) else {
            throw SnapshotError.failed("Cannot read image: \(imageURL.path)")
        }
        guard let provider = imageProvider, provider.acceptImageQuery(data) else {
            throw SnapshotError.failed("Cannot decode image: \(imageURL.path)")
        }
        let sources = store.map { [SearchSource(id: "startup", displayName: "", isOnline: true, store: $0)] + additionalSources } ?? additionalSources
        self.additionalSources = { sources }
        filters.options = SearchOptions(sort: .relevance, ascending: false, kind: nil)
        syncImagePreview()
        let token = generation.next()
        searchImage(token: token, refresh: false, preserveSelection: false)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if case .ready = provider.imageQueryPhase { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        if case .ready(0) = provider.imageQueryPhase {
            throw SnapshotError.failed("Image search returned no hits")
        }
    }

    func prepareSnapshot(state: String, query: String, options: SearchOptions, store: IndexStore?, selection: Int, additionalSources: [SearchSource] = [], additionalOnly: Bool = false) throws {
        _ = view
        searchField.text = state == "recent" ? "" : query; filters.options = options
        if state == "indexing" {
            setState(.indexing); indexing.updateCount(1_234_567); searchField.indexing = true
            footer.text = L10n.text("footer.indexing", Presentation.countText(1_234_567)); return
        }
        if additionalOnly || additionalSearchProvider?.isEnabled == true {
            if additionalOnly { filters.select(FilterBar.names.count, notify: false); refreshAdditionalFilter() }
            _ = generation.next(); pendingNewSearch = nil
            let query = Query.parse(searchField.text, store: store)
            let sources = additionalOnly ? [] : store.map { [SearchSource(id: "startup", displayName: "", isOnline: true, store: $0)] + additionalSources } ?? additionalSources
            let files: SearchPresentation
            if sources.isEmpty { files = SearchPresentation(query: query) }
            else if let found = MultiSearcher.search(query, options: options, in: sources) {
                let hits = supplementaryProvider?.prepareSearch(query, options: options, sources: sources, isCancelled: { false })() ?? []
                files = hits.isEmpty ? SearchPresentation(found) : SearchPresentation(found).supplement(hits, options: options)
            } else { throw SnapshotError.failed("Cannot search snapshot index") }
            let began = CFAbsoluteTimeGetCurrent()
            let items = additionalOnly || options.kind == nil ? try additionalSearchProvider?.prepareSearch(query, isCancelled: { false })() ?? [] : []
            diagnostics = query.diagnostics; present(files.including(items, options: options, elapsedMs: (CFAbsoluteTimeGetCurrent() - began) * 1000), selection: selection); return
        }
        if let store, let supplementaryProvider {
            let sources = [SearchSource(id: "startup", displayName: "", isOnline: true, store: store)] + additionalSources
            let query = Query.parse(searchField.text, store: store)
            let hits = supplementaryProvider.prepareSearch(query, options: options, sources: sources, isCancelled: { false })()
            guard let found = MultiSearcher.search(query, options: options, in: sources) else { throw SnapshotError.failed("Cannot search snapshot index") }
            diagnostics = query.diagnostics; present(SearchPresentation(found).supplement(hits, options: options), selection: selection); return
        }
        if let store, !additionalSources.isEmpty, let found = MultiSearcher.search(Query.parse(searchField.text, store: store), options: options, in: [SearchSource(id: "startup", displayName: "", isOnline: true, store: store)] + additionalSources) {
            diagnostics = found.query.diagnostics; present(SearchPresentation(found), selection: selection); return
        }
        guard let store, let found = Searcher.search(Query.parse(searchField.text, store: store), options: options, in: store) else { throw SnapshotError.failed("Cannot search snapshot index") }
        diagnostics = Query.parse(searchField.text, store: store).diagnostics
        snapshotNoAccess = state == "no-access"
        present(found, selection: selection)
        if state == "syntax" { toggleSyntax(true) }
        if state == "toast", let item = results.selectedItem { footer.showToast(.copiedPath, value: item.path, snapshot: true) }
        if state == "empty" {
            setState(.empty)
            footer.text = L10n.text("footer.results", Presentation.countText(0), Presentation.elapsedText(found.elapsedMs))
        }
    }
    private var selectedURL: URL? {
        guard stateView == nil else { return nil }
        return results.selectedItem.map { URL(fileURLWithPath: $0.path) }
    }
    func handleKey(_ event: NSEvent) -> Bool {
        if (view.window as? SearchPanel)?.hiding == true { return true }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command), option = flags.contains(.option)
        if searchField.editor.hasMarkedText() { return false }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        // 以图搜图：剪贴板里是图片文件或截图时接管 ⌘V；普通文字仍走标准粘贴。
        if command, key == "v", flags.intersection([.control, .option, .shift]).isEmpty,
           let source = ImagePasteboard.pasteSource() {
            return acceptImageSource(source)
        }
        // A nonactivating panel has no Edit menu to dispatch text shortcuts.
        if flags.intersection([.command, .control, .option, .shift]) == .command,
           let editor = searchField.input.currentEditor() {
            switch key {
            case "a": editor.selectAll(nil); return true
            case "c" where editor.selectedRange.length > 0: editor.copy(nil); return true
            case "x": editor.cut(nil); return true
            case "v": editor.paste(nil); return true
            default: break
            }
        }
        if command && event.keyCode == 44 { toggleSyntax(); return true }
        if syntaxVisible && event.keyCode == 53 { toggleSyntax(false); return true }
        if syntaxVisible { return false }
        if [126, 125, 116, 121, 115, 119].contains(event.keyCode) { setBrowsing(true) }
        if event.keyCode == 49 && flags.intersection([.command, .control, .option, .shift]).isEmpty && browsingResults && previewWithSpace {
            previewSelected(); return true
        }
        switch event.keyCode {
        case 115: results.select(0, repeatKey: event.isARepeat); return true
        case 119: results.select((results.result?.count ?? 1) - 1, repeatKey: event.isARepeat); return true
        case 126: if command { results.select(0, repeatKey: event.isARepeat) } else { results.move(-1, repeatKey: event.isARepeat) }; return true
        case 125: if command { results.select((results.result?.count ?? 1) - 1, repeatKey: event.isARepeat) } else { results.move(1, repeatKey: event.isARepeat) }; return true
        case 116: results.page(-1, repeatKey: event.isARepeat); return true
        case 121: results.page(1, repeatKey: event.isARepeat); return true
        case 36, 76: if command { revealSelected() } else { openSelected() }; return true
        case 48: filters.cycle(flags.contains(.shift) ? -1 : 1); return true
        case 53:
            if imagePicking {
                imageOpenPanel?.cancel(nil)
            } else if quickLook.isVisible {
                quickLook.close()
            } else {
                hidePanel?()
            }
            return true
        case 51 where command: trashSelected(); return true
        default: break
        }
        guard command else { return false }
        switch key {
        case "y": previewSelected(); return true
        case "c":
            if option { copyName(); return true }
            if searchField.input.currentEditor()?.selectedRange.length ?? 0 > 0 { return false }
            copyPath(); return true
        case "w": hidePanel?(); return true
        case ",": onSettings?(); return true
        case "1"..."9": filters.select((Int(key) ?? 1) - 1); return true
        default: return false
        }
    }
    private func openSelected(fromStart: Bool = false) {
        if let item = results.selectedAdditional { performAdditional(item, kind: .open); return }
        guard stateView == nil, (view.window as? SearchPanel)?.hiding != true,
              let item = results.selectedItem else { return }
        let url = URL(fileURLWithPath: item.path)
        guard allowOnlineAction() else { return }
        // 双击/回车 = 跳到命中时间点；右键“从头播放”与无时码视频 = 普通打开。
        let seekMs = !fromStart && item.kind == 5 ? item.detail?.mediaStartMs : nil
        results.pressOpen { [weak self] in
            guard let self, self.allowOnlineAction() == true else { return }
            // 网盘文件：不在主线程 stat/open——同步 fileExists + NSWorkspace.open 会卡住整个面板；
            // 交给 LaunchServices 异步打开，失败只 beep，不再阻塞 UI。
            self.logResultAction("open")
            self.hidePanel?()
            guard let seekMs else {
                self.openWithSystemPlayer(url)
                return
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let outcome = self.videoPlayback.open(url: url, startMs: seekMs)
                DispatchQueue.main.async { self.reportVideoPlayback(outcome) }
            }
        }
    }
    private func openWithSystemPlayer(_ url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(url, configuration: configuration) { _, error in
            if error != nil { DispatchQueue.main.async { NSSound.beep() } }
        }
    }
    private func reportVideoPlayback(_ outcome: VideoPlaybackOutcome) {
        let bundle = outcome.playerBundleID ?? "nil"
        NSLog("astfind video-open player=%@ kind=%@ reason=%@", bundle,
              String(describing: outcome.kind), String(describing: outcome.reason))
        switch outcome.kind {
        case .sought:
            break
        case .standard:
            if outcome.reason == .notQuickTime { footer.showNote(L10n.text("video.notQuickTime")) }
            if outcome.reason == .automationDenied { footer.showNote(L10n.text("video.seekFailed")) }
        case .fallback:
            footer.showNote(L10n.text("video.seekFailed"))
        }
    }

    // MARK: - 找相似（M0.7a）

    private func findSimilarSelected() {
        guard stateView == nil, let item = results.selectedItem else { return }
        guard allowOnlineAction() else { return }
        switch item.kind {
        case 4:
            findSimilar(imageAt: item)
        case 5:
            guard let mediaStartMs = item.detail?.mediaStartMs else {
                footer.showNote(L10n.text("image.frameReadFailed"))
                return
            }
            findSimilar(videoFrameAt: item, mediaStartMs: mediaStartMs)
        default:
            break
        }
    }

    private func findSimilar(imageAt item: ResultItem) {
        guard !findSimilarBusy else { return }
        findSimilarBusy = true
        footer.showNote(L10n.text("image.reading"))
        refreshProgress()
        let url = URL(fileURLWithPath: item.path)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let began = CFAbsoluteTimeGetCurrent()
            let data = ImagePasteboard.readData(at: url, timeout: 15)
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - began) * 1000
            DispatchQueue.main.async {
                guard let self else { return }
                self.findSimilarBusy = false
                self.refreshProgress()
                NSLog("astfind find-similar source=image elapsedMs=%.0f ok=%@", elapsedMs, data == nil ? "false" : "true")
                guard let data else {
                    self.footer.showNote(L10n.text("image.readFailed"))
                    return
                }
                _ = self.acceptImageData(data)
            }
        }
    }

    private func findSimilar(videoFrameAt item: ResultItem, mediaStartMs: Int) {
        guard !findSimilarBusy else { return }
        findSimilarBusy = true
        footer.showNote(L10n.text("image.frameExtracting"))
        refreshProgress()
        let url = URL(fileURLWithPath: item.path)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let began = CFAbsoluteTimeGetCurrent()
            let result = VideoFrameExtractor.jpegData(path: url.path, atMs: mediaStartMs)
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - began) * 1000
            DispatchQueue.main.async {
                guard let self else { return }
                self.findSimilarBusy = false
                self.refreshProgress()
                switch result {
                case .success(let data):
                    NSLog("astfind find-similar source=video elapsedMs=%.0f startMs=%ld ok=true", elapsedMs, mediaStartMs)
                    _ = self.acceptImageData(data)
                case .failure(let failure):
                    NSLog("astfind find-similar source=video elapsedMs=%.0f startMs=%ld ok=false reason=%@",
                          elapsedMs, mediaStartMs, String(describing: failure))
                    self.footer.showNote(L10n.text("image.frameReadFailed"))
                }
            }
        }
    }
    private func revealSelected() {
        guard stateView == nil, let url = selectedURL, allowOnlineAction() else { return }
        logResultAction("reveal")
        hidePanel?()
        DispatchQueue.global(qos: .userInitiated).async {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
    @discardableResult
    private func allowOnlineAction() -> Bool {
        guard let item = results.selectedItem else { return false }
        // Check the live provider as well as the submitted snapshot during an in-flight refresh.
        let current = searchSources.first { $0.id == item.source.id }
        // 扫描/重扫未完成时 isOnline 保守为 false，但挂载其实可读；打开动作以真实可达性为准。
        let probed = !snapshot && sourceReachability != nil
        let reachable = probed ? sourceReachability!(item.source) : item.source.isOnline
        // SMB 挂载点可能还在、服务端已经失联：此时 open 会把用户扔进分钟级内核等待。
        guard snapshot || reachable, snapshot || current?.isOnline == true || (probed && reachable) else {
            footer.warning = true; footer.actionable = false
            footer.text = L10n.text("source.unavailable", item.source.displayName)
            return false
        }
        return snapshot || current?.store === item.source.store
    }
    private func previewSelected() { if allowOnlineAction() { quickLook.toggle() } }
    private func copyPath() {
        if let item = results.selectedAdditional { performAdditional(item, kind: .copy); return }
        guard stateView == nil, let url = selectedURL else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([url as NSURL]); NSPasteboard.general.setString(url.path, forType: .string)
        footer.showToast(.copiedPath, value: url.path)
    }
    private func copyName() {
        if let item = results.selectedAdditional { performAdditional(item, kind: .copyName); return }
        guard stateView == nil, let item = results.selectedItem else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.name, forType: .string)
        footer.showToast(.copiedName, value: item.name)
    }
    private func trashSelected() {
        guard stateView == nil, let url = selectedURL, let item = results.selectedItem else { return }
        guard allowOnlineAction(), FileManager.default.fileExists(atPath: url.path), trashing.insert(url).inserted else { return }
        NSWorkspace.shared.recycle([url]) { [weak self] _, error in
            DispatchQueue.main.async {
                self?.trashing.remove(url)
                if error != nil { NSSound.beep() }
                else { self?.footer.showToast(.trashed, value: item.name) }
            }
        }
    }
    private func performAdditional(_ item: AdditionalSearchItem, kind: AdditionalSearchAction.Kind) {
        guard pendingNewSearch == nil, stateView == nil, results.result?.query.raw == searchField.text, additionalSearchProvider?.isEnabled == true,
              let action = item.actions.first(where: { $0.kind == kind }) else { return }
        let perform = { [weak self] in
            guard let self, self.results.selectedAdditional?.id == item.id, self.additionalSearchProvider?.isEnabled == true else { return }
            self.runAdditional(action)
        }
        if kind == .open { results.pressOpen(perform) } else { perform() }
    }
    private func runAdditional(_ action: AdditionalSearchAction) {
        guard additionalSearchProvider?.isEnabled == true, pendingNewSearch == nil else { return }
        action.perform { [weak self] success in
            guard let self else { return }
            if success { if action.kind == .open { self.hidePanel?() } }
            else { self.footer.warning = true; self.footer.text = L10n.text("search.actionFailed") }
        }
    }
    @objc private func additionalContextAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? AdditionalSearchAction else { return }; runAdditional(action)
    }
    private func contextMenu() -> NSMenu {
        let menu = NSMenu(); menu.delegate = self
        if let selected = results.selectedAdditional {
            for action in selected.actions {
                let item = NSMenuItem(title: action.title, action: #selector(additionalContextAction(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = action; menu.addItem(item)
            }
            return menu
        }
        let selected = results.selectedItem
        let isVideo = selected?.kind == 5
        let mediaStartMs = selected?.detail?.mediaStartMs
        let online = selected?.source.isOnline == true
        func add(_ action: ContextAction, enabled: Bool = true) {
            let item = NSMenuItem(title: L10n.text(action.key), action: #selector(contextAction(_:)), keyEquivalent: "")
            item.target = self; item.tag = action.rawValue; item.isEnabled = enabled
            if !enabled, let selected, !selected.source.isOnline {
                item.toolTip = L10n.text("source.unavailable", selected.source.displayName)
            }
            menu.addItem(item)
        }
        add(.open)
        if isVideo && mediaStartMs != nil { add(.playFromStart) }
        // 只有图片结果、带时间码的视频帧命中才显示“找相似”；离线来源读不到原文件，置灰。
        let canFindSimilar = selected != nil && (selected?.kind == 4 || (isVideo && mediaStartMs != nil))
        if selected?.kind == 4 || isVideo {
            add(.findSimilar, enabled: canFindSimilar && online)
        }
        add(.reveal)
        add(.preview)
        menu.addItem(.separator())
        add(.copyPath)
        add(.copyName)
        menu.addItem(.separator())
        add(.trash, enabled: online)
        return menu
    }
    private enum ContextAction: Int {
        case open, playFromStart, findSimilar, reveal, preview, copyPath, copyName, trash
        var key: String {
            switch self {
            case .open: return "ctx.open"
            case .playFromStart: return "ctx.playFromStart"
            case .findSimilar: return "ctx.findSimilar"
            case .reveal: return "ctx.reveal"
            case .preview: return "ctx.preview"
            case .copyPath: return "ctx.copyPath"
            case .copyName: return "ctx.copyName"
            case .trash: return "ctx.trash"
            }
        }
    }
    @objc private func contextAction(_ item: NSMenuItem) {
        guard let action = ContextAction(rawValue: item.tag) else { return }
        switch action {
        case .open: openSelected()
        case .playFromStart: openSelected(fromStart: true)
        case .findSimilar: findSimilarSelected()
        case .reveal: revealSelected()
        case .preview: previewSelected()
        case .copyPath: copyPath()
        case .copyName: copyName()
        case .trash: trashSelected()
        }
    }
    func menuWillOpen(_ menu: NSMenu) { menuTracking = true }
    func menuDidClose(_ menu: NSMenu) { menuTracking = false; hideIfInactive() }
    private func hideIfInactive() {
        if view.window?.isKeyWindow == false && !quickLook.isVisible && !menuTracking && !dragging && !imagePicking { hidePanel?() }
    }
    func windowDidResignKey(_ notification: Notification) {
        // Quick Look visibility settles after the key-window transition.
        DispatchQueue.main.async { [weak self] in self?.hideIfInactive() }
    }
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        (client as? NSTextField) === searchField.input ? searchField.editor : nil
    }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { selectedURL != nil }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { quickLook.begin(panel) }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { quickLook.end(panel) }
}
