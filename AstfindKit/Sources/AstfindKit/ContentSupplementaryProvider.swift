import Foundation
import AppKit
import ImageIO
import OilFindCore
import AstfindPanel
import AstfindFaceCore

/// 把引擎的内容检索（图片 OCR / 文档全文，D6 trigram FTS）接进面板补充通道：
/// 文件名结果先行，内容命中异步追加（上游 SupplementarySearchProvider 协议）。
///
/// 命中必须落回某个 SearchSource 的 entry——面板据此渲染文件行、打开动作、
/// 离线禁开；路径反查用 store 的 O(1) parent+name 哈希下钻（lookup(parent:name:)），
/// 分块引导期的块源根是子目录，通过逐级丢弃前导段适配。
///
/// 同时实现 `ImageQuerySearchProvider`：以图搜图复用同一条向量检索路径，
/// 命中解析/类别过滤/视频帧去重与文本语义通道一致。
public final class ContentSupplementaryProvider: SupplementarySearchProvider, JointImageSearchProvider, SemanticWarmupProvider {
    /// 快照模式专用：等待文本语义结果进入引擎缓存（生产热路径绝不调用）。
    public func warmSemanticQuery(_ term: String, timeout: TimeInterval) {
        guard engine.semanticSearchEnabled, !term.isEmpty else { return }
        if engine.cachedSemanticHits(for: term) != nil { return }
        engine.scheduleSemanticSearch(term)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if engine.cachedSemanticHits(for: term) != nil { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }
    private let engine: AstfindEngine

    public init(engine: AstfindEngine) {
        self.engine = engine
        engine.onImageQueryComplete = { [weak self] in self?.notifyImageChange() }
        engine.onJointQueryComplete = { [weak self] in self?.notifyImageChange() }
    }

    public var isEnabled: Bool { true }

    // MARK: - 以图搜图（面板入口走同一条向量检索）

    public var onImageQueryChange: (() -> Void)?
    public static let imageResultLimit = 24
    /// 先多取再按资产去重：一个视频可能独占 top-N 的几十帧，取太少会把其他相似素材挤掉。
    public static let imageFetchLimit = 200
    private let imageLock = NSLock()
    private var imageQuery: ImageQuery?
    private var imagePreviewImage: NSImage?
    private var imagePhase: ImageQueryPhase = .idle
    private var jointPhase: JointImageQueryPhase = .idle
    private var imageGeneration = 0
    private enum QueryMode { case image, person }
    private var queryMode: QueryMode = .image
    private var personQueryData: Data?
    private var personCandidates: [FaceCandidate] = []
    private var personPreviews: [NSImage] = []
    private var personSelectedFace = 0

    public var imagePreview: NSImage? { imageLock.lock(); defer { imageLock.unlock() }; return imagePreviewImage }
    public var imageQueryPhase: ImageQueryPhase { imageLock.lock(); defer { imageLock.unlock() }; return imagePhase }
    public var jointQueryPhase: JointImageQueryPhase { imageLock.lock(); defer { imageLock.unlock() }; return jointPhase }

    public var imageEntryAvailability: ImageEntryAvailability {
        switch engine.imageQueryAvailability() {
        case .available: return .available
        case .unknown: return .unknown
        case .unavailable(let reason): return .unavailable(reason)
        }
    }

    public var isPersonQueryActive: Bool {
        imageLock.lock(); defer { imageLock.unlock() }
        return queryMode == .person && imagePreviewImage != nil
    }

    public var personEntryAvailability: ImageEntryAvailability {
        guard engine.faceSearchEnabled else {
            return .unavailable("人物检索未开启")
        }
        guard engine.faceModelAvailable else {
            return .unavailable("人物模型未安装")
        }
        return .available
    }

    public var personFacePreviews: [NSImage] {
        imageLock.lock(); defer { imageLock.unlock() }
        return personPreviews
    }

    public var selectedPersonFaceIndex: Int {
        imageLock.lock(); defer { imageLock.unlock() }
        return personSelectedFace
    }

    public func selectPersonFace(_ index: Int) {
        imageLock.lock()
        guard index >= 0, index < personCandidates.count else { imageLock.unlock(); return }
        personSelectedFace = index
        imagePhase = .analyzing
        imageLock.unlock()
        notifyImageChange()
    }

    /// 接受参考图：主线程只做头校验与预览；下采样/向量化/检索全部后台。
    public func acceptImageQuery(_ data: Data) -> Bool {
        guard CGImageSourceCreateWithData(data as CFData, nil) != nil else { return false }
        let preview = NSImage(data: data)
        imageLock.lock()
        imageGeneration += 1
        let generation = imageGeneration
        imageQuery = nil
        imagePreviewImage = preview
        imagePhase = .analyzing
        jointPhase = .idle
        imageLock.unlock()
        notifyImageChange()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard let query = ImageQuery.make(from: data) else {
                self.setImagePhase(.failed("无法解码这张图片"), generation: generation)
                return
            }
            self.imageLock.lock()
            guard self.imageGeneration == generation else { self.imageLock.unlock(); return }
            self.imageQuery = query
            if self.imagePreviewImage == nil { self.imagePreviewImage = NSImage(data: query.jpeg) }
            self.imageLock.unlock()
            self.notifyImageChange()
        }
        return true
    }

