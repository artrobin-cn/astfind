import Foundation
import AppKit
import ImageIO
import OilFindCore
import AstfindPanel
import AstfindFaceCore

/// 统一搜索引擎：Registry + ScanScheduler（D4 起 session 归调度器所有，避免双写快照）。
///
/// 启动语义（离线优先，D1/D2/D5 结论固化）：
/// 1. `start()` 对全部来源做**离线快照加载**（每源 ~70ms，零源 I/O）——立即全源可搜；
///    首扫来源在引导期以"块"为单位逐步可搜（部分可查，D4）；
/// 2. 挂载可达的来源由调度器后台扫描/周期重扫，完成即通知 UI；
/// 3. `isOnline == false` 的来源在 oil-find 面板中可见但禁打开。
public final class AstfindEngine {
    private let registry: SourceRegistry
    private let snapshotDirectory: URL
    private let scheduler: ScanScheduler
    private let volumeResolver: VolumeIdentityResolving
    /// SMB 共享身份解析（R1）：挂载表反查 smb://host/share；注入式，测试模拟挂载点漂移。
    private let smbResolver: SMBShareResolving
    /// A1 Provider 骨架：向量/ASR Provider 登记处（默认空=零影响）；配置在 ASTFIND_HOME/providers.json。
    public let providers: ProviderHub
    /// A2 图片语义：向量入库/检索（同一 registry 库，独立连接）。
    public let semantic: EmbeddingIndexer?
    /// 内容索引（D6：OCR/PDF/纯文本 → 中文 FTS）。独立连接（WAL + busy_timeout），
    /// 低优先级批处理——与文件名搜索热路径零交集。
    public let content: ContentIndexer?
    /// M0.8b 人脸索引（独立表/任务；模型由用户按许可放置）。
    public let face: FaceIndexer?
    /// 全局人物检索开关（默认关闭）；来源还需单独 face_index_enabled。
    public private(set) var faceSearchEnabled: Bool
    /// 人物检索相似度阈值；越低召回越多、误报也越多。
    public private(set) var faceMinScore: Double
    private let faceHome: URL
    private var lock = NSLock()   // 仅保护 started 一次性标志
    private var observers: [NSObjectProtocol] = []
    private var started = false

    // MARK: 可达性缓存
    // sources() 被面板高频拉取（每次击键 + 索引进度轮询 ~2Hz）。挂载探测曾直接对
    // NAS 路径同步 fileExists——SMB 往返会卡住主线程输入。可达性是外部状态：
    // 缓存 + 后台 TTL 重验 + 变化才通知，热路径零文件系统 I/O。
    private let reachabilityQueue = DispatchQueue(label: "astfind.reachability", qos: .utility)
    private let reachabilityLock = NSLock()
    private var mountedCache: [String: Bool] = [:]
    private var reachabilityRefreshPending = false
    /// 可注入（测试）：挂载点可达性探测与重验间隔
    public var reachabilityProbe: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    public var reachabilityTTL: TimeInterval = 1.5
    /// SMB 服务端存活探测（测试可注入）。挂载点仍在 ≠ 服务端还活着：
    /// NAS 掉线后 smbfs 会保留挂载点，read 却卡在内核 TCP 重传上。
    public var smbServerProbe: (String) -> Bool = { SMBServerProbe.isReachable(host: $0) }
    private struct SMBHealth { let reachable: Bool; let at: Date }
    private var smbHealth: [String: SMBHealth] = [:]
    private let smbHealthLock = NSLock()
    /// 在线时 5s 复验；离线时 30s 才重试——NAS 掉线期间不要每轮都做 mDNS/TCP 探测。
    private static let smbOnlineTTL: TimeInterval = 5
    private static let smbOfflineTTL: TimeInterval = 30

    /// M0.6 前台活动协调：面板/搜索/QuickLook/打开/定位统一成可查询的交互状态。
    /// 保留 `setInteractive(visible:typing:)` 作为 M0.6 与 M0.7 的兼容接口。
    private let foregroundActivity = ForegroundActivityCoordinator()
    private let scanPacing: ScanPacingController
    private let interactionLogLock = NSLock()
    private var lastInteractionLog = ""
    /// 因来源失联而被引擎暂停的源；恢复时只恢复这些，绝不误恢复用户手动暂停。
    private var healthPausedSources: Set<String> = []
    private let healthPausedLock = NSLock()

    /// 来源列表或其在线状态变化时回调（主线程不保证——UI 层自行 dispatch）。
    public var onSourcesChange: (() -> Void)?