    /// 人物参考照片：解码/预览后后台检测全部候选脸；查询使用已选候选，避免重复 Vision。
    public func acceptPersonQuery(_ data: Data) -> Bool {
        guard CGImageSourceCreateWithData(data as CFData, nil) != nil else { return false }
        let preview = NSImage(data: data)
        imageLock.lock()
        imageGeneration += 1
        let generation = imageGeneration
        queryMode = .person
        personQueryData = data
        personCandidates = []
        personPreviews = []
        personSelectedFace = 0
        imageQuery = nil
        imagePreviewImage = preview
        imagePhase = .analyzing
        jointPhase = .idle
        imageLock.unlock()
        notifyImageChange()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let candidates = Array(try self.engine.faceCandidates(imageData: data).prefix(6))
                let previews = candidates.map {
                    NSImage(cgImage: $0.alignedImage, size: NSSize(width: 112, height: 112))
                }
                self.imageLock.lock()
                guard self.imageGeneration == generation else { self.imageLock.unlock(); return }
                self.personCandidates = candidates
                self.personPreviews = previews
                self.personSelectedFace = 0
                self.imageLock.unlock()
                self.notifyImageChange()
            } catch {
                self.setImagePhase(.failed("参考图没有检测到人脸"), generation: generation)
            }
        }
        return true
    }

    public func clearImageQuery() {
        imageLock.lock()
        imageGeneration += 1
        queryMode = .image
        personQueryData = nil
        personCandidates = []
        personPreviews = []
        personSelectedFace = 0
        imageQuery = nil
        imagePreviewImage = nil
        imagePhase = .idle
        jointPhase = .idle
        imageLock.unlock()
        notifyImageChange()
    }

    public func imageQueryHits(for sources: [SearchSource], kind: UInt8?,
                               isCancelled: @escaping () -> Bool) -> (hits: [SupplementaryHit], phase: ImageQueryPhase) {
        imageLock.lock()
        let query = imageQuery
        let phase = imagePhase
        let mode = queryMode
        let candidates = personCandidates
        let selectedFace = personSelectedFace
        imageLock.unlock()
        if mode == .person {
            guard !candidates.isEmpty else { return ([], phase == .analyzing ? .analyzing : phase) }
            let candidate = candidates[min(max(0, selectedFace), candidates.count - 1)]
            do {
                let hits = try engine.faceSearch(candidate: candidate, limit: Self.imageFetchLimit,
                                                 minScore: engine.faceMinScore)
                guard !isCancelled() else { return ([], phase) }
                let resolved = resolvePersonHits(hits, sources: sources, kind: kind, isCancelled: isCancelled)
                let ready = ImageQueryPhase.ready(resolved.count)
                setImagePhase(ready)
                return (resolved, ready)
            } catch AstfindEngine.FaceSearchError.modelUnavailable {
                let reason = "人物模型未安装"
                setImagePhase(.unavailable(reason))
                return ([], .unavailable(reason))
            } catch AstfindEngine.FaceSearchError.noFace {
                let reason = "参考图没有检测到人脸"
                setImagePhase(.failed(reason))
                return ([], .failed(reason))
            } catch {
                let reason = "无法读取这张图片"
                setImagePhase(.failed(reason))
                return ([], .failed(reason))
            }
        }
        guard let query else { return ([], phase) }
        switch engine.imageQueryOutcome(for: query, limit: Self.imageFetchLimit) {
        case .analyzing:
            setImagePhase(.analyzing)
            return ([], .analyzing)
        case .unavailable(let reason):
            setImagePhase(.unavailable(reason))
            return ([], .unavailable(reason))
        case .failed(let reason):
            setImagePhase(.failed(reason))
            return ([], .failed(reason))
        case .hits(let hits):
            guard !isCancelled() else { return ([], phase) }
            let resolved = resolveImageHits(hits, sources: sources, kind: kind, isCancelled: isCancelled)
            let ready = ImageQueryPhase.ready(resolved.count)
            setImagePhase(ready)
            return (resolved, ready)
        }
    }

    /// 图文联合查询：图片 + 文字同一条向量检索；融合不可用时引擎已降级为图片召回 + 文本重排。
    public func jointImageHits(for text: String, sources: [SearchSource], kind: UInt8?,
                               isCancelled: @escaping () -> Bool) -> (hits: [SupplementaryHit], phase: JointImageQueryPhase) {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        imageLock.lock()
        let query = imageQuery
        let phase = jointPhase
        let imagePhase = self.imagePhase
        let generation = imageGeneration
        let mode = queryMode
        imageLock.unlock()
        if mode == .person { return ([], .idle) }
        guard let query else {
            // 参考图已接受但仍在归一化/向量化：先保持“分析中”，绝不先返回半联合结果。
            switch imagePhase {
            case .analyzing:
                setJointPhase(.analyzing, generation: generation)
                return ([], .analyzing)
            case .failed(let reason):
                setJointPhase(.failed(reason), generation: generation)
                return ([], .failed(reason))
            case .unavailable(let reason):
                setJointPhase(.unavailable(reason), generation: generation)
                return ([], .unavailable(reason))
            default:
                return ([], phase)
            }
        }
        guard !term.isEmpty else { return ([], .idle) }
        switch engine.jointQueryOutcome(for: JointImageQuery(image: query, text: term),
                                        limit: Self.imageFetchLimit) {
        case .analyzing:
            setJointPhase(.analyzing, generation: generation)
            return ([], .analyzing)
        case .unavailable(let reason):
            setJointPhase(.unavailable(reason), generation: generation)
            return ([], .unavailable(reason))
        case .failed(let reason):
            setJointPhase(.failed(reason), generation: generation)
            return ([], .failed(reason))
        case .hits(let result):
            guard !isCancelled() else { return ([], phase) }
            let resolved = resolveImageHits(result.hits, sources: sources, kind: kind,
                                            isCancelled: isCancelled, label: "图+文")
            let ready = JointImageQueryPhase.ready(count: resolved.count, mode: result.mode,
                                                   fallback: result.fallback)
            AstfindAppExtension.log("joint-query mode=\(result.mode.rawValue) fallback=\(result.fallback?.rawValue ?? "none") count=\(resolved.count)")
            setJointPhase(ready, generation: generation)
            return (resolved, ready)
        }
    }

    /// SMB 视频抽帧是大文件随机读（363GB 素材实测会拖慢整块网盘），
    /// 只给本机/外置盘视频做命中帧缩略图；SMB 保留时间码标签与通用视频图标。
    private func frameThumbnailSources() -> Set<String> {
        Set(((try? engine.records()) ?? []).filter { $0.kind != .smb }.map(\.sourceId))
    }

    /// 人物结果：FaceIndexer 已按资产去重；这里映射回面板 entry，并套用类别筛选。
    private func resolvePersonHits(_ hits: [FaceIndexer.Hit], sources: [SearchSource],
                                   kind: UInt8?, isCancelled: () -> Bool) -> [SupplementaryHit] {
        let frameSources = frameThumbnailSources()
        var result: [SupplementaryHit] = []
        var seen = Set<String>()
        for hit in hits {
            if isCancelled() { break }
            if let kind, Self.kind(ofPath: hit.relativePath) != kind { continue }
            guard let entry = resolve(sourceId: hit.sourceId, relativePath: hit.relativePath,
                                      in: sources) else { continue }
            let key = entry.source.id + "|" + String(entry.entryID)
            guard seen.insert(key).inserted else { continue }
            let name = (hit.relativePath as NSString).lastPathComponent
            let timecode = hit.startMs.map { " @" + Self.timecode($0) } ?? ""
            let frameMs = hit.startMs != nil && frameSources.contains(hit.sourceId) ? hit.startMs : nil
            result.append(SupplementaryHit(
                sourceID: entry.source.id, entryID: entry.entryID,
                detail: "【人物 · 相似度 \(String(format: "%.2f", hit.score))\(timecode)】\(name)",
                highlights: [], thumbnail: true,
                thumbnailTimeMs: frameMs,
                mediaStartMs: hit.startMs))
            if result.count >= Self.imageResultLimit { break }
        }
        return result
    }

    /// 视频帧与图片同表：按资产去重取最佳帧（视频带时间码），类别页签用同一张扩展名表过滤；
    /// 命中顺序保持相似度降序（面板以 preserveHitOrder 呈现，不再被名称/时间排序覆盖）。
    private func resolveImageHits(_ hits: [EmbeddingIndexer.SemanticHit], sources: [SearchSource],
                                  kind: UInt8?, isCancelled: () -> Bool,
                                  label: String = "以图搜图") -> [SupplementaryHit] {
        let frameSources = frameThumbnailSources()
        var best: [String: EmbeddingIndexer.SemanticHit] = [:]
        var order: [String] = []
        for hit in hits {
            if let kind, Self.kind(ofPath: hit.relativePath) != kind { continue }
            if best[hit.assetId] == nil { order.append(hit.assetId) }
            if (best[hit.assetId]?.score ?? -1) < hit.score { best[hit.assetId] = hit }
        }
        var result: [SupplementaryHit] = []
        var seenEntries = Set<String>()
        for assetId in order {
            guard !isCancelled() else { break }
            guard let hit = best[assetId],
                  let entry = resolve(sourceId: hit.sourceId, relativePath: hit.relativePath, in: sources) else { continue }
            let key = entry.source.id + "|" + String(entry.entryID)
            guard seenEntries.insert(key).inserted else { continue }
            let name = (hit.relativePath as NSString).lastPathComponent
            let timecode = hit.kind == "video" ? hit.startMs.map { " @" + Self.timecode($0) } ?? "" : ""
            let frameMs = hit.kind == "video" && frameSources.contains(hit.sourceId) ? hit.startMs : nil
            result.append(SupplementaryHit(sourceID: entry.source.id, entryID: entry.entryID,
                                           detail: "【\(label) · 相似度 \(String(format: "%.2f", hit.score))\(timecode)】\(name)",
                                           highlights: [], thumbnail: true,
                                           thumbnailTimeMs: frameMs,
                                           mediaStartMs: hit.kind == "video" ? hit.startMs : nil))
            if result.count >= Self.imageResultLimit { break }
        }
        return result
    }

    private func setImagePhase(_ new: ImageQueryPhase, generation: Int? = nil) {
        imageLock.lock()
        if let generation, imageGeneration != generation { imageLock.unlock(); return }
        let changed = imagePhase != new
        imagePhase = new
        imageLock.unlock()
        if changed { notifyImageChange() }
    }

    private func setJointPhase(_ new: JointImageQueryPhase, generation: Int? = nil) {
        imageLock.lock()
        if let generation, imageGeneration != generation { imageLock.unlock(); return }
        let changed = jointPhase != new
        jointPhase = new
        imageLock.unlock()
        if changed { notifyImageChange() }
    }

    private func notifyImageChange() {
        if Thread.isMainThread { onImageQueryChange?() }
        else { DispatchQueue.main.async { [weak self] in self?.onImageQueryChange?() } }
    }

    public func prepareSearch(_ query: Query, options: SearchOptions,
                              sources: [SearchSource], isCancelled: @escaping () -> Bool) -> () -> [SupplementaryHit] {
        let term = query.raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, term.count <= 64 else { return { [] } }
        return {
            guard !isCancelled() else { return [] }
            let hits = self.engine.contentSearch(term, limit: 20)
            guard !isCancelled() else { return [] }
            let frameSources = self.frameThumbnailSources()
            var result: [SupplementaryHit] = []
            var seen = Set<String>()
            for hit in hits {
                guard !isCancelled() else { break }
                // 类别筛选（图片/视频/文档…页签）对补充命中同样生效——与主结果同一张扩展名表，
                // 否则「视频」页签下混入图片语义行（2026-10-22 开发者实弹反馈）
                if let wanted = options.kind, Self.kind(ofPath: hit.relativePath) != wanted { continue }
                guard let entry = self.resolve(sourceId: hit.sourceId, relativePath: hit.relativePath, in: sources) else { continue }
                seen.insert(hit.sourceId + "|" + hit.relativePath)
                // 视频帧命中带时间码（PRD：结果含时间码）：【视频帧 @01:23】…
                let label: String
                switch hit.textKind {
                case "ocr": label = "图片OCR"
                case "video": label = "视频帧" + (hit.startMs.map { " @" + Self.timecode($0) } ?? "")
                default: label = "正文"
                }
                let detail = "【\(label)】\(hit.snippet)"
                result.append(SupplementaryHit(sourceID: entry.source.id, entryID: entry.entryID,
                                               detail: detail,
                                               highlights: Self.highlightRanges(of: term, in: detail),
                                               thumbnail: hit.textKind == "ocr" || hit.textKind == "video",
                                               thumbnailTimeMs: hit.textKind == "video" && frameSources.contains(hit.sourceId) ? hit.startMs : nil,
                                               mediaStartMs: hit.textKind == "video" ? hit.startMs : nil))
            }
            // A2 语义（图片）：各通道只付自己的时延——OCR/正文命中立即返回；语义缓存命中即并入，
            // 未命中则请求引擎后台计算（完成后经 onSupplementaryRefresh 让宿主重跑本轮查询）。
            // 教训（2026-10-21 面板 0 结果）：闭包里同步等远端文本向量（限时 2s + 冷探测更久）会把
            // 内容命中一起拖过面板查询代次窗口（键入/索引通知都作废旧代次），全部命中被丢弃。
            if self.engine.semanticSearchEnabled, !isCancelled() {
                if let semanticHits = self.engine.cachedSemanticHits(for: term) {
                    self.appendSemantic(semanticHits, seen: seen, sources: sources,
                                        wantedKind: options.kind, isCancelled: isCancelled, into: &result)
                } else {
                    self.engine.scheduleSemanticSearch(term)
                }
            }
            return result
        }
    }

    /// 语义命中并入补充结果：相似度地板防噪（WeMM 图文余弦实测 0.6 级匹配 / 0.3–0.5 级噪声）；
    /// 与内容命中按 sourceId+路径去重；视频帧多段命中按资产去重取最佳帧（带时间码，PRD：结果含时间码）。
    private func appendSemantic(_ hits: [EmbeddingIndexer.SemanticHit], seen: Set<String>,
                                sources: [SearchSource], wantedKind: UInt8?,
                                isCancelled: () -> Bool,
                                into result: inout [SupplementaryHit]) {
        let frameSources = frameThumbnailSources()
        var bestPerAsset: [String: EmbeddingIndexer.SemanticHit] = [:]
        var order: [String] = []
        for hit in hits where hit.score >= Self.semanticScoreFloor {
            if let wanted = wantedKind, Self.kind(ofPath: hit.relativePath) != wanted { continue }
            if bestPerAsset[hit.assetId] == nil { order.append(hit.assetId) }
            if (bestPerAsset[hit.assetId]?.score ?? -1) < hit.score { bestPerAsset[hit.assetId] = hit }
        }
        for assetId in order {
            guard !isCancelled() else { return }
            guard let hit = bestPerAsset[assetId] else { continue }
            let key = hit.sourceId + "|" + hit.relativePath
            guard !seen.contains(key) else { continue }
            let pseudo = ContentIndexer.ContentHit(assetId: hit.assetId, sourceId: hit.sourceId,
                                                   relativePath: hit.relativePath, snippet: "", textKind: "semantic",
                                                   startMs: hit.startMs)
            guard let entry = self.resolve(sourceId: pseudo.sourceId, relativePath: pseudo.relativePath, in: sources) else { continue }
            let name = (hit.relativePath as NSString).lastPathComponent
            let timecode = hit.kind == "video" ? hit.startMs.map { " @" + Self.timecode($0) } ?? "" : ""
            let detail = "【语义 · 相似度 \(String(format: "%.2f", hit.score))\(timecode)】\(name)"
            result.append(SupplementaryHit(sourceID: entry.source.id, entryID: entry.entryID,
                                           detail: detail, highlights: [], thumbnail: true,
                                           thumbnailTimeMs: hit.kind == "video" && frameSources.contains(hit.sourceId) ? hit.startMs : nil,
                                           mediaStartMs: hit.kind == "video" ? hit.startMs : nil))
        }
    }

    /// 语义命中相似度地板。A0-a 基准定参（2026-10-22，114,583 向量 / 36 查询：真值 12 / 通用 16 / 负例 8）：
    /// 0.35 下 8/8 负例查询泄漏 top-20 共 160 条假阳性；0.50 为拐点——假阳性 21 条（−87%）、
    /// 真值 11/12 查询 58 条命中零损失、通用 top1 16→15；0.55 起伤真值（数据页 0.53 对被切）。
    /// 复评工具 `scripts/a0/a0-bench.py`。详见 wiki《Astfind-A0基准报告-v1》。
    public static var semanticScoreFloor: Float = 0.50

    /// 扩展名 → 类别（与上游 Classifier.extGroups **同表**：1 文件夹 2 应用 3 文档 4 图片
    /// 5 视频 6 音频 7 代码 8 压缩包；上游表为内部实现未导出，此处镜像——上游改表需同步）。
    /// 面板类别页签（图片/视频/…）对主结果与补充命中用同一把尺子过滤。
    public static let kindByExtension: [String: UInt8] = {
        var table: [String: UInt8] = [:]
        let groups: [(UInt8, String)] = [
            (3, "pdf doc docx xls xlsx ppt pptx pages numbers key txt md markdown rtf rtfd csv tsv epub mobi odt ods odp tex log"),
            (4, "png jpg jpeg gif heic heif webp bmp tiff tif svg psd ai sketch fig raw cr2 cr3 nef arw dng ico icns avif"),
            (5, "mp4 mov mkv avi wmv flv webm m4v mpg mpeg 3gp rmvb"),
            (6, "mp3 wav flac aac m4a ogg wma aiff aif opus mid midi caf"),
            (7, "swift c h m mm cpp hpp cc js jsx mjs cjs ts tsx py rb go rs java kt php html htm css scss less vue svelte astro sh zsh bash json yaml yml toml xml sql lua dart cs r pl gradle plist ipynb"),
            (8, "zip rar 7z tar gz bz2 xz tgz zst dmg iso pkg jar war apk ipa")
        ]
        for (kind, list) in groups {
            for ext in list.split(separator: " ") { table[String(ext)] = kind }
        }
        return table
    }()

    private static func kind(ofPath path: String) -> UInt8 {
        kindByExtension[(path as NSString).pathExtension.lowercased()] ?? 0
    }

    /// 毫秒 → mm:ss（≥1 小时为 h:mm:ss）
    public static func timecode(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    public func sourcesDidChange(_ sources: [SearchSource]) { }
    private var wasVisible = false
    /// 面板可见/刚隐藏时让后台 OCR 让路：用户正在看结果或即将打开文件，
    /// 同一 SMB 卷上的随机读不该被几路 OCR 抢走。
    public func userActivity(visible: Bool, typing: Bool) {
        engine.setInteractive(visible: visible, typing: typing)
        // 只在“隐藏→显示”边沿强制重验，避免每次击键都打网络；
        // 用来清掉缓存里的假离线（重扫窗口/临时断链后恢复）。
        if visible && !wasVisible { engine.refreshReachabilityNow() }
        wasVisible = visible
    }

    // MARK: - 路径反查

    /// 内容命中（sourceId + relativePath）→ 面板源列表中的 (source, entryID)。
    /// 先试同 id 源；分块引导期块源 id 不同，退化为逐源尝试 + 丢弃前导段适配块根，
    /// 以 store.path(id) 后缀校验兜底，杜绝张冠李戴。
    private func resolve(sourceId: String, relativePath: String, in sources: [SearchSource]) -> (source: SearchSource, entryID: UInt32)? {
        let components = relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return nil }
        let ordered = sources.sorted { $0.id == sourceId && $1.id != sourceId }
        for source in ordered {
            let store = source.store
            let root = store.rootPath == "/" ? "" : store.rootPath
            let dropMax = min(components.count - 1, 4)
            for drop in 0...dropMax {
                let absolute = root + "/" + components.dropFirst(drop).joined(separator: "/")
                // resolve(path:) 依赖名字哈希表，仅扫描/在线加载路径会构建；
                // 裸加载（离线盘快照）无哈希 → 按文件名搜索兜底 + 绝对路径精确校验
                let id = store.read({ store.resolve(path: absolute) })
                    ?? Self.resolveByName(fileName: components.last!, in: store, absolute: absolute)
                guard let id, store.path(id).hasSuffix("/" + relativePath) else { continue }
                return (source, id)
            }
        }
        return nil
    }

    /// 无哈希兜底：按文件名搜索（Searcher 线性扫名，不依赖哈希），再以绝对路径锁定唯一 entry。
    static func resolveByName(fileName: String, in store: IndexStore, absolute: String) -> UInt32? {
        guard let result = MultiSearcher.search(Query.parse(fileName), in: [
            SearchSource(id: "astfind-resolve", displayName: "", isOnline: true, store: store)
        ]) else { return nil }
        for item in result.items {
            let id = item.entryID
            if store.read({ store.path(id) }) == absolute { return id }
        }
        return nil
    }

    static func highlightRanges(of term: String, in text: String) -> [NSRange] {
        let ns = text as NSString
        guard ns.length > 0, !term.isEmpty else { return [] }
        var ranges: [NSRange] = []
        var cursor = 0
        while ranges.count < 4, cursor <= ns.length {
            let rest = NSRange(location: cursor, length: ns.length - cursor)
            let found = ns.range(of: term, range: rest)
            guard found.location != NSNotFound else { break }
            ranges.append(found)
            cursor = found.location + max(found.length, 1)
        }
        return ranges
    }
}