    public init(databaseURL: URL, snapshotDirectory: URL,
                budget: ScanScheduler.Budget = ScanScheduler.Budget(),
                volumeResolver: VolumeIdentityResolving = DefaultVolumeResolver(),
                smbResolver: SMBShareResolving = DefaultSMBShareResolver(),
                contentIndexer: ContentIndexer? = nil) throws {
        self.registry = try SourceRegistry(databaseURL: databaseURL)
        // home 是 App 专用数据目录：老版本可能以 0755 建过，显式收紧（只动这个专用目录，不动任意父目录）。
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: databaseURL.deletingLastPathComponent().path)
        self.snapshotDirectory = snapshotDirectory
        self.volumeResolver = volumeResolver
        self.smbResolver = smbResolver
        self.providers = ProviderHub(fileURL: databaseURL.deletingLastPathComponent().appendingPathComponent("providers.json"))
        self.semantic = try? EmbeddingIndexer(databaseURL: databaseURL)
        self.semanticFlag = UserDefaults.standard.bool(forKey: "astfindSemanticSearch")
        try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: snapshotDirectory.path)
        self.scanPacing = ScanPacingController(coordinator: foregroundActivity)
        self.scheduler = ScanScheduler(registry: registry, snapshotDirectory: snapshotDirectory, budget: budget,
                                       pacing: scanPacing)
        self.content = contentIndexer ?? (try? ContentIndexer(databaseURL: databaseURL))
        self.faceHome = databaseURL.deletingLastPathComponent()
        self.face = try? FaceIndexer(databaseURL: databaseURL)
        self.faceSearchEnabled = UserDefaults.standard.bool(forKey: "astfindFaceSearch")
        self.faceMinScore = Self.clampFaceMinScore(
            UserDefaults.standard.object(forKey: "astfindFaceMinScore") as? Double ?? 0.5)
        let storedLanes = UserDefaults.standard.object(forKey: "astfindContentLanes") as? Int ?? 2
        self.extractionLanes = min(4, max(1, storedLanes))
        // 视频帧 OCR 默认关（成本高，PRD 质量门禁）；用户开过则随应用域偏好恢复
        self.videoOCRFlag = UserDefaults.standard.bool(forKey: "astfindVideoOCR")
        if videoOCRFlag { try? self.content?.setVideoOCR(enabled: true) }
        try? self.content?.reclaimOrphanedJobs()
        scheduler.onProgress = { [weak self] progress in
            self?.handleSchedulerProgress(progress)
        }
        if faceSearchEnabled { _ = loadFaceEmbedder() }
    }

    /// 调度器进度：来源转为 ready（扫描收敛）后自动在后台排内容提取
    /// （D6 遗留的"扫描后自动排任务"——文件名/内容两条管线由此全自动闭环）。
    /// 每个来源每次 ready 只触发一次；周期重扫的重复触发由变更检测自然去重。
    /// 可关闭（内容机制类测试手动驱动时用）。
    public var autoExtractContent = true
    /// 内容抽取并发路数（1=省电 2=标准 4=全速；默认 2，用户可调，泵每轮读取即时生效）。
    public var extractionLanes: Int {
        didSet { extractionLanes = min(4, max(1, extractionLanes)) }
    }
    /// 视频帧 OCR（L2，动刀清单 2 号）：默认关。开启=为全部来源排队 mp4/mov/m4v 并踢泵；
    /// 关闭=热切换提取器并清掉未处理的视频任务（已识别的时间段观测保留）。
    private var videoOCRFlag: Bool
    public var videoOCREnabled: Bool { videoOCRFlag }
    public func setVideoOCR(enabled: Bool, persist: Bool = true) {
        videoOCRFlag = enabled
        if persist { UserDefaults.standard.set(enabled, forKey: "astfindVideoOCR") }
        try? content?.setVideoOCR(enabled: enabled)
        AstfindAppExtension.log("video-ocr \(enabled ? "enabled" : "disabled")")
        guard enabled else { return }
        _ = try? content?.resetDoneJobs(extensions: VideoFrameOCRExtractor.supportedExtensions)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            _ = self?.extractContent(limit: 0)   // 只入队：视频走泵按源轮转，不抢图片批次
            self?.kickExtractionPump()
        }
    }

    // MARK: - 内容索引范围（按来源）

    /// 切换来源的内容索引。关闭时清理该来源未处理的 OCR/正文与语义任务；
    /// 已完成/失败记录保留；重新开启后会重新检查，未变更内容快速跳过。
    /// - Returns: 本次清理的 pending 任务数（关闭时）。
    @discardableResult
    public func setContentIndexEnabled(sourceId: String, enabled: Bool) throws -> Int {
        try registry.setContentIndexEnabled(sourceId: sourceId, enabled: enabled)
        var cleared = 0
        if enabled {
            if let content { _ = try? content.enqueuePending(sourceId: sourceId) }
            if semanticFlag, let semantic, let active = activeImageEmbedding() {
                try? semantic.ensureProfile(active.profile)
                _ = try? semantic.enqueuePending(sourceId: sourceId, profile: active.profile)
                _ = try? semantic.enqueuePendingVideos(sourceId: sourceId, profile: active.profile)
                kickEmbeddingPump()
            }
            kickExtractionPump()
        } else {
            cleared = (try? content?.clearPending(sourceId: sourceId)) ?? 0
            _ = try? semantic?.clearPending(sourceId: sourceId)
        }
        Self.trace("content-index source=\(sourceId) enabled=\(enabled) cleared=\(cleared)")
        notifyChange()
        return cleared
    }

    // MARK: - M0.8b 人脸索引（骨架）

    public struct FaceStatus: Equatable, Sendable {
        public var enabled = false
        public var modelAvailable = false
        public var minScore: Double = 0.5
        public var counts = FaceIndexer.Counts()
        public var embeddings = 0
        public var enabledSources = 0
    }

    private static func clampFaceMinScore(_ value: Double) -> Double {
        min(0.9, max(0.2, value))
    }

    public func setFaceMinScore(_ value: Double) {
        faceMinScore = Self.clampFaceMinScore(value)
        UserDefaults.standard.set(faceMinScore, forKey: "astfindFaceMinScore")
        Self.trace("face min-score=\(faceMinScore)")
    }

    /// 权重不随 App 分发；用户按许可放到此路径。
    public var faceModelURL: URL {
        faceHome.appendingPathComponent("models/buffalo_sc.mlmodelc")
    }

    public var faceModelAvailable: Bool {
        FileManager.default.fileExists(atPath: faceModelURL.path)
    }

    /// 加载本机 CoreML 模型；缺失/损坏返回 false（不阻塞现有搜索）。
    @discardableResult
    public func loadFaceEmbedder() -> Bool {
        guard let face else { return false }
        if face.embedder != nil { return true }
        guard faceModelAvailable else { return false }
        face.embedder = try? CoreMLFaceEmbedder(modelURL: faceModelURL)
        return face.embedder != nil
    }

    public func setFaceSearchEnabled(_ enabled: Bool) {
        faceSearchEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "astfindFaceSearch")
        Self.trace("face search enabled=\(enabled) model=\(faceModelAvailable)")
        if enabled {
            _ = loadFaceEmbedder()
            if let face {
                for record in (try? registry.sources()) ?? [] where record.faceIndexEnabled {
                    _ = try? face.enqueuePending(sourceId: record.sourceId)
                }
            }
            kickFaceIndexPump()
        } else {
            facePumpLock.lock()
            facePumpGeneration += 1
            facePumpLock.unlock()
        }
        notifyChange()
    }

    /// 人脸索引按来源独立开关；关闭时清理该来源未处理的 face_embed pending。
    @discardableResult
    public func setFaceIndexEnabled(sourceId: String, enabled: Bool) throws -> Int {
        try registry.setFaceIndexEnabled(sourceId: sourceId, enabled: enabled)
        var cleared = 0
        if enabled {
            _ = try? face?.enqueuePending(sourceId: sourceId)
            kickFaceIndexPump()
        } else {
            cleared = (try? face?.clearPending(sourceId: sourceId)) ?? 0
        }
        Self.trace("face-index source=\(sourceId) enabled=\(enabled) cleared=\(cleared)")
        notifyChange()
        return cleared
    }

    public enum FaceSearchError: Error, Equatable {
        case modelUnavailable
        case imageUnreadable
        case noFace
    }

    /// 检测参考图全部候选脸（按面积降序）；合影选择主脸用。
    public func faceCandidates(imageData: Data) throws -> [FaceCandidate] {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw FaceSearchError.imageUnreadable
        }
        do {
            return try VisionFacePreprocessor().candidates(image: image)
        } catch {
            throw FaceSearchError.noFace
        }
    }

    /// 对已选候选脸做 embedding + 本机索引查询（避免重复 Vision 检测）。
    public func faceSearch(candidate: FaceCandidate, limit: Int = 20,
                           minScore: Double = 0.5) throws -> [FaceIndexer.Hit] {
        guard let face else { throw FaceSearchError.modelUnavailable }
        if face.embedder == nil { _ = loadFaceEmbedder() }
        guard let embedder = face.embedder else { throw FaceSearchError.modelUnavailable }
        let vector = try embedder.embed(alignedImage: candidate.alignedImage)
        return try face.search(vector: vector, limit: limit, minScore: minScore)
    }

    /// 参考照片 → Vision 候选（默认最大脸）→ CoreML 向量 → 本机人脸索引。
    public func faceSearch(imageData: Data, faceIndex: Int = 0, limit: Int = 20,
                           minScore: Double = 0.5) throws -> [FaceIndexer.Hit] {
        let candidates = try faceCandidates(imageData: imageData)
        guard !candidates.isEmpty else { throw FaceSearchError.noFace }
        let index = min(max(0, faceIndex), candidates.count - 1)
        return try faceSearch(candidate: candidates[index], limit: limit, minScore: minScore)
    }

    public func faceSearch(imageURL: URL, faceIndex: Int = 0, limit: Int = 20,
                           minScore: Double = 0.5) throws -> [FaceIndexer.Hit] {
        guard let data = try? Data(contentsOf: imageURL) else {
            throw FaceSearchError.imageUnreadable
        }
        return try faceSearch(imageData: data, faceIndex: faceIndex, limit: limit, minScore: minScore)
    }

    /// 设置来源人脸索引范围（相对 source 根的路径前缀；nil/空 = 整个来源）。
    /// 会清理旧 pending 并按新范围入队；旧范围已生成向量由 search 过滤，不再返回。
    @discardableResult
    public func setFaceIndexPrefix(sourceId: String, prefix: String?) throws -> Int {
        try registry.setFaceIndexPrefix(sourceId: sourceId, prefix: prefix)
        let cleared = (try? face?.clearPending(sourceId: sourceId)) ?? 0
        if let record = try registry.source(id: sourceId), record.faceIndexEnabled {
            _ = try? face?.enqueuePending(sourceId: sourceId)
            kickFaceIndexPump()
        }
        Self.trace("face-index source=\(sourceId) prefix=\(prefix ?? "*") cleared=\(cleared)")
        notifyChange()
        return cleared
    }

    public func faceStatus() -> FaceStatus {
        var status = FaceStatus()
        status.enabled = faceSearchEnabled
        status.modelAvailable = faceModelAvailable
        status.minScore = faceMinScore
        if let face {
            status.counts = (try? face.counts()) ?? FaceIndexer.Counts()
            status.embeddings = (try? face.embeddingCount()) ?? 0
        }
        status.enabledSources = ((try? registry.sources()) ?? []).filter(\.faceIndexEnabled).count
        return status
    }

    private let facePumpLock = NSLock()
    private var facePumpGeneration = 0
    private var facePumpRunning = false

    /// 启动/保活人脸索引泵；模型未就绪或全局关闭时静默退出。
    public func kickFaceIndexPump() {
        guard faceSearchEnabled, let face, face.embedder != nil else { return }
        facePumpLock.lock()
        guard !facePumpRunning else { facePumpLock.unlock(); return }
        facePumpRunning = true
        facePumpGeneration += 1
        let generation = facePumpGeneration
        facePumpLock.unlock()
        Self.trace("face pump kicked gen=\(generation)")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.runFacePump(generation: generation)
        }
    }

    private func runFacePump(generation: Int) {
        defer {
            facePumpLock.lock()
            if facePumpGeneration == generation { facePumpRunning = false }
            facePumpLock.unlock()
        }
        guard let face else { return }
        while facePumpAlive(generation), faceSearchEnabled, face.embedder != nil {
            if isInteractive {
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }
            let sources = (try? face.pendingSourceIds()) ?? []
            if sources.isEmpty { break }
            var processed = 0
            for sourceId in sources {
                guard facePumpAlive(generation), !isInteractive else { break }
                let summary = try? face.runPending(limit: 25, sourceId: sourceId,
                                                   shouldPause: { [weak self] in self?.isInteractive ?? false })
                processed += summary?.processed ?? 0
            }
            Thread.sleep(forTimeInterval: processed > 0 ? 0.2 : 1.0)
        }
    }

    private func facePumpAlive(_ generation: Int) -> Bool {
        facePumpLock.lock(); defer { facePumpLock.unlock() }
        return facePumpGeneration == generation
    }

    // MARK: - A2 图片语义（向量入库泵 + 语义检索）
    // 默认关：开启=选用第一个经探测支持图片的 Provider 建 profile、为全部来源排队图片、踢嵌入泵；
    // 查询侧把查询文本发给同一 Provider（外发门已放行才可能走到这里）。

    private var semanticFlag: Bool
    public var semanticSearchEnabled: Bool { semanticFlag }

    /// 语义模型状态快照（只读缓存，绝不探测——设置页轮询可安全调用）。
    public func semanticStatus() -> ProviderHub.SemanticStatus { providers.semanticStatus() }

    /// 切换语义模型（关闭 / 远程 / 本地）。
    ///
    /// 只写配置并停掉入库泵——**不在这里开始建向量**：切换模型意味着全新的向量空间，
    /// 全量重嵌是数小时级动作，必须由用户显式打开「图片语义索引」开关（`setSemanticSearch(true)`）。
    /// 关闭同时停泵：语义通道整体退出，文件名/OCR/正文不受影响。
    public func setSemanticMode(_ mode: SemanticMode) throws {
        try providers.setSemanticMode(mode)
        AstfindAppExtension.log("semantic mode → \(mode.rawValue)")
        setSemanticSearch(enabled: false)   // 停泵 + 清语义查询缓存（持久化标志）
        clearImageQueryCache()
    }

    public func setSemanticSearch(enabled: Bool, persist: Bool = true) {
        semanticFlag = enabled
        if persist { UserDefaults.standard.set(enabled, forKey: "astfindSemanticSearch") }
        AstfindAppExtension.log("semantic-search \(enabled ? "enabled" : "disabled")")
        if enabled { kickEmbeddingPump(); warmImageQueryCapability() } else {
            embeddingPumpLock.lock(); embeddingGeneration += 1; embeddingPumpLock.unlock()
            semanticQueryLock.lock(); semanticQueryCache.removeAll(); semanticQueryLock.unlock()
            clearImageQueryCache()
        }
    }

    /// 语义入库进度（设置页展示）。只读已有探测缓存——**绝不在 UI 调用路径上探测**
    /// （activeImageEmbedding 未缓存时会同步探测 ≤10s，会卡设置页）。无可用 Provider 时返回 nil（UI 隐藏）。
    public struct EmbedProgress: Sendable, Equatable {
        public let providerId: String
        public let imageVectors: Int
        public let videoVectors: Int
        public let imageJobs: EmbeddingIndexer.Counts
        public let videoJobs: EmbeddingIndexer.Counts
    }

    public func embedProgress() -> EmbedProgress? {
        guard semanticFlag, let semantic else { return nil }
        for provider in providers.semanticEmbeddingProviders() {
            guard case .available(_, let caps)? = providers.lastProbe(id: provider.id),
                  caps.embedImage, let dims = caps.dimensions else { continue }
            let profile = semantic.resolveProfile(providerId: provider.id, model: caps.model ?? "unknown", dimension: dims)
            return EmbedProgress(
                providerId: provider.id,
                imageVectors: semantic.embeddingCount(profile: profile) - semantic.videoVectorCount(profile: profile),
                videoVectors: semantic.videoVectorCount(profile: profile),
                imageJobs: (try? semantic.counts()) ?? .init(),
                videoJobs: (try? semantic.videoCounts()) ?? .init())
        }
        return nil
    }

    /// 当前可用的图片向量 Provider 与其 profile（探测过且实测支持图片）；未探测则同步探一次（≤10s）。
    public func activeImageEmbedding() -> (provider: EmbeddingProvider, profile: EmbeddingIndexer.Profile)? {
        // 关闭 → 空；本地 → 只回环（永不外发）；远程 → 只非回环。筛选是发送边界，不只是 UI 偏好。
        for provider in providers.semanticEmbeddingProviders() {
            var probe = providers.lastProbe(id: provider.id)
            if probe == nil {
                let semaphore = DispatchSemaphore(value: 0)
                let box = ProbeBox()
                Task.detached { box.value = await provider.probe(); semaphore.signal() }
                _ = semaphore.wait(timeout: .now() + 10)
                probe = box.value
                if let probe { providers.record(probe: probe, id: provider.id) }
            }
            guard case .available(_, let caps)? = probe, caps.embedImage, let dims = caps.dimensions else { continue }
            let model = caps.model ?? "unknown"
            let profile = semantic?.resolveProfile(providerId: provider.id, model: model, dimension: dims)
                ?? .image(providerId: provider.id, model: model, dimension: dims)
            return (provider, profile)
        }
        return nil
    }
    final class ProbeBox: @unchecked Sendable { var value: ProviderProbe? }

    private let embeddingPumpLock = NSLock()
    private var embeddingGeneration = 0
    private var embeddingPumpRunning = false
    /// 用户正在搜索的时间窗（泵避让：搜索进行中入库让位，把远端 Provider 让给查询）
    private var embeddingPauseUntil = Date.distantPast

    /// 面板搜索进行中/刚结束（4s 窗口）：嵌入泵轮间避让，避免查询排在入库流量后（实测 7s）。
    public func noteSearchActivity() {
        embeddingPumpLock.lock(); embeddingPauseUntil = Date().addingTimeInterval(4); embeddingPumpLock.unlock()
    }
    private func embeddingPaused() -> Bool {
        embeddingPumpLock.lock(); defer { embeddingPumpLock.unlock() }; return Date() < embeddingPauseUntil
    }

    /// 启动/保活嵌入泵（幂等）。无可用图片 Provider 时静默退出（无 Provider 零影响）。
    public func kickEmbeddingPump() {
        embeddingPumpLock.lock()
        guard semanticFlag, !embeddingPumpRunning, semantic != nil else { embeddingPumpLock.unlock(); return }
        embeddingPumpRunning = true
        embeddingGeneration += 1
        let generation = embeddingGeneration
        embeddingPumpLock.unlock()
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.runEmbeddingPump(generation: generation) }
    }

    private func isEmbeddingPumpAlive(_ generation: Int) -> Bool {
        embeddingPumpLock.lock(); defer { embeddingPumpLock.unlock() }; return embeddingGeneration == generation
    }

    private func runEmbeddingPump(generation: Int) {
        defer { embeddingPumpLock.lock(); if embeddingGeneration == generation { embeddingPumpRunning = false }; embeddingPumpLock.unlock() }
        guard let semantic, let active = activeImageEmbedding() else {
            // 诊断：逐 Provider 记录探测结论（ATS 拦截/外发未授权/鉴权失败一眼可辨）
            for provider in providers.semanticEmbeddingProviders() {
                Self.trace("embed pump: provider \(provider.id) probe=\(providers.lastProbe(id: provider.id).map { "\($0)" } ?? "nil") egress=\(providers.egress.allowsRemote)")
            }
            Self.trace("embed pump: no image-capable provider; idle"); return
        }
        // 入队属于触发事件：泵启动时为全部来源补排一次（幂等、单查询+批量插入）——图片与视频帧
        try? semantic.ensureProfile(active.profile)
        for record in (try? registry.sources()) ?? [] where record.contentIndexEnabled {
            let n = (try? semantic.enqueuePending(sourceId: record.sourceId, profile: active.profile)) ?? 0
            let v = (try? semantic.enqueuePendingVideos(sourceId: record.sourceId, profile: active.profile)) ?? 0
            if n > 0 || v > 0 { Self.trace("embed enqueue src=\(record.sourceId.prefix(8)) +\(n)图 +\(v)视频") }
        }
        Self.trace("embed pump enter gen=\(generation) profile=\(active.profile.id)")
        var consecutiveTransient = 0
        while isEmbeddingPumpAlive(generation), semanticFlag {
            // 搜索/面板可见/刚打开文件：图片向量化也一起让路（同一 NAS 卷的随机读）。
            if embeddingPaused() || isInteractive { Thread.sleep(forTimeInterval: 0.5); continue }
            var processed = 0, transient = 0
            // 视频帧**独占**嵌入泵直到清空（2026-10-21 开发者指示：空闲期全力跑视频）——
            // 服务端 GPU 产能 ≈3 帧/s 本来就是视频吞吐上限，图片批次只会在 NAS 带宽/解码
            // CPU 上抢资源。图片队列量大不丢失，视频清空后自动恢复轮转。
            let videoSources = (try? semantic.videoPendingSourceIds()) ?? []
            for sourceId in videoSources {
                guard isEmbeddingPumpAlive(generation), semanticFlag else { Self.trace("embed pump exit gen=\(generation)"); return }
                let summary = (try? semantic.runPendingVideo(limit: 4, sourceId: sourceId, lanes: 3,
                                                             provider: active.provider, profile: active.profile)) ?? .init()
                processed += summary.embedded + summary.skippedUnchanged
                transient += summary.transientFailures
                recordThroughput(sourceId: "embed-video:" + sourceId, processed: summary.embedded)
                Self.trace("embed-video round src=\(sourceId.prefix(8)) embedded=\(summary.embedded) failed=\(summary.failed) transient=\(summary.transientFailures) quarantined=\(summary.quarantined) deferred=\(summary.deferredOffline)\(summary.lastFailure.map { " lastFailure=\($0)" } ?? "")")
            }
            let sources = videoSources.isEmpty ? (try? semantic.pendingSourceIds()) ?? [] : []
            if sources.isEmpty, videoSources.isEmpty { break }
            for sourceId in sources {
                guard isEmbeddingPumpAlive(generation), semanticFlag else { Self.trace("embed pump exit gen=\(generation)"); return }
                // 批量能力>1 时 runPending 内部流式攒批发请求（服务端 GPU 是瓶颈，WeMM 批量 32 ≈ 3 图/s 封顶）
                let summary = (try? semantic.runPending(limit: 25, sourceId: sourceId, lanes: extractionLanes,
                                                        provider: active.provider, profile: active.profile)) ?? .init()
                processed += summary.embedded + summary.skippedUnchanged
                transient += summary.transientFailures
                recordThroughput(sourceId: "embed:" + sourceId, processed: summary.embedded)
                Self.trace("embed round src=\(sourceId.prefix(8)) embedded=\(summary.embedded) unchanged=\(summary.skippedUnchanged) failed=\(summary.failed) transient=\(summary.transientFailures) quarantined=\(summary.quarantined) deferred=\(summary.deferredOffline)\(summary.lastFailure.map { " lastFailure=\($0)" } ?? "")")
            }
            // 环境类失败（服务端/超时）退避：连续空转越久退避越长，上限 5 分钟
            if processed == 0, transient > 0 {
                consecutiveTransient += 1
                Thread.sleep(forTimeInterval: min(300, 15 * pow(2, Double(consecutiveTransient - 1))))
            } else {
                consecutiveTransient = 0
                Thread.sleep(forTimeInterval: processed == 0 ? 1.0 : 0.1)
            }
        }
        Self.trace("embed pump exit gen=\(generation)")
    }

    /// 语义检索（阻塞封装）：查询文本 → 同 profile Provider 向量 → 本地余弦。无 Provider/关闭→空。
    /// - Parameter timeout: 远端文本向量化限时——面板热路径必须给短预算（默认 2s）：服务器被入库
    ///   占满时到点即放弃本轮语义命中，绝不拖死补充通道（2026-10-21 翻车实锤）。
    public func semanticSearch(_ text: String, limit: Int = 10, timeout: TimeInterval = 2) -> [EmbeddingIndexer.SemanticHit] {
        guard semanticFlag, let semantic, let active = activeImageEmbedding() else { return [] }
        let semaphore = DispatchSemaphore(value: 0)
        let box = VectorBox()
        let provider = active.provider
        Task.detached { box.value = try? await provider.embedText(text); semaphore.signal() }
        guard semaphore.wait(timeout: .now() + timeout) == .success, let vector = box.value else { return [] }
        return (try? semantic.search(queryVector: vector, profile: active.profile, limit: limit)) ?? []
    }
    final class VectorBox: @unchecked Sendable { var value: [Float]? }

    // MARK: - 以图搜图（M0.5）
    // 与文本语义共用同一条检索路径（embedText → embedImageData，其余完全相同）：
    // 图片向量与视频帧向量同处 embeddings 表，一次查询天然同时命中两种模态。
    // 图片向量化比文本慢（本地 ~1s / 远程 2–3s），查询必须走后台：先 .analyzing，完成回调宿主重跑。

    /// 图片查询完成（成功/失败/不可用都会回调，主线程）——面板据此重跑本轮以图搜图。
    public var onImageQueryComplete: (() -> Void)?
    /// 图文联合查询完成（成功/失败/不可用都会回调，主线程）——面板据此重跑本轮联合查询。
    public var onJointQueryComplete: (() -> Void)?
    public var imageQueryTimeout: TimeInterval = 10
    public static let imageQueryLimit = 24

    private struct ImageQueryEntry {
        let outcome: ImageQueryOutcome
        let at: Date
        let ttl: TimeInterval
    }
    private struct JointQueryEntry {
        let outcome: JointImageQueryOutcome
        let at: Date
        let ttl: TimeInterval
    }
    private struct VectorEntry {
        let vector: [Float]
        let at: Date
    }
    enum VectorResult: Equatable {
        case success([Float])
        case failure(String)
    }
    private let imageQueryLock = NSLock()
    private var imageQueryCache: [String: ImageQueryEntry] = [:]
    private var jointQueryCache: [String: JointQueryEntry] = [:]
    private var imageQueriesInFlight: Set<String> = []
    private var jointQueriesInFlight: Set<String> = []
    /// 图片向量按 digest 缓存：同一参考图改文字做联合查询不重复向量化。
    private var imageVectorCache: [String: VectorEntry] = [:]
    /// 文本向量按 profile + text 缓存：连续键入/缓存窗口内不重复远端请求。
    private var textVectorCache: [String: VectorEntry] = [:]
    /// 切换语义模型/关闭时自增：在途的旧模型结果不得回写新向量空间的查询缓存。
    private var imageQueryGeneration = 0
    private static let imageQueryCacheLimit = 16
    private static let jointQueryCacheLimit = 16
    private static let imageQuerySuccessTTL: TimeInterval = 60
    private static let imageQueryFailureTTL: TimeInterval = 5
    private static let imageVectorTTL: TimeInterval = 600
    private static let textVectorTTL: TimeInterval = 300
    private static let vectorCacheLimit = 32

    /// 只读缓存探测，绝不联网——可在 UI 热路径调用。
    public func imageQueryAvailability() -> ImageQueryAvailability {
        guard semantic != nil else { return .unavailable("语义索引不可用") }
        guard semanticFlag else { return .unavailable("语义检索已关闭") }
        let candidates = providers.semanticEmbeddingProviders()
        guard !candidates.isEmpty else { return .unavailable("未配置图片语义模型") }
        var unknown = false
        for provider in candidates {
            guard let probe = providers.lastProbe(id: provider.id) else { unknown = true; continue }
            if case .available(_, let caps) = probe, caps.embedImage, caps.dimensions != nil { return .available }
        }
        return unknown ? .unknown : .unavailable("当前语义模型不支持图片输入")
    }

    /// 入口可见但能力未知时后台探一次（不阻塞 UI）；探测结果进 ProviderHub 缓存。
    public func warmImageQueryCapability() {
        guard imageQueryAvailability() == .unknown else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in _ = self?.activeImageEmbedding() }
    }

    /// 面板查询入口：缓存命中直接给；未命中即调度后台，先返回 .analyzing。
    public func imageQueryOutcome(for query: ImageQuery, limit: Int = AstfindEngine.imageQueryLimit) -> ImageQueryOutcome {
        switch imageQueryAvailability() {
        case .unavailable(let reason): return .unavailable(reason)
        case .available, .unknown: break
        }
        if let cached = cachedImageOutcome(for: query, limit: limit) { return cached }
        scheduleImageSearch(query, limit: limit)
        return .analyzing
    }

    /// 同步查询（CLI / 测试 / 无头验证）——阻塞到向量化与检索返回。
    public func imageSearch(_ query: ImageQuery, limit: Int = AstfindEngine.imageQueryLimit,
                            timeout: TimeInterval = 15) -> ImageQueryOutcome {
        switch imageQueryAvailability() {
        case .unavailable(let reason): return .unavailable(reason)
        case .available, .unknown: break
        }
        if let cached = cachedImageOutcome(for: query, limit: limit) { return cached }
        let outcome = computeImageOutcome(query, limit: limit, timeout: timeout)
        storeImageOutcome(outcome, for: query.digest, limit: limit)
        return outcome
    }

    public func scheduleImageSearch(_ query: ImageQuery, limit: Int = AstfindEngine.imageQueryLimit) {
        imageQueryLock.lock()
        let generation = imageQueryGeneration
        let key = "\(query.digest)#\(limit)#\(generation)"
        guard !imageQueriesInFlight.contains(key) else { imageQueryLock.unlock(); return }
        imageQueriesInFlight.insert(key)
        imageQueryLock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let outcome = self.computeImageOutcome(query, limit: limit, timeout: self.imageQueryTimeout)
            self.storeImageOutcome(outcome, for: query.digest, limit: limit, generation: generation)
            self.imageQueryLock.lock(); self.imageQueriesInFlight.remove(key); self.imageQueryLock.unlock()
            DispatchQueue.main.async { self.onImageQueryComplete?() }
        }
    }

    // MARK: - 图文联合查询（M0.7b）

    /// 面板入口：缓存命中直接给；未命中即调度后台，先返回 .analyzing。
    /// 文本向量不可用不会在这里判死——引擎会降级为图片召回 + 文本过滤/重排。
    public func jointQueryOutcome(for query: JointImageQuery,
                                  limit: Int = AstfindEngine.imageQueryLimit) -> JointImageQueryOutcome {
        switch imageQueryAvailability() {
        case .unavailable(let reason): return .unavailable(reason)
        case .available, .unknown: break
        }
        guard let active = activeImageEmbedding() else { return .unavailable("当前语义模型不支持图片输入") }
        imageQueryLock.lock()
        let generation = imageQueryGeneration
        imageQueryLock.unlock()
        if let cached = cachedJointOutcome(for: query, profile: active.profile, limit: limit, generation: generation) {
            return cached
        }
        scheduleJointQuery(query, limit: limit, profile: active.profile)
        return .analyzing
    }

    /// 同步联合查询（CLI / 测试 / 无头验证）。
    public func jointImageSearch(_ query: JointImageQuery, limit: Int = AstfindEngine.imageQueryLimit,
                                 timeout: TimeInterval = 15) -> JointImageQueryOutcome {
        switch imageQueryAvailability() {
        case .unavailable(let reason): return .unavailable(reason)
        case .available, .unknown: break
        }
        guard let active = activeImageEmbedding() else { return .unavailable("当前语义模型不支持图片输入") }
        imageQueryLock.lock()
        let generation = imageQueryGeneration
        imageQueryLock.unlock()
        if let cached = cachedJointOutcome(for: query, profile: active.profile, limit: limit, generation: generation) {
            return cached
        }
        let outcome = computeJointOutcome(query, limit: limit, timeout: timeout, active: active)
        storeJointOutcome(outcome, for: query, profile: active.profile, limit: limit, generation: generation)
        return outcome
    }

    public func scheduleJointQuery(_ query: JointImageQuery, limit: Int = AstfindEngine.imageQueryLimit,
                                   profile: EmbeddingIndexer.Profile? = nil) {
        imageQueryLock.lock()
        let generation = imageQueryGeneration
        let key = jointInFlightKey(query, limit: limit, generation: generation)
        guard !jointQueriesInFlight.contains(key) else { imageQueryLock.unlock(); return }
        jointQueriesInFlight.insert(key)
        imageQueryLock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let outcome = self.computeJointOutcome(query, limit: limit, timeout: self.imageQueryTimeout, active: nil)
            self.storeJointOutcome(outcome, for: query, profile: profile, limit: limit, generation: generation)
            self.imageQueryLock.lock(); self.jointQueriesInFlight.remove(key); self.imageQueryLock.unlock()
            DispatchQueue.main.async { self.onJointQueryComplete?() }
        }
    }

    private func computeJointOutcome(_ query: JointImageQuery, limit: Int, timeout: TimeInterval,
                                     active: (provider: EmbeddingProvider, profile: EmbeddingIndexer.Profile)?) -> JointImageQueryOutcome {
        guard semanticFlag, let semantic else { return .unavailable("语义检索已关闭") }
        guard let active = active ?? activeImageEmbedding() else {
            return .unavailable("当前语义模型不支持图片输入")
        }
        noteSearchActivity()   // 泵避让：入库流量把远端 Provider 让给这次联合查询
        let profile = active.profile
        let provider = active.provider
        let supportsText = providerSupportsText(provider)
        let cachedImage = cachedImageVector(digest: query.image.digest, profile: profile)
        let cachedText = supportsText ? cachedTextVector(text: query.text, profile: profile) : nil
        let box = JointVectorBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await withTaskGroup(of: Void.self) { group in
                if let cachedImage {
                    box.image = .success(cachedImage)
                } else {
                    group.addTask {
                        do {
                            box.image = .success(try await provider.embedImageData(query.image.jpeg, mime: "image/jpeg"))
                        } catch {
                            box.image = .failure("图片向量化失败：\(String(describing: error))")
                        }
                    }
                }
                if supportsText {
                    if let cachedText {
                        box.text = .success(cachedText)
                    } else {
                        group.addTask {
                            do {
                                box.text = .success(try await provider.embedText(query.text))
                            } catch {
                                box.text = .failure("文本向量化失败：\(String(describing: error))")
                            }
                        }
                    }
                }
            }
            semaphore.signal()
        }
        let completed = semaphore.wait(timeout: .now() + timeout) == .success
        let imageResult = box.image
        let textResult = box.text
        if case .success(let vector)? = imageResult {
            storeImageVector(vector, digest: query.image.digest, profile: profile)
        }
        if case .success(let vector)? = textResult {
            storeTextVector(vector, text: query.text, profile: profile)
        }
        guard let imageResult else {
            return .failed(completed ? "参考图向量化失败" : "图片向量化超时（超过 \(Int(timeout)) 秒）")
        }
        let imageVector: [Float]
        switch imageResult {
        case .failure(let message): return .failed(message)
        case .success(let vector): imageVector = vector
        }
        guard imageVector.count == profile.dimension else {
            return .failed("向量维度不一致（返回 \(imageVector.count)，索引 \(profile.dimension)）")
        }
        let textVector: [Float]?
        if case .success(let vector)? = textResult { textVector = vector } else { textVector = nil }
        if JointVectorFusion.isUsable(textVector, dimension: profile.dimension), let textVector {
            guard let fused = JointVectorFusion.fuse(image: imageVector, text: textVector, alpha: query.alpha) else {
                return jointFallback(imageVector: imageVector, text: query.text, profile: profile,
                                     semantic: semantic, reason: .fusionUnavailable)
            }
            do {
                let hits = try semantic.search(queryVector: fused, profile: profile, limit: limit)
                return .hits(JointQueryResult(hits: hits, mode: .fused))
            } catch {
                return jointFallback(imageVector: imageVector, text: query.text, profile: profile,
                                     semantic: semantic, reason: .searchFailed)
            }
        }
        return jointFallback(imageVector: imageVector, text: query.text, profile: profile,
                             semantic: semantic, reason: .textVectorUnavailable)
    }

    /// 降级：图片召回 top 200 → 文本命中（文件名/OCR/FTS/缓存语义）重排。
    /// 有命中 = filtered（命中优先、其余按图片相似度续排）；无命中 = imageOnly（保留纯图结果）。
    private func jointFallback(imageVector: [Float], text: String, profile: EmbeddingIndexer.Profile,
                               semantic: EmbeddingIndexer, reason: JointQueryFallback) -> JointImageQueryOutcome {
        let imageHits: [EmbeddingIndexer.SemanticHit]
        do {
            imageHits = try semantic.search(queryVector: imageVector, profile: profile,
                                            limit: ContentSupplementaryProvider.imageFetchLimit)
        } catch {
            return .failed("检索失败：\(error.localizedDescription)")
        }
        var assetIds = Set<String>()
        var paths = Set<String>()
        for hit in contentSearch(text, limit: ContentSupplementaryProvider.imageFetchLimit) {
            assetIds.insert(hit.assetId)
            paths.insert(hit.sourceId + "|" + hit.relativePath)
        }
        if let semanticHits = cachedSemanticHits(for: text) {
            for hit in semanticHits {
                assetIds.insert(hit.assetId)
                paths.insert(hit.sourceId + "|" + hit.relativePath)
            }
        }
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let tokens = folded.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { $0.count >= 2 }
        func matches(_ hit: EmbeddingIndexer.SemanticHit) -> Bool {
            if assetIds.contains(hit.assetId) || paths.contains(hit.sourceId + "|" + hit.relativePath) { return true }
            guard !folded.isEmpty else { return false }
            let name = (hit.relativePath as NSString).lastPathComponent
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return name.contains(folded) || tokens.contains { name.contains($0) }
        }
        let matched = imageHits.filter(matches)
        let ordered = matched.isEmpty ? imageHits : matched + imageHits.filter { !matches($0) }
        let mode: JointQueryMode = matched.isEmpty ? .imageOnly : .filtered
        let fallback: JointQueryFallback? = matched.isEmpty
            ? (reason == .textVectorUnavailable ? .textVectorUnavailable : .textNoMatch)
            : reason
        return .hits(JointQueryResult(hits: ordered, mode: mode, fallback: fallback))
    }

    private func providerSupportsText(_ provider: EmbeddingProvider) -> Bool {
        if case .available(_, let caps)? = providers.lastProbe(id: provider.id) { return caps.embedText }
        return provider.capabilities.embedText
    }

    private func computeImageOutcome(_ query: ImageQuery, limit: Int, timeout: TimeInterval) -> ImageQueryOutcome {
        guard semanticFlag, let semantic else { return .unavailable("语义检索已关闭") }
        guard let active = activeImageEmbedding() else { return .unavailable("当前语义模型不支持图片输入") }
        noteSearchActivity()   // 泵避让：入库流量把远端 Provider 让给这次图片向量化
        switch imageVector(for: query, provider: active.provider, profile: active.profile, timeout: timeout) {
        case .failure(let message):
            return .failed(message)
        case .success(let vector):
            guard vector.count == active.profile.dimension else {
                return .failed("向量维度不一致（返回 \(vector.count)，索引 \(active.profile.dimension)）")
            }
            do {
                return .hits(try semantic.search(queryVector: vector, profile: active.profile, limit: limit))
            } catch {
                return .failed("检索失败：\(error.localizedDescription)")
            }
        }
    }

    private func imageVector(for query: ImageQuery, provider: EmbeddingProvider,
                             profile: EmbeddingIndexer.Profile, timeout: TimeInterval) -> VectorResult {
        if let cached = cachedImageVector(digest: query.digest, profile: profile) {
            return .success(cached)
        }
        let semaphore = DispatchSemaphore(value: 0)
        let box = ImageVectorBox()
        Task.detached {
            do { box.result = .success(try await provider.embedImageData(query.jpeg, mime: "image/jpeg")) }
            catch { box.result = .failure(error) }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success, let result = box.result else {
            return .failure("参考图向量化超时（超过 \(Int(timeout)) 秒）")
        }
        switch result {
        case .failure(let error):
            return .failure("图片向量化失败：\(String(describing: error))")
        case .success(let vector):
            storeImageVector(vector, digest: query.digest, profile: profile)
            return .success(vector)
        }
    }

    private func jointQueryCacheKey(_ query: JointImageQuery, profile: EmbeddingIndexer.Profile,
                                    limit: Int, generation: Int) -> String {
        "\(query.image.digest)#\(query.text)#\(query.alpha)#\(limit)#\(profile.id)#\(generation)"
    }

    private func jointInFlightKey(_ query: JointImageQuery, limit: Int, generation: Int) -> String {
        "\(query.image.digest)#\(query.text)#\(query.alpha)#\(limit)#\(generation)"
    }

    private func cachedJointOutcome(for query: JointImageQuery, profile: EmbeddingIndexer.Profile,
                                    limit: Int, generation: Int) -> JointImageQueryOutcome? {
        let key = jointQueryCacheKey(query, profile: profile, limit: limit, generation: generation)
        imageQueryLock.lock(); defer { imageQueryLock.unlock() }
        guard let entry = jointQueryCache[key] else { return nil }
        guard Date().timeIntervalSince(entry.at) <= entry.ttl else {
            jointQueryCache[key] = nil
            return nil
        }
        return entry.outcome
    }

    private func storeJointOutcome(_ outcome: JointImageQueryOutcome, for query: JointImageQuery,
                                   profile: EmbeddingIndexer.Profile?, limit: Int, generation: Int) {
        let ttl: TimeInterval
        switch outcome {
        case .hits: ttl = Self.imageQuerySuccessTTL
        case .failed, .unavailable: ttl = Self.imageQueryFailureTTL
        case .analyzing: return
        }
        guard let profile else {
            // 调度时无法拿到 profile（模型切换/探测失败）：本次结果只回调，不入缓存。
            return
        }
        let key = jointQueryCacheKey(query, profile: profile, limit: limit, generation: generation)
        imageQueryLock.lock()
        if generation != imageQueryGeneration { imageQueryLock.unlock(); return }
        jointQueryCache[key] = JointQueryEntry(outcome: outcome, at: Date(), ttl: ttl)
        while jointQueryCache.count > Self.jointQueryCacheLimit,
              let oldest = jointQueryCache.min(by: { $0.value.at < $1.value.at })?.key {
            jointQueryCache[oldest] = nil
        }
        imageQueryLock.unlock()
    }

    private func imageVectorCacheKey(digest: String, profile: EmbeddingIndexer.Profile) -> String {
        "\(profile.id)#\(digest)"
    }

    private func textVectorCacheKey(_ text: String, profile: EmbeddingIndexer.Profile) -> String {
        "\(profile.id)#\(text)"
    }

    private func cachedImageVector(digest: String, profile: EmbeddingIndexer.Profile) -> [Float]? {
        let key = imageVectorCacheKey(digest: digest, profile: profile)
        imageQueryLock.lock(); defer { imageQueryLock.unlock() }
        guard let entry = imageVectorCache[key] else { return nil }
        guard Date().timeIntervalSince(entry.at) <= Self.imageVectorTTL else {
            imageVectorCache[key] = nil
            return nil
        }
        return entry.vector
    }

    private func cachedTextVector(text: String, profile: EmbeddingIndexer.Profile) -> [Float]? {
        let key = textVectorCacheKey(text, profile: profile)
        imageQueryLock.lock(); defer { imageQueryLock.unlock() }
        guard let entry = textVectorCache[key] else { return nil }
        guard Date().timeIntervalSince(entry.at) <= Self.textVectorTTL else {
            textVectorCache[key] = nil
            return nil
        }
        return entry.vector
    }

    private func storeImageVector(_ vector: [Float], digest: String, profile: EmbeddingIndexer.Profile) {
        storeVector(vector, key: imageVectorCacheKey(digest: digest, profile: profile), cache: &imageVectorCache)
    }

    private func storeTextVector(_ vector: [Float], text: String, profile: EmbeddingIndexer.Profile) {
        storeVector(vector, key: textVectorCacheKey(text, profile: profile), cache: &textVectorCache)
    }

    private func storeVector(_ vector: [Float], key: String, cache: inout [String: VectorEntry]) {
        imageQueryLock.lock()
        cache[key] = VectorEntry(vector: vector, at: Date())
        while cache.count > Self.vectorCacheLimit,
              let oldest = cache.min(by: { $0.value.at < $1.value.at })?.key {
            cache[oldest] = nil
        }
        imageQueryLock.unlock()
    }

    private func imageQueryCacheKey(_ digest: String, _ limit: Int) -> String { "\(digest)#\(limit)" }

    private func cachedImageOutcome(for query: ImageQuery, limit: Int) -> ImageQueryOutcome? {
        let key = imageQueryCacheKey(query.digest, limit)
        imageQueryLock.lock(); defer { imageQueryLock.unlock() }
        guard let entry = imageQueryCache[key] else { return nil }
        guard Date().timeIntervalSince(entry.at) <= entry.ttl else {
            imageQueryCache[key] = nil
            return nil
        }
        return entry.outcome
    }

    private func storeImageOutcome(_ outcome: ImageQueryOutcome, for digest: String, limit: Int, generation: Int? = nil) {
        let ttl: TimeInterval
        switch outcome {
        case .hits: ttl = Self.imageQuerySuccessTTL
        case .failed, .unavailable: ttl = Self.imageQueryFailureTTL
        case .analyzing: return
        }
        let key = imageQueryCacheKey(digest, limit)
        imageQueryLock.lock()
        if let generation, generation != imageQueryGeneration { imageQueryLock.unlock(); return }
        imageQueryCache[key] = ImageQueryEntry(outcome: outcome, at: Date(), ttl: ttl)
        while imageQueryCache.count > Self.imageQueryCacheLimit,
              let oldest = imageQueryCache.min(by: { $0.value.at < $1.value.at })?.key {
            imageQueryCache[oldest] = nil
        }
        imageQueryLock.unlock()
    }

    private func clearImageQueryCache() {
        imageQueryLock.lock()
        imageQueryGeneration += 1
        imageQueryCache.removeAll()
        jointQueryCache.removeAll()
        imageQueriesInFlight.removeAll()
        jointQueriesInFlight.removeAll()
        imageVectorCache.removeAll()
        textVectorCache.removeAll()
        imageQueryLock.unlock()
    }
    final class ImageVectorBox: @unchecked Sendable { var result: Result<[Float], Error>? }

    final class JointVectorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var imageResult: VectorResult?
        private var textResult: VectorResult?
        var image: VectorResult? {
            get { lock.lock(); defer { lock.unlock() }; return imageResult }
            set { lock.lock(); imageResult = newValue; lock.unlock() }
        }
        var text: VectorResult? {
            get { lock.lock(); defer { lock.unlock() }; return textResult }
            set { lock.lock(); textResult = newValue; lock.unlock() }
        }
    }

    // MARK: 语义查询缓存 + 异步调度（2026-10-21 面板 0 结果修正）
    // 教训：补充闭包里同步等远端文本向量（超时 2s + 冷探测更久），把内容命中一起拖过
    // 面板查询代次窗口（键入/索引通知都推进代次），全部命中被作废。此后各通道只付
    // 自己的时延：内容命中即回；语义查缓存，未命中后台算，算完回调宿主重跑本轮查询。

    private let semanticQueryLock = NSLock()
    private var semanticQueryCache: [String: (hits: [EmbeddingIndexer.SemanticHit], at: Date)] = [:]
    private var semanticQueriesInFlight: Set<String> = []
    /// 异步语义命中就绪（有内容可并入时才触发）：宿主应重跑当前查询，第二轮走缓存即时并入。
    public var onSupplementaryRefresh: (() -> Void)?
    /// 查询缓存有效期：向量仍在入库，过期重算让新图可见；上限防长会话膨胀。
    public static let semanticQueryTTL: TimeInterval = 30
    private static let semanticQueryCacheLimit = 32
    private static let semanticInFlightLimit = 4

    private static func semanticQueryKey(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 热路径取语义：缓存新鲜直接给；未命中返回 nil（调用方随后 schedule 后台计算）。绝不在此等网络。
    public func cachedSemanticHits(for text: String) -> [EmbeddingIndexer.SemanticHit]? {
        let key = Self.semanticQueryKey(text)
        semanticQueryLock.lock(); defer { semanticQueryLock.unlock() }
        guard let entry = semanticQueryCache[key] else { return nil }
        guard Date().timeIntervalSince(entry.at) <= Self.semanticQueryTTL else {
            semanticQueryCache[key] = nil
            return nil
        }
        return entry.hits
    }

    /// 后台语义计算（幂等：同词在途不重复；缓存新鲜/停用/超并发上限即忽略）。
    public func scheduleSemanticSearch(_ text: String) {
        let key = Self.semanticQueryKey(text)
        semanticQueryLock.lock()
        let fresh = semanticQueryCache[key]
        let freshUsable = fresh != nil && Date().timeIntervalSince(fresh!.at) <= Self.semanticQueryTTL
        guard semanticFlag, semantic != nil, !semanticQueriesInFlight.contains(key),
              !freshUsable, semanticQueriesInFlight.count < Self.semanticInFlightLimit else {
            semanticQueryLock.unlock(); return
        }
        semanticQueriesInFlight.insert(key)
        semanticQueryLock.unlock()
        noteSearchActivity()   // 泵避让：入库流量把远端 Provider 让给这次查询文本向量化
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let hits = self.semanticSearch(text, limit: 10, timeout: 6)
            self.semanticQueryLock.lock()
            self.semanticQueryCache[key] = (hits, Date())
            while self.semanticQueryCache.count > Self.semanticQueryCacheLimit,
                  let oldest = self.semanticQueryCache.min(by: { $0.value.at < $1.value.at })?.key {
                self.semanticQueryCache[oldest] = nil
            }
            self.semanticQueriesInFlight.remove(key)
            self.semanticQueryLock.unlock()
            if !hits.isEmpty { self.onSupplementaryRefresh?() }
        }
    }

    private var autoExtractedReady = Set<String>()
    // 连续抽取泵：此前只在来源就绪时触发一批（每源 500 个），12 万积压永远追不完。
    // 泵按源轮转小批次推进（公平——外置盘不排在数万 NAS 任务后），stop() 即停。
    private let pumpLock = NSLock()
    private var pumpGeneration = 0
    private var pumpRunning = false
    private func handleSchedulerProgress(_ progress: ScanScheduler.SourceProgress) {
        if case .ready = progress.phase, !autoExtractedReady.contains(progress.sourceId) {
            autoExtractedReady.insert(progress.sourceId)
            // 只对仍启用内容索引的来源排队；关闭后即使旧 ready 事件迟到也不重新入队。
            let contentEnabled = (try? registry.source(id: progress.sourceId))?.contentIndexEnabled ?? true
            if autoExtractContent, contentEnabled {
                let sourceId = progress.sourceId
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    _ = self?.extractContent(sourceId: sourceId)
                    self?.kickExtractionPump()
                }
            }
            if semanticFlag, contentEnabled {
                let sourceId = progress.sourceId
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    guard let self, let semantic = self.semantic, let active = self.activeImageEmbedding() else { return }
                    try? semantic.ensureProfile(active.profile)
                    _ = try? semantic.enqueuePending(sourceId: sourceId, profile: active.profile)
                    _ = try? semantic.enqueuePendingVideos(sourceId: sourceId, profile: active.profile)
                    self.kickEmbeddingPump()
                }
            }
            if faceSearchEnabled, (try? registry.source(id: progress.sourceId))?.faceIndexEnabled == true {
                let sourceId = progress.sourceId
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    _ = try? self?.face?.enqueuePending(sourceId: sourceId)
                    self?.kickFaceIndexPump()
                }
            }
        }
        onSourcesChange?()
    }

    /// `ASTFIND_HOME` 覆盖，默认 `~/Library/Application Support/Astfind`（测试/多实例隔离用）。
    public static func defaultHome() -> URL {
        let base = ProcessInfo.processInfo.environment["ASTFIND_HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Astfind")
        return base
    }
    public convenience init(home: URL, budget: ScanScheduler.Budget = ScanScheduler.Budget(),
                            volumeResolver: VolumeIdentityResolving = DefaultVolumeResolver(),
                            smbResolver: SMBShareResolving = DefaultSMBShareResolver()) throws {
        try self.init(databaseURL: home.appendingPathComponent("registry.sqlite"),
                      snapshotDirectory: home.appendingPathComponent("snapshots"),
                      budget: budget, volumeResolver: volumeResolver, smbResolver: smbResolver)
    }

    // MARK: 生命周期

    public func start() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()
        let records = (try? registry.sources()) ?? []
        // 1) 离线优先：attach 内部同步 loadOffline——全部来源立即从快照可搜（首扫来源进入块引导）
        for record in records {
            scheduler.attach(record: record)
        }
        // 2) 挂载可达 → 调度器扫描
        refreshMounts()
        // 3) GUI 运行时监听系统挂载/卸载/唤醒；CLI 无 runloop 也可手动 refreshMounts()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: nil) { [weak self] _ in
            self?.refreshMounts()
        })
        observers.append(center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: nil) { [weak self] _ in
            self?.refreshMounts()
        })
        notifyChange()
 
        // 启动即踢泵：不再依赖任何触发时序（错过 ready 事件的存量积压也要能排掉）
        kickExtractionPump()
        kickEmbeddingPump()
        kickFaceIndexPump()
    }

    public func stop() {
        lock.lock()
        let wasStarted = started
        started = false
        lock.unlock()
        pumpLock.lock()
        pumpGeneration += 1   // 掐掉在跑的抽取泵
        pumpLock.unlock()
        facePumpLock.lock()
        facePumpGeneration += 1   // 掐掉在跑的人脸泵
        facePumpLock.unlock()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        if wasStarted { scheduler.shutdown() }
    }

    // MARK: 来源管理

    @discardableResult
    public func register(path: String, name: String? = nil, kind: SourceRecord.Kind = .local, scanNow: Bool = true) throws -> SourceRecord {
        // 外置卷在注册时捕获卷 UUID 作为稳定身份（名字/路径不做身份——D3 第一性原理）
        var volumeIdentity: String?
        if kind == .external { volumeIdentity = volumeResolver.volumeUUID(atMount: path) }
        // SMB 身份优先（R1）：路径位于 SMB 挂载下（无论调用方报什么 kind——App 添加页对
        // /Volumes 一律记 external），locator 存 smb:// 共享身份，挂载点只作运行态。
        // 挂载表反查不到（未挂载/非 SMB 路径）时回退路径型，可达后由 refreshMounts 迁移升级。
        var kind = kind
        var locator = path
        if let identity = smbIdentity(forPath: path) {
            kind = .smb
            locator = identity
        }
        let record = try registry.registerSource(kind: kind, locator: locator, displayName: name ?? URL(fileURLWithPath: path).lastPathComponent,
                                                 volumeIdentity: volumeIdentity)
        let reachable = sourceReachable(record, path: path, refreshSMB: true)
        rememberMount(path, reachable)
        try registry.updateMount(sourceId: record.sourceId, mountPath: reachable ? path : nil, online: reachable)
        scheduler.attach(record: record)
        if scanNow, reachable {
            scheduler.handleMounted(record: record, mountPath: path)
            _ = waitForScans(timeout: 600)   // 注册即等待收敛（CLI 交互语义；App 内可传 scanNow:false）
        }
        notifyChange()
        return record
    }

    public func remove(sourceId: String) throws {
        scheduler.shutdownSource(sourceId: sourceId)
        try registry.removeSource(sourceId: sourceId)
        try? FileManager.default.removeItem(at: snapshotDirectory.appendingPathComponent(sourceId + ".oilfind"))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: snapshotDirectory.path)) ?? []
        for file in files where file.hasPrefix("\(sourceId).boot.") { try? FileManager.default.removeItem(at: snapshotDirectory.appendingPathComponent(file)) }
        notifyChange()
    }

    public func records() -> [SourceRecord] {
        ((try? registry.sources()) ?? []).filter { !$0.contentOnly }
    }

    public func liveAssetCount(sourceId: String) -> Int {
        (try? registry.liveAssetCount(sourceId: sourceId)) ?? 0
    }

    /// 内容专用来源（外置盘）：复用面板 catalog 已建的文件名索引文件登记资产，只做 OCR/正文抽取。
    /// 不挂扫描调度器、不进 sources()——文件名检索仍由面板 catalog 提供，同一卷绝不双扫。
    /// 拔盘后资产与内容观测保留（离线仍可搜），重插/重扫由 catalog 变更再次驱动（幂等）。
    @discardableResult
    public func ensureContentSource(volumeUUID: String, name: String, mountPath: String,
                                    storeFile: URL) throws -> SourceRecord {
        let record: SourceRecord
        if let existing = ((try? registry.sources()) ?? []).first(where: {
            $0.contentOnly && $0.volumeIdentity?.uppercased() == volumeUUID.uppercased()
        }) {
            record = existing
        } else {
            record = try registry.registerSource(kind: .external, locator: mountPath, displayName: name,
                                                 volumeIdentity: volumeUUID, contentOnly: true)
        }
        let reachable = cachedMount(mountPath)
        try registry.updateMount(sourceId: record.sourceId, mountPath: mountPath, online: reachable)
        guard let store = IndexStore.load(from: storeFile.path) else { return record }
        let run = try registry.beginScanRun(sourceId: record.sourceId)
        try registry.endScanRun(run, success: true, snapshotRootPath: store.rootPath)
        _ = try registry.syncAssets(sourceId: record.sourceId, scanRunId: run.scanRunId,
                                    scanRunCompleted: true, entries: SourceRegistry.entries(in: store))
        if autoExtractContent {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                _ = self?.extractContent(sourceId: record.sourceId)
                self?.kickExtractionPump()
            }
        }
        return record
    }

    /// 内容专用来源（本机目录，P0 范围选择器）：复用**面板主索引**（rootPath="/"，文件名索引
    /// 唯一属主）登记所选目录下的资产——同盘零双扫；只做 OCR/正文抽取，不进 sources()。
    /// 幂等：主索引变化（去抖后）重复调用即重同步；目录内删除随 store 收敛（scanRunCompleted）。
    @discardableResult
    public func ensureLocalContentSource(dirPath: String, displayName: String? = nil, store: IndexStore) throws -> SourceRecord {
        let normalized = dirPath.hasSuffix("/") && dirPath.count > 1 ? String(dirPath.dropLast()) : dirPath
        let record: SourceRecord
        if let existing = ((try? registry.sources()) ?? []).first(where: {
            $0.contentOnly && $0.kind == .local && $0.locator == "file://" + normalized
        }) {
            record = existing
        } else {
            record = try registry.registerSource(kind: .local, locator: normalized,
                                                 displayName: displayName ?? URL(fileURLWithPath: normalized).lastPathComponent,
                                                 contentOnly: true)
        }
        let reachable = reachabilityProbe(normalized)
        rememberMount(normalized, reachable)
        try registry.updateMount(sourceId: record.sourceId, mountPath: normalized, online: reachable)
        let run = try registry.beginScanRun(sourceId: record.sourceId)
        try registry.endScanRun(run, success: true, snapshotRootPath: normalized)
        // 资产相对路径改为相对**所选目录**（mount + relative = 文件全路径，与抽取/打开语义一致）；
        // store 条目本相对其扫描根（面板主索引 rootPath="/"），这里剥掉目录前缀
        // （前缀长度含前导斜杠，恰好抵掉相对路径首段分隔符，dropFirst 不再 +1）。
        let storeRoot = store.rootPath == "/" ? "" : store.rootPath
        let scopePrefixLength = storeRoot.isEmpty ? normalized.count : normalized.count - storeRoot.count
        let entries = SourceRegistry.entries(in: store, underPath: normalized).map { entry -> (relativePath: String, kind: String, size: Int64, mtimeNs: Int64?) in
            (String(entry.relativePath.dropFirst(scopePrefixLength)), entry.kind, entry.size, entry.mtimeNs)
        }
        _ = try registry.syncAssets(sourceId: record.sourceId, scanRunId: run.scanRunId,
                                    scanRunCompleted: true, entries: entries)
        if autoExtractContent {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                _ = self?.extractContent(sourceId: record.sourceId)
                self?.kickExtractionPump()
            }
        }
        return record
    }

    /// 全部本机内容范围（设置页清单用；contentOnly + local，对 records()/sources() 隐藏）。
    public func localContentScopes() -> [SourceRecord] {
        ((try? registry.sources()) ?? []).filter { $0.contentOnly && $0.kind == .local }
    }

    /// 主索引变化驱动的幂等重同步（调用方负责去抖；store 为面板主索引当前 store）。
    public func resyncLocalContentScopes(store: IndexStore) {
        for record in localContentScopes() {
            guard let dir = legacyPath(fromLocator: record.locator) else { continue }
            _ = try? ensureLocalContentSource(dirPath: dir, displayName: record.displayName, store: store)
        }
    }

    /// 目录内容索引成本预估（范围选择确认流）：实地遍历所选目录一次，按提取器扩展名
    /// 分类计数。走磁盘而非主索引——目录是用户刚选的 ground truth，索引可能滞后。
    public struct LocalContentEstimate: Equatable, Sendable {
        public let images: Int
        public let documents: Int
        public let totalBytes: Int64
        /// 目录过大时预估截断（实测 ~/Desktop 级目录全量遍历要分钟级——统计本身不能成为卡顿源）
        public let truncated: Bool
        public var total: Int { images + documents }
        /// 按当前并发路数估的抽取时长下限（秒；实测外置盘约 1 文件/秒/路，保守取 1）
        public func estimatedSeconds(lanes: Int) -> Int {
            total <= 0 ? 0 : Int((Double(total) / Double(max(1, lanes))).rounded(.up))
        }
    }

    public func localContentEstimate(dirPath: String) -> LocalContentEstimate {
        let imageExts = VisionOCRExtractor.supportedExtensions
        let textExts = PlainTextExtractor.supportedExtensions
        var images = 0, documents = 0, visited = 0
        var totalBytes: Int64 = 0
        let visitCap = 50_000
        if let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: dirPath),
                                                           includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
            for case let url as URL in enumerator {
                visited += 1
                if visited > visitCap { break }
                let name = url.lastPathComponent
                // 元数据碎片不入预估（与入队过滤同一纪律）
                if name.hasPrefix("._") || name == ".DS_Store" { continue }
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values?.isRegularFile == true else { continue }
                let ext = url.pathExtension.lowercased()
                if imageExts.contains(ext) { images += 1 }
                else if textExts.contains(ext) || ext == "pdf" { documents += 1 }
                else { continue }
                totalBytes += Int64(values?.fileSize ?? 0)
            }
        }
        return LocalContentEstimate(images: images, documents: documents, totalBytes: totalBytes,
                                    truncated: visited > visitCap)
    }

    /// 更新来源挂载点（重挂载/换名后由挂载检测或用户绑定调用），并立即刷新。
    public func updateMount(sourceId: String, path: String?) throws {
        let reachable: Bool
        if let path, let record = try registry.source(id: sourceId) {
            reachable = sourceReachable(record, path: path, refreshSMB: true)
        } else {
            reachable = path.map { reachabilityProbe($0) } ?? false
        }
        if let path { rememberMount(path, reachable) }
        try registry.updateMount(sourceId: sourceId, mountPath: reachable ? path : nil, online: reachable)
        refreshMounts()
    }

    /// 重新探测各来源挂载状态并驱动调度器；离线的只降标记、保快照。
    ///
    /// 外置卷（有 volumeIdentity）**UUID 优先**：在全部挂载点里按 UUID 找归属——
    /// 换挂载点/改名卷自动重绑；同名卷靠 UUID 消歧；找不到 = 卷不在（离线，快照保留）。
    ///
    /// SMB（R1）**共享身份优先**：locator 为 smb://host/share[/子路径] 时按身份前缀匹配
    /// 任意挂载点——NAS 重连/挂载点改名漂移（teamshare-1 → teamshare）自动重绑；
    /// 无卷 UUID 且路径位于 SMB 挂载下的存量来源（曾被记为 external/local）自动升级为身份。
    public func refreshMounts() {
        var shareMounts: [SMBShareMount]?   // 惰性解析：仅需要时查一次挂载表
        for var record in (try? registry.sources()) ?? [] {
            if record.kind == .smb || (record.volumeIdentity == nil && !record.contentOnly) {
                if shareMounts == nil { shareMounts = smbResolver.smbShareMounts() }
                upgradeLegacySMB(record: &record, shareMounts: shareMounts ?? [])
            }
            if record.kind == .smb {
                if shareMounts == nil { shareMounts = smbResolver.smbShareMounts() }
                if rebindSMB(record: &record, shareMounts: shareMounts ?? []) { continue }
                // 无身份且反查失败（如挂载表不可得）：退回路径语义兜底
            }
            if record.kind == .external, let expected = record.volumeIdentity {
                if let mount = volumeResolver.findMount(volumeUUID: expected) {
                    if record.mountPath != mount {
                        try? registry.updateMount(sourceId: record.sourceId, mountPath: mount, online: true)
                        record.mountPath = mount
                    }
                    scheduler.handleMounted(record: record, mountPath: mount)
                } else {
                    if record.onlineState == .online { try? registry.updateMount(sourceId: record.sourceId, mountPath: nil, online: false) }
                    scheduler.handleUnmounted(sourceId: record.sourceId)
                }
                continue
            }
            // local/SMB 路径兜底：路径即绑定（locator 语义），可达性决定在线
            if let mount = record.mountPath {
                let reachable = reachabilityProbe(mount)
                rememberMount(mount, reachable)
                if reachable {
                    scheduler.handleMounted(record: record, mountPath: mount)
                } else {
                    scheduler.handleUnmounted(sourceId: record.sourceId)
                }
            } else {
                scheduler.handleUnmounted(sourceId: record.sourceId)
            }
        }
    }

    /// 存量升级（幂等）：无卷 UUID 的路径型来源，其绑定路径位于 SMB 挂载下且可达时，
    /// 读挂载表升级为 smb:// 身份源（kind 与 locator 一次写入）。反查失败/不可达则原样返回。
    private func upgradeLegacySMB(record: inout SourceRecord, shareMounts: [SMBShareMount]) {
        guard !SMBShareIdentity.isIdentity(record.locator),
              record.volumeIdentity == nil, !record.contentOnly else { return }
        for candidate in [record.mountPath, legacyPath(fromLocator: record.locator)].compactMap({ $0 }) {
            guard reachabilityProbe(candidate),
                  let identity = smbIdentity(forPath: candidate, shareMounts: shareMounts) else { continue }
            guard !smbLocatorTaken(identity, excluding: record.sourceId) else {
                AstfindAppExtension.log("smb: \(record.displayName) 迁移跳过——身份 \(identity) 已被其他来源占用")
                return
            }
            let formerKind = record.kind.rawValue
            try? registry.upgradeToSMB(sourceId: record.sourceId, locator: identity)
            record.kind = .smb
            record.locator = identity
            AstfindAppExtension.log("smb: \(record.displayName) 由 \(formerKind) 路径型升级为共享身份 \(identity)")
            return
        }
    }

    /// SMB 来源按共享身份重绑（决策在调用线程；返回 false 表示无身份，走路径兜底）。
    private func rebindSMB(record: inout SourceRecord, shareMounts: [SMBShareMount]) -> Bool {
        guard let parts = SMBShareIdentity.parts(ofIdentity: record.locator) else { return false }
        // 身份前缀匹配：同共享任意挂载点皆可绑（歧义取排序第一个并记诊断，不猜其余）
        let matches = shareMounts
            .filter { SMBShareIdentity.matches(shareURL: $0.shareURL, locatorShareURL: parts.shareURL) }
            .sorted { $0.mountPath < $1.mountPath }
        if matches.count > 1 {
            let paths = matches.map { $0.mountPath }.joined(separator: ", ")
            AstfindAppExtension.log("smb: 共享 \(parts.shareURL) 存在 \(matches.count) 个挂载点（\(paths)），取第一个")
        }
        if let mount = matches.first {
            let candidate = parts.subpath.isEmpty ? mount.mountPath : mount.mountPath + "/" + parts.subpath
            // 挂载表还在 ≠ 服务端活着：NAS 掉线后 smbfs 挂载点会保留，
            // 只 stat mountPath 会误判在线并让扫描/抽取撞进不可中断 I/O。
            let reachable = sourceReachable(record, path: candidate, refreshSMB: true)
            rememberMount(candidate, reachable)
            if reachable {
                _ = takeHealthPaused(sourceId: record.sourceId)
                if record.mountPath != candidate || record.onlineState != .online {
                    try? registry.updateMount(sourceId: record.sourceId, mountPath: candidate, online: true)
                    record.mountPath = candidate
                }
                scheduler.handleMounted(record: record, mountPath: candidate)
                return true
            }
            // 挂载点仍在、服务端不可达：保留 mountPath 供恢复后继续用，只落离线态。
            if record.mountPath != candidate || record.onlineState == .online {
                try? registry.updateMount(sourceId: record.sourceId, mountPath: candidate, online: false)
                record.mountPath = candidate
            }
            pauseForHealth(sourceId: record.sourceId)
            return true
        }
        // 共享不在/子路径不可达：离线，快照保留（离线 ≠ 删除）
        if record.mountPath != nil || record.onlineState == .online {
            try? registry.updateMount(sourceId: record.sourceId, mountPath: nil, online: false)
            record.mountPath = nil
        }
        scheduler.handleUnmounted(sourceId: record.sourceId)
        return true
    }

    /// 路径 → smb://host/share/子路径 身份（当前挂载表反查；不在任何 SMB 挂载下返回 nil）。
    /// 多挂载点嵌套时最长挂载路径优先。
    private func smbIdentity(forPath path: String, shareMounts: [SMBShareMount]? = nil) -> String? {
        let mounts = (shareMounts ?? smbResolver.smbShareMounts())
            .sorted { $0.mountPath.count > $1.mountPath.count }
        for mount in mounts {
            if let sub = SMBShareIdentity.subpath(ofPath: path, underMount: mount.mountPath) {
                return sub.isEmpty ? mount.shareURL : mount.shareURL + "/" + sub
            }
        }
        return nil
    }

    /// 存量路径型 locator（file:///Volumes/…）→ 文件系统路径；非路径型返回 nil。
    private func legacyPath(fromLocator locator: String) -> String? {
        guard locator.hasPrefix("file://") else { return nil }
        return String(locator.dropFirst("file://".count))
    }

    /// 身份是否已被其他 SMB 来源占用（防迁移制造重复源）。
    private func smbLocatorTaken(_ identity: String, excluding sourceId: String) -> Bool {
        ((try? registry.sources()) ?? []).contains {
            $0.sourceId != sourceId && $0.kind == .smb && $0.locator.caseInsensitiveCompare(identity) == .orderedSame
        }
    }

    /// 等待全部"挂载可达"来源完成扫描收敛（一次性进程如 CLI 用；App 内由 UI 事件驱动）。
    @discardableResult
    public func waitForScans(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let records = self.records()
            let progress = Dictionary(uniqueKeysWithValues: scheduler.progress().map { ($0.sourceId, $0.phase) })
            let done = records.allSatisfy { record in
                guard let mount = record.mountPath, FileManager.default.fileExists(atPath: mount) else { return true }
                switch progress[record.sourceId] {
                case .ready, .paused: return true
                default: return false   // nil（attach 未及）/idle/bootstrap/rescan 都不算完
                }
            }
            if done { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    // MARK: 暂停/恢复（透传调度器）

    public func pause(sourceId: String) { scheduler.pause(sourceId: sourceId); notifyChange() }
    public func resume(sourceId: String) { scheduler.resume(sourceId: sourceId); notifyChange() }
    public func schedulerProgress() -> [ScanScheduler.SourceProgress] { scheduler.progress() }

    // MARK: 内容提取与内容搜索（D6）

    /// 为一个（或全部）来源入队并执行内容提取。源离线的任务自动留队，重连后续跑。
    @discardableResult
    public func extractContent(sourceId: String? = nil, limit: Int = 500) -> ContentIndexer.Summary? {
        guard let content else { return nil }
        // 目标取全部来源（含内容专用来源）——records() 对用户隐藏 contentOnly，不能用作抽取范围。
        // 离线/失联源不入队也不执行：否则 NAS 掉线时泵会一直撞不可中断 I/O。
        // contentIndexEnabled=false 的来源只保留文件名/元数据索引，不进入 OCR/正文/语义队列。
        let allSources = (try? registry.sources()) ?? []
        let targets = (sourceId.map { [$0] } ?? allSources.map(\.sourceId))
            .filter { id in
                guard let record = allSources.first(where: { $0.sourceId == id }) else { return false }
                return record.contentIndexEnabled && isSourceReachable(sourceId: id)
            }
        for id in targets { _ = try? content.enqueuePending(sourceId: id) }
        if let sourceId, !targets.contains(sourceId) { return nil }
        // 按源触发优先处理该源，其余源的全局积压按序跟上
        // 直接触发（源 ready / 外置盘同步等）也要遵守面板交互暂停；
        // 否则泵虽然停了，ready 事件仍会另起一批 OCR，把面板打开期间又打满。
        let shouldPause = { [weak self] in self?.isInteractive ?? false }
        if let sourceId {
            let summary = try? content.runPending(limit: limit, sourceId: sourceId, lanes: extractionLanes,
                                                  shouldPause: shouldPause)
            if let summary { recordThroughput(sourceId: sourceId, processed: summary.processed) }
            return summary
        }
        return try? content.runPending(limit: limit, lanes: extractionLanes, shouldPause: shouldPause)
    }

    // MARK: - 抽取进度可视化（动刀清单 3 号）
    // 痛点实锤（2026-10-20 晚）：引擎在大量干活，界面毫无感知。真相在 index_jobs 各态计数；
    // 速率/预计剩余用引擎内滚动窗口（泵每轮 processed 已知，无需给任务表加时间戳迁移）。

    public struct ExtractionProgress: Equatable, Sendable, Identifiable {
        public let sourceId: String
        public let displayName: String
        public let pending: Int
        public let running: Int
        public let done: Int
        public let failed: Int
        /// 最近窗口处理速率（文件/分钟）；窗口内无处理为 nil
        public let ratePerMinute: Double?
        public var id: String { sourceId }
        public var remaining: Int { pending + running }
        public var total: Int { pending + running + done + failed }
        /// 预计剩余秒数（按窗口速率）；无剩余或无速率为 nil
        public var etaSeconds: Int? {
            guard remaining > 0, let rate = ratePerMinute, rate > 0 else { return nil }
            return Int((Double(remaining) / rate * 60).rounded(.up))
        }
    }

    private let throughputLock = NSLock()
    private var throughputSamples: [String: [(at: Date, processed: Int)]] = [:]
    private static let throughputWindow: TimeInterval = 600

    /// 记录一轮处理量（泵/按源触发都调用；窗口 10 分钟，超窗样本丢弃）。
    private func recordThroughput(sourceId: String, processed: Int) {
        guard processed > 0 else { return }
        throughputLock.lock(); defer { throughputLock.unlock() }
        var samples = throughputSamples[sourceId] ?? []
        samples.append((Date(), processed))
        let cutoff = Date().addingTimeInterval(-Self.throughputWindow)
        samples.removeAll { $0.at < cutoff }
        throughputSamples[sourceId] = samples
    }

    /// 窗口速率（文件/分钟）：窗口内总量 / 自最早样本起的分钟数（下限 1 分钟防启动期虚高）。
    private func ratePerMinute(sourceId: String) -> Double? {
        throughputLock.lock(); defer { throughputLock.unlock() }
        let cutoff = Date().addingTimeInterval(-Self.throughputWindow)
        let samples = (throughputSamples[sourceId] ?? []).filter { $0.at >= cutoff }
        guard let first = samples.first else { return nil }
        let total = samples.reduce(0) { $0 + $1.processed }
        let minutes = max(1, Date().timeIntervalSince(first.at) / 60)
        return Double(total) / minutes
    }

    /// 全部来源（含内容专用来源）的抽取进度；只含有任务的来源。只读连接，可高频轮询。
    public func extractionProgress() -> [ExtractionProgress] {
        guard let content, let counts = try? content.jobCountsBySource() else { return [] }
        let names = Dictionary(uniqueKeysWithValues: ((try? registry.sources()) ?? []).map { ($0.sourceId, $0.displayName) })
        return counts.compactMap { sourceId, jobs -> ExtractionProgress? in
            guard let name = names[sourceId] else { return nil }   // 已删来源的残留不展示
            return ExtractionProgress(sourceId: sourceId, displayName: name,
                                      pending: jobs.pending, running: jobs.running,
                                      done: jobs.done, failed: jobs.failed,
                                      ratePerMinute: ratePerMinute(sourceId: sourceId))
        }
        .sorted { ($0.remaining, $0.displayName) > ($1.remaining, $1.displayName) }
    }

    /// 失败样本抽查（相对路径前 N 条）。
    public func failedExtractionSamples(sourceId: String, limit: Int = 5) -> [String] {
        (try? content?.failedSamples(sourceId: sourceId, limit: limit)) ?? []
    }

    /// 启动/保活抽取泵：已有泵在跑则忽略。幂等，多处触发安全。
    public func kickExtractionPump() {
        pumpLock.lock()
        guard autoExtractContent, !pumpRunning else { pumpLock.unlock(); return }
        pumpRunning = true
        pumpGeneration += 1
        let generation = pumpGeneration
        pumpLock.unlock()
        Self.trace("pump kicked gen=\(generation)")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.runExtractionPump(generation: generation)
        }
    }

    /// 引擎侧轨迹日志：~/.…/Astfind/pump.log（诊断用，每轮 ≤1 行）
    static func trace(_ message: String) {
        let url = AstfindEngine.defaultHome().appendingPathComponent("pump.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            let directory = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            try? Data(line.utf8).write(to: url, options: .atomic)
        }
        // 诊断日志会带来源 id/路径片段：仅属主可读（旧版本留下的 0644 文件也一并收紧）。
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func runExtractionPump(generation: Int) {
        Self.trace("pump loop enter gen=\(generation)")
        var lastIdleLog = Date.distantPast
        while isPumpAlive(generation), autoExtractContent, let content {
            if isInteractive {
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }
            let sources = (try? content.pendingSourceIds()) ?? []
            if sources.isEmpty { break }
            var processed = 0, skipped = 0
            for sourceId in sources {
                guard isPumpAlive(generation), autoExtractContent else {
                    pumpFinished(generation); return
                }
                // 失联源直接跳过：挂载点还在也不能读，否则整轮卡在 smbfs。
                guard isSourceReachable(sourceId: sourceId) else { skipped += 1; continue }
                // 泵轮只消费现有 pending，不做全量重入队——入队属于触发事件
                // （来源就绪/内容源建立/变更检测），每轮重插数万行曾把吞吐拖死
                let round = (try? content.runPending(limit: 25, sourceId: sourceId, lanes: extractionLanes,
                                                     shouldPause: { [weak self] in self?.isInteractive ?? false }))?.processed ?? 0
                recordThroughput(sourceId: sourceId, processed: round)
                processed += round
            }
            // 全源离线时不要每秒写一行 pump.log；每 30s 留一条心跳即可。
            if processed > 0 || skipped < sources.count || Date().timeIntervalSince(lastIdleLog) > 30 {
                Self.trace("pump round sources=\(sources.count) processed=\(processed) skipped=\(skipped) gen=\(generation)")
                lastIdleLog = Date()
            }
            NSLog("astfind pump round sources=%d processed=%d skipped=%d", sources.count, processed, skipped)
            // 无进展（如来源全离线）退避，避免空转；有进展则短歇续跑。全离线多睡一会。
            Thread.sleep(forTimeInterval: processed > 0 ? 0.2 : (skipped == sources.count ? 5.0 : 1.0))
        }
        Self.trace("pump loop exit gen=\(generation)")
        pumpFinished(generation)
    }

    private func pumpFinished(_ generation: Int) {
        pumpLock.lock(); defer { pumpLock.unlock() }
        if pumpGeneration == generation { pumpRunning = false }
    }

    private func isPumpAlive(_ generation: Int) -> Bool {
        pumpLock.lock(); defer { pumpLock.unlock() }
        return pumpGeneration == generation
    }

    /// 内容搜索（图片里的字 / PDF 正文 / 文本正文），全部本地。
    public func contentSearch(_ term: String, limit: Int = 20) -> [ContentIndexer.ContentHit] {
        (try? content?.search(term, limit: limit)) ?? []
    }

    // MARK: 搜索

    /// 合并全部来源；离线来源保留（可见、面板禁打开）。
    /// `isOnline` 保守语义：挂载可达且（权威扫描完成 / 块为完整子树扫描）。
    /// 可达性按需从文件系统探测——不维护副本集合（副本同步曾引发 isOnline 恒假 bug）。
    public func sources() -> [SearchSource] {
        var result: [SearchSource] = []
        for record in (try? registry.sources()) ?? [] where !record.contentOnly {
            let online = cachedMount(record)
            let chunks = scheduler.chunkSources(sourceId: record.sourceId)
            if !chunks.isEmpty {
                for chunk in chunks {
                    result.append(SearchSource(id: chunk.id, displayName: record.displayName,
                                                isOnline: online, store: chunk.store))
                }
                continue
            }
            guard let session = scheduler.session(sourceId: record.sourceId),
                  let source = session.searchSource else { continue }
            // 已有**同一挂载根**的权威快照时，重扫窗口（state=rescan/idle/paused）仍可搜索、可打开；
            // 只有“从未扫完”或重挂到新根、快照尚未 rebase 的来源才保守离线。
            // 否则 NAS 每次重扫，面板整列都会误标离线。
            let rootMatchesMount = record.mountPath.map { source.store.rootPath == $0 } ?? false
            let usable = session.state == .onlineReady
                || (rootMatchesMount && scheduler.hasCanonicalSnapshot(sourceId: record.sourceId))
            result.append(SearchSource(id: source.id, displayName: record.displayName,
                                       isOnline: online && usable,
                                       store: source.store))
        }
        scheduleReachabilityRefresh()
        return result
    }

    /// 内容专用外置盘（无 SMB 身份）的路径缓存探测。
    private func cachedMount(_ mountPath: String?) -> Bool {
        guard let path = mountPath else { return false }
        reachabilityLock.lock()
        let cached = mountedCache[path]
        reachabilityLock.unlock()
        if let cached { return cached }
        let reachable = reachabilityProbe(path)
        rememberMount(path, reachable)
        return reachable
    }

    /// 热路径可达性：缓存命中零 I/O；未命中（冷启动/新源注册后首次）同步探测一次并落缓存。
    private func cachedMount(_ record: SourceRecord) -> Bool {
        guard let path = record.mountPath else { return false }
        reachabilityLock.lock()
        let cached = mountedCache[path]
        reachabilityLock.unlock()
        if let cached { return cached }
        let reachable = sourceReachable(record)
        rememberMount(path, reachable)
        return reachable
    }

    /// 挂载点可达 + SMB 服务端存活。SMB 探测失败时只改在线态，不清 mountPath——
    /// 服务端恢复后同一个挂载点还能继续用，省一次重挂/重扫。
    private func sourceReachable(_ record: SourceRecord, path: String? = nil,
                                 refreshSMB: Bool = false) -> Bool {
        guard let mount = path ?? record.mountPath else { return false }
        if record.kind == .smb, let host = SMBShareIdentity.host(ofIdentity: record.locator),
           !smbServerHealthy(host, refresh: refreshSMB) {
            return false
        }
        return reachabilityProbe(mount)
    }

    private func smbServerHealthy(_ host: String, refresh: Bool) -> Bool {
        smbHealthLock.lock()
        if !refresh, let entry = smbHealth[host] {
            let ttl = entry.reachable ? Self.smbOnlineTTL : Self.smbOfflineTTL
            if Date().timeIntervalSince(entry.at) < ttl {
                smbHealthLock.unlock()
                return entry.reachable
            }
        }
        smbHealthLock.unlock()
        let reachable = smbServerProbe(host)
        smbHealthLock.lock()
        smbHealth[host] = SMBHealth(reachable: reachable, at: Date())
        smbHealthLock.unlock()
        return reachable
    }

    /// 面板重新出现时强制刷新一次来源可达性：修掉「缓存里还是 false」导致整列离线，
    /// 或扫描期间 state 未 ready 的误判。只在 show 边沿调用，不做热路径。
    public func refreshReachabilityNow() {
        let records = (try? registry.sources()) ?? []
        var changed = false
        for record in records {
            guard let path = record.mountPath else { continue }
            let reachable = sourceReachable(record, refreshSMB: true)
            reachabilityLock.lock()
            let old = mountedCache[path]
            mountedCache[path] = reachable
            reachabilityLock.unlock()
            if reachable {
                if takeHealthPaused(sourceId: record.sourceId) {
                    scheduler.handleMounted(record: record, mountPath: path)
                    scheduler.resume(sourceId: record.sourceId)
                }
            } else {
                pauseForHealth(sourceId: record.sourceId)
            }
            if let old, old != reachable { changed = true }
        }
        if changed { notifyChange() }
    }

    /// 面板打开结果前的同步预检：SMB 强制刷新一次（最多 0.8s），
    /// 宁可提示「来源不可用」，也不把用户扔进 Preview 的分钟级 SMB 等待。
    public func isSourceReachable(source: SearchSource) -> Bool {
        let path = source.store.rootPath
        let match = ((try? registry.sources()) ?? []).first { record in
            guard let mount = record.mountPath else { return false }
            return path == mount || path.hasPrefix(mount + "/")
        }
        guard let match else { return source.isOnline }
        return sourceReachable(match, refreshSMB: true)
    }

    /// 抽取泵用：按 sourceId 查询，带 SMB 健康缓存（5s），不会每轮都打网络。
    public func isSourceReachable(sourceId: String) -> Bool {
        guard let record = try? registry.source(id: sourceId) else { return false }
        return sourceReachable(record)
    }

    /// 面板可见时暂停后台抽取；隐藏后保留 8s 宽限，让 Preview/Finder 先读文件。
    /// M0.6 在引擎内部迁移到 ForegroundActivityCoordinator，签名与 M0.7 调用点保持不变。
    public func setInteractive(visible: Bool, typing: Bool) {
        foregroundActivity.setPanel(visible: visible)
        foregroundActivity.setTyping(visible && typing)
        scanPacing.wakeAll()
        logInteraction(reason: "setInteractive")
    }

    /// QuickLook 可见期间持续交互；关闭后按宽限退出，不依赖主面板。
    public func setQuickLookActive(_ active: Bool) {
        foregroundActivity.setQuickLook(visible: active)
        scanPacing.wakeAll()
        logInteraction(reason: "quickLook")
    }

    /// Preview/Finder/QuickTime 在前台时保持后台暂停；切走后按宽限恢复。
    public func setExternalAppActive(_ active: Bool) {
        foregroundActivity.setExternalAppActive(active)
        scanPacing.wakeAll()
        logInteraction(reason: "externalApp")
    }

    /// 打开/Finder 定位/MCP 等活动的显式入口（当前打开路径复用面板隐藏宽限）。
    public func noteForegroundActivity(_ activity: ForegroundActivity) {
        foregroundActivity.note(activity)
        scanPacing.wakeAll()
        logInteraction(reason: "note:\(activity.rawValue)")
    }

    public func endForegroundActivity(_ activity: ForegroundActivity) {
        foregroundActivity.end(activity)
        scanPacing.wakeAll()
        logInteraction(reason: "end:\(activity.rawValue)")
    }

    /// 诊断：面板/搜索/QuickLook 的真实交互状态变化。只在状态变化时写一行。
    private func logInteraction(reason: String) {
        let interactive = foregroundActivity.isInteractive
        let sources = foregroundActivity.activeSources.map(\.rawValue).sorted().joined(separator: ",")
        let key = "\(interactive)|\(sources)"
        interactionLogLock.lock()
        let changed = key != lastInteractionLog
        if changed { lastInteractionLog = key }
        interactionLogLock.unlock()
        guard changed else { return }
        NSLog("astfind interaction reason=%@ interactive=%d sources=%@",
              reason, interactive ? 1 : 0, sources)
    }

    /// 诊断：当前是否有 SMB Scanner 实际进入交互降速。
    public var isSMBScanThrottled: Bool { scanPacing.isThrottled }

    /// 测试/诊断：M0.6 Pacer 接线状态。
    var scanPacingForTesting: ScanPacingController { scanPacing }

    private var isInteractive: Bool { foregroundActivity.isInteractive }

    private func pauseForHealth(sourceId: String) {
        healthPausedLock.lock()
        let inserted = healthPausedSources.insert(sourceId).inserted
        healthPausedLock.unlock()
        if inserted { scheduler.pause(sourceId: sourceId) }
    }

    /// 摘掉「因失联而暂停」标记；返回 true 表示这次是从失联中恢复，调用方需重挂调度器。
    private func takeHealthPaused(sourceId: String) -> Bool {
        healthPausedLock.lock()
        let removed = healthPausedSources.remove(sourceId) != nil
        healthPausedLock.unlock()
        return removed
    }

    private func rememberMount(_ path: String, _ reachable: Bool) {
        reachabilityLock.lock(); mountedCache[path] = reachable; reachabilityLock.unlock()
    }

    /// 后台合并重验：任何 sources() 调用安排一次 TTL 后的重验，结果变化才通知面板刷新。
    private func scheduleReachabilityRefresh() {
        reachabilityLock.lock(); defer { reachabilityLock.unlock() }
        guard !reachabilityRefreshPending else { return }
        reachabilityRefreshPending = true
        let ttl = reachabilityTTL
        reachabilityQueue.asyncAfter(deadline: .now() + ttl) { [weak self] in
            guard let self else { return }
            var changed = false
            for record in (try? self.registry.sources()) ?? [] {
                guard let path = record.mountPath else { continue }
                // SMB 必须探服务端：挂载点还在但 NAS 已掉线时 fileExists 恒真。
                // 走 5s 健康缓存，避免 1.5s 一次的 TTL 重验反复阻塞在 0.8s 的 connect 上；
                // 打开前的预检（isSourceReachable(source:)）才是强制刷新。
                let reachable = self.sourceReachable(record, refreshSMB: false)
                self.reachabilityLock.lock()
                let old = self.mountedCache[path]
                self.mountedCache[path] = reachable
                self.reachabilityLock.unlock()
                if reachable {
                    // 从失联恢复：调度器可能已被 pause，mountPath 也未必还在运行态，
                    // 先重挂再恢复，否则 resume 因 mountPath=nil 直接空转。
                    if self.takeHealthPaused(sourceId: record.sourceId) {
                        self.scheduler.handleMounted(record: record, mountPath: path)
                        self.scheduler.resume(sourceId: record.sourceId)
                    }
                } else {
                    self.pauseForHealth(sourceId: record.sourceId)
                }
                if let old, old != reachable { changed = true }
            }
            self.reachabilityLock.lock(); self.reachabilityRefreshPending = false; self.reachabilityLock.unlock()
            if changed { DispatchQueue.main.async { self.notifyChange() } }
        }
    }

    /// 一次统一查询（CLI/测试用；App 内由 oil-find 面板驱动 MultiSearcher）。
    public func search(_ raw: String, limit: Int = 20) -> (total: Int, rows: [(source: String, online: Bool, path: String)])? {
        let list = sources()
        guard !list.isEmpty, let result = MultiSearcher.search(Query.parse(raw), in: list) else { return nil }
        let rows = result.items.prefix(limit).map { hit -> (String, Bool, String) in
            let source = result.sources[hit.sourceIndex]
            return (source.displayName, source.isOnline, source.store.path(hit.entryID))
        }
        return (result.total, rows)
    }

    private func notifyChange() {
        onSourcesChange?()
    }

    // MARK: - R2 手动重链接（PR 式保底：素材整体搬家/换 NAS 主机/目录重组/本地目录移动）

    /// 重链接评估报告：`analyzeRelink` 纯只读产出（确认前不落任何库变更，取消无副作用）。
    public struct RelinkReport: Equatable, Sendable {
        public let sourceId: String
        /// 反推出的候选根（锚点消歧后匹配率最高者）。
        public let candidateRoot: String
        /// 快照存活资产总数。
        public let totalAssets: Int
        /// 实际抽样数（≤500，全量不足 500 时全查）。
        public let sampled: Int
        /// 存在且大小一致。
        public let matched: Int
        /// 存在但大小不符。
        public let sizeMismatched: Int
        /// 缺失清单（前 N 条，帮用户判断选错位置）。
        public let missingSamples: [String]
        public var matchRate: Double { sampled == 0 ? 0 : Double(matched) / Double(sampled) }
        /// 重绑门槛（默认 90%）：UI 与 CLI 共用，避免两处阈值漂移；不足时提示改选目录、不做部分重绑。
        public var meetsThreshold: Bool { matchRate >= 0.9 }
    }

    public enum RelinkError: Error, Equatable {
        /// 锚点无法定位：文件锚点在快照中无同名资产、或来源尚无资产。
        case anchorUnresolvable(String)
    }

    /// 评估重链接。锚点可为**新根目录**（直接指认）或**任一同名文件**（按文件名+大小在快照
    /// 资产中定位，反推候选根——新位置套了目录层级也能找到真正根；多候选以抽样匹配率最高者胜，
    /// 并列取路径排序第一）。抽样校验 ≤500 条（存在性 + 大小一致率）。
    ///
    /// 热路径纪律：本方法含文件系统 IO（SMB stat 最坏数百毫秒级），UI 必须在后台队列调用。
    public func analyzeRelink(sourceId: String, anchor: URL) throws -> RelinkReport {
        guard let record = try registry.source(id: sourceId) else { throw RegistryError.unknownSource(sourceId) }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: anchor.path, isDirectory: &isDir) else {
            throw RelinkError.anchorUnresolvable("锚点路径不存在：\(anchor.path)")
        }
        let assets = try registry.assets(sourceId: sourceId, limit: .max)
        guard !assets.isEmpty else { throw RelinkError.anchorUnresolvable("来源「\(record.displayName)」尚无快照资产，无从匹配") }

        let candidates: [String]
        if isDir.boolValue {
            candidates = [anchor.path]
        } else {
            let name = anchor.lastPathComponent
            let anchorSize = (try? FileManager.default.attributesOfItem(atPath: anchor.path))?[.size] as? Int64
            var roots = Set<String>()
            for asset in assets where URL(fileURLWithPath: asset.relativePath).lastPathComponent == name {
                // 大小已知且不符的同名文件排除（大小未知不排除，避免时间戳类噪声误杀）
                if let anchorSize, anchorSize > 0, asset.size > 0, anchorSize != asset.size { continue }
                guard anchor.path.hasSuffix("/" + asset.relativePath) else { continue }
                roots.insert(String(anchor.path.dropLast(asset.relativePath.count + 1)))
            }
            candidates = roots.sorted()
        }
        guard !candidates.isEmpty else {
            throw RelinkError.anchorUnresolvable("锚点文件在「\(record.displayName)」的快照中找不到对应资产")
        }

        let sample = Self.relinkSample(assets, cap: 500)
        var best: RelinkReport?
        for root in candidates {
            let report = Self.verifyRelinkRoot(root: root, sourceId: sourceId, total: assets.count, sample: sample)
            if best == nil || report.matchRate > best!.matchRate { best = report }
        }
        return best!
    }

    /// 应用重链接（用户在匹配报告上确认后调用）：新根与 locator 单事务落库 + 驱动完整重扫收敛
    /// （D4 权威语义）。`snapshot_root_path` 随成功扫描更新为新根；**内容观测全部保留**——
    /// 身份=sourceId+relativePath 不变，变更令牌未变则内容抽取 skippedUnchanged（零重抽 OCR）。
    public func applyRelink(sourceId: String, to root: String) throws {
        guard var record = try registry.source(id: sourceId) else { throw RegistryError.unknownSource(sourceId) }
        let reachable = reachabilityProbe(root)
        rememberMount(root, reachable)
        // SMB 位置重推共享身份（换 NAS 主机/共享时身份随重链接更新）；其余走路径型 locator
        var locator = root
        if record.kind == .smb, let identity = smbIdentity(forPath: root) { locator = identity }
        try registry.relinkSource(sourceId: sourceId, mountPath: reachable ? root : nil,
                                  locator: locator, online: reachable)
        record.locator = locator
        record.mountPath = reachable ? root : nil
        // 重扫 ready 后重新触发内容入队（此前 ready 已消费过一次）
        autoExtractedReady.remove(sourceId)
        if reachable {
            scheduler.handleMounted(record: record, mountPath: root)
        } else {
            scheduler.handleUnmounted(sourceId: sourceId)
        }
        AstfindAppExtension.log("relink: \(record.displayName) → \(root)（locator=\(locator)，在线=\(reachable)）")
        notifyChange()
    }

    /// 快照样例文件（重链接弹窗帮用户回忆原始内容；在最近资产中均匀取 count 条）。
    public func sampleRelativePaths(sourceId: String, count: Int = 3) -> [String] {
        let assets = (try? registry.assets(sourceId: sourceId, limit: 300)) ?? []
        let k = min(count, assets.count)
        guard k > 0 else { return [] }
        guard k > 1 else { return [assets[0].relativePath] }
        return (0..<k).map { assets[(assets.count - 1) * $0 / (k - 1)].relativePath }
    }

    /// 均匀抽样（全量不足 cap 时全查；否则等距取 cap 条，覆盖首尾）。
    static func relinkSample(_ assets: [AssetRecord], cap: Int) -> [AssetRecord] {
        guard assets.count > cap else { return assets }
        var sample: [AssetRecord] = []
        sample.reserveCapacity(cap)
        for i in 0..<cap {
            let index = (assets.count - 1) * i / (cap - 1)
            sample.append(assets[index])
        }
        return sample
    }

    /// 候选根校验：抽样条目的存在性 + 大小一致率。缺失清单取前 10 条。
    static func verifyRelinkRoot(root: String, sourceId: String, total: Int, sample: [AssetRecord]) -> RelinkReport {
        var matched = 0, mismatched = 0
        var missing: [String] = []
        for asset in sample {
            let path = root + "/" + asset.relativePath
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
                let size = attrs[.size] as? Int64 ?? -1
                if size == asset.size { matched += 1 } else { mismatched += 1 }
            } else {
                if missing.count < 10 { missing.append(asset.relativePath) }
            }
        }
        return RelinkReport(sourceId: sourceId, candidateRoot: root, totalAssets: total,
                            sampled: sample.count, matched: matched, sizeMismatched: mismatched,
                            missingSamples: missing)
    }
}
