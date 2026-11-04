// astfind-sources —— 来源管理与统一搜索 CLI（D5 无头证据入口）
//
//   astfind-sources add <路径> [--name 显示名] [--kind local|external|smb]   注册并立即扫描
//   astfind-sources list                                                    来源清单+状态
//   astfind-sources remove <sourceId|前缀>                                  移除来源（含快照）
//   astfind-sources search <词> [--limit N]                                  跨全部来源统一搜索
//   astfind-sources relink <sourceId|前缀> <新根/锚点文件> [--confirm]        手动重链接（R2；不带 --confirm 仅评估）
//   astfind-sources face status|on|off|enable|disable|scope|enqueue|run|detect|search  M0.8b 人脸索引
//
// ASTFIND_HOME 环境变量可覆盖数据目录（默认 ~/Library/Application Support/Astfind）。
import Foundation
import AstfindKit
import OilFindCore

let args = Array(CommandLine.arguments.dropFirst())
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("ERROR: \(message)\n".utf8))
    exit(2)
}
guard let command = args.first else {
    fail("usage: astfind-sources add|list|status|pause|resume|remove|search ...")
}
let positionals = args.dropFirst().filter { !$0.starts(with: "-") }
func option(_ key: String) -> String? {
    guard let index = args.firstIndex(of: key), index + 1 < args.count else { return nil }
    return args[index + 1]
}

let home = AstfindEngine.defaultHome()
let engine: AstfindEngine
do { engine = try AstfindEngine(home: home) }
catch { fail("cannot open registry at \(home.path): \(error)") }

switch command {
case "add":
    guard let path = positionals.first else { fail("add <绝对路径>") }
    let name = option("--name")
    let kind = SourceRecord.Kind(rawValue: option("--kind") ?? "local") ?? .local
    do {
        let record = try engine.register(path: path, name: name, kind: kind)
        let assets = engine.liveAssetCount(sourceId: record.sourceId)
        print("registered \(record.sourceId) kind=\(record.kind.rawValue) name=\(record.displayName) assets=\(assets)")
    } catch { fail("register failed: \(error)") }

case "list":
    for record in engine.records() {
        let state = record.onlineState == .online ? "online " : "offline"
        print("\(record.sourceId.prefix(8))  \(state)  index=\(record.indexState.rawValue)\(record.indexState == .ready ? "" : "      ")\t\(record.displayName)\t\(record.locator)\t\(record.mountPath ?? "—")")
    }
    if engine.records().isEmpty { print("(no sources; use: astfind-sources add <路径>)") }

case "status":
    // 扫描调度实时状态：阶段（含块引导进度）+ 已扫条目
    engine.start()
    for progress in engine.schedulerProgress() {
        let phase: String
        switch progress.phase {
        case .idle: phase = "idle"
        case .bootstrap(let done, let total): phase = "bootstrap \(done)/\(total)"
        case .rescan: phase = "rescan"
        case .paused: phase = "paused"
        case .ready: phase = "ready"
        }
        print("\(progress.sourceId.prefix(8))  \(phase)\tscanned=\(progress.scanned)\t\(progress.displayName)")
    }
    engine.stop()

case "pause":
    guard let key = positionals.first else { fail("pause <sourceId 或其前缀>") }
    let match = engine.records().filter { $0.sourceId.hasPrefix(key) }
    guard match.count == 1 else { fail("匹配 \(match.count) 个来源") }
    engine.pause(sourceId: match[0].sourceId)
    print("paused \(match[0].displayName)（旧索引保留可搜）")

case "resume":
    guard let key = positionals.first else { fail("resume <sourceId 或其前缀>") }
    let match = engine.records().filter { $0.sourceId.hasPrefix(key) }
    guard match.count == 1 else { fail("匹配 \(match.count) 个来源") }
    engine.resume(sourceId: match[0].sourceId)
    print("resumed \(match[0].displayName)")

case "remove":
    guard let key = positionals.first else { fail("remove <sourceId 或其前缀>") }
    let match = engine.records().filter { $0.sourceId.hasPrefix(key) || $0.locator == key }
    guard match.count == 1 else { fail("匹配 \(match.count) 个来源，需唯一（用更长前缀）") }
    do { try engine.remove(sourceId: match[0].sourceId); print("removed \(match[0].displayName)") }
    catch { fail("remove failed: \(error)") }

case "extract":
    // 内容提取（OCR/PDF/纯文本 → 本地中文 FTS）；可指定来源前缀
    let prefix = positionals.first
    let target: String?
    if let prefix {
        // 含内容专用范围（records() 对其隐藏）——按前缀可直接驱动某个范围的抽取
        let match = (engine.records() + engine.localContentScopes()).filter { $0.sourceId.hasPrefix(prefix) }
        guard match.count == 1 else { fail("匹配 \(match.count) 个来源") }
        target = match[0].sourceId
    } else { target = nil }
    engine.start()
    if let summary = engine.extractContent(sourceId: target) {
        print("METRIC content enqueue-pending-run processed=\(summary.processed) extracted=\(summary.extracted) unchanged=\(summary.skippedUnchanged) failed=\(summary.failed) offline=\(summary.deferredOffline) cleaned=\(summary.cleanedDeletions)")
    } else { fail("content indexer unavailable") }
    engine.stop()

case "content-search":
    guard let term = positionals.first else { fail("content-search <关键词>") }
    let limit = Int(option("--limit") ?? "20") ?? 20
    engine.start()
    let hits = engine.contentSearch(term, limit: limit)
    for hit in hits {
        let tc = hit.startMs.map { " @\(ContentSupplementaryProvider.timecode($0))" } ?? ""
        print("[\(hit.textKind)\(tc)] \(hit.relativePath)\t\(hit.snippet)")
    }
    print("hits=\(hits.count)")
    engine.stop()

case "query":
    // 文件名/路径索引查询基准：只加载本地快照，不启动扫描/不等待 NAS。
    guard let term = positionals.first else { fail("query <关键词> [--samples N]") }
    let samples = max(1, Int(option("--samples") ?? "1") ?? 1)
    let home = AstfindEngine.defaultHome()
    let snapshots = home.appendingPathComponent("snapshots", isDirectory: true)
    var sources: [SearchSource] = []
    for record in engine.records() where !record.contentOnly {
        let url = snapshots.appendingPathComponent(record.sourceId + ".oilfind")
        if let store = IndexStore.load(from: url.path) {
            sources.append(SearchSource(id: record.sourceId, displayName: record.displayName,
                                        isOnline: true, store: store))
        }
    }
    guard !sources.isEmpty else { fail("no local snapshots under \(snapshots.path)") }
    let query = Query.parse(term)
    var times: [Double] = []
    var total = 0
    for _ in 0..<samples {
        let began = ProcessInfo.processInfo.systemUptime
        if let result = MultiSearcher.search(query, in: sources) {
            total = result.total
        }
        times.append((ProcessInfo.processInfo.systemUptime - began) * 1000)
    }
    let sorted = times.sorted()
    let p50 = sorted[max(0, Int(ceil(Double(samples) * 0.5)) - 1)]
    let p95 = sorted[max(0, Int(ceil(Double(samples) * 0.95)) - 1)]
    print("queries=\(samples) sources=\(sources.count) total=\(total) p50_ms=\(String(format: "%.3f", p50)) p95_ms=\(String(format: "%.3f", p95)) max_ms=\(String(format: "%.3f", sorted.last ?? 0))")
    engine.stop()

case "content-query":
    // OCR/正文 FTS 查询基准：不启动扫描。
    guard let term = positionals.first else { fail("content-query <关键词> [--samples N]") }
    let samples = max(1, Int(option("--samples") ?? "1") ?? 1)
    var times: [Double] = []
    var hits = 0
    for _ in 0..<samples {
        let began = ProcessInfo.processInfo.systemUptime
        hits = engine.contentSearch(term, limit: 20).count
        times.append((ProcessInfo.processInfo.systemUptime - began) * 1000)
    }
    let sorted = times.sorted()
    let p50 = sorted[max(0, Int(ceil(Double(samples) * 0.5)) - 1)]
    let p95 = sorted[max(0, Int(ceil(Double(samples) * 0.95)) - 1)]
    print("queries=\(samples) hits=\(hits) p50_ms=\(String(format: "%.3f", p50)) p95_ms=\(String(format: "%.3f", p95)) max_ms=\(String(format: "%.3f", sorted.last ?? 0))")
    engine.stop()

case "semantic-query":
    // 语义查询基准：会调用已配置的 embedding provider，不启动扫描。
    guard let term = positionals.first else { fail("semantic-query <查询> [--samples N]") }
    let samples = max(1, Int(option("--samples") ?? "1") ?? 1)
    var times: [Double] = []
    var hits = 0
    for _ in 0..<samples {
        let began = ProcessInfo.processInfo.systemUptime
        hits = engine.semanticSearch(term, limit: 10, timeout: 15).count
        times.append((ProcessInfo.processInfo.systemUptime - began) * 1000)
    }
    let sorted = times.sorted()
    let p50 = sorted[max(0, Int(ceil(Double(samples) * 0.5)) - 1)]
    let p95 = sorted[max(0, Int(ceil(Double(samples) * 0.95)) - 1)]
    print("queries=\(samples) hits=\(hits) p50_ms=\(String(format: "%.3f", p50)) p95_ms=\(String(format: "%.3f", p95)) max_ms=\(String(format: "%.3f", sorted.last ?? 0))")
    engine.stop()

case "search":
    guard let term = positionals.first else { fail("search <关键词>") }
    let limit = Int(option("--limit") ?? "20") ?? 20
    engine.start()
    engine.waitForScans(timeout: 120)   // 一次性进程：等挂载来源重扫收口再出结果
    guard let result = engine.search(term, limit: limit) else {
        print("no sources registered / no index"); exit(1)
    }
    for row in result.rows {
        let flag = row.online ? "[在线] " : "[离线]"
        print("\(flag)\(row.source)\t\(row.path)")
    }
    print("total=\(result.total) showing=\(result.rows.count)")
    engine.stop()

case "relink":
    // R2 手动重链接（PR 式保底）：relink <sourceId|前缀> <新根目录|锚点文件> [--confirm]
    // 不带 --confirm 只评估出报告（零落库）；带 --confirm 且匹配率 ≥90% 才重绑。
    guard let key = positionals.first, let target = positionals.dropFirst().first else {
        fail("relink <sourceId 或前缀> <新根目录/锚点文件> [--confirm]")
    }
    let match = engine.records().filter { $0.sourceId.hasPrefix(key) }
    guard match.count == 1 else { fail("匹配 \(match.count) 个来源，需唯一（用更长前缀）") }
    let record = match[0]
    do {
        let report = try engine.analyzeRelink(sourceId: record.sourceId, anchor: URL(fileURLWithPath: target))
        let percent = Int((report.matchRate * 100).rounded())
        print("匹配 \(report.matched)/\(report.sampled)（\(percent)%）  候选根=\(report.candidateRoot)")
        print("总资产=\(report.totalAssets)  大小不符=\(report.sizeMismatched)  缺失示例=\(report.missingSamples.count)")
        for miss in report.missingSamples { print("  缺失: \(miss)") }
        guard args.contains("--confirm") else { print("（未加 --confirm：仅评估，不落库）"); exit(0) }
        guard report.meetsThreshold else { fail("匹配率 \(percent)% 低于 90% 阈值，不重绑——请改选目录后重试") }
        try engine.applyRelink(sourceId: record.sourceId, to: report.candidateRoot)
        engine.refreshMounts()
        print("已重绑「\(record.displayName)」→ \(report.candidateRoot)，后台重扫收敛中")
    } catch { fail("relink failed: \(error)") }

case "snapinfo":
    // 快照取证：打印各源快照文件内实际存储的根路径与条目数（诊断 rebase/收敛用）
    for record in engine.records() {
        let url = home.appendingPathComponent("snapshots").appendingPathComponent(record.sourceId + ".oilfind")
        guard let store = IndexStore.load(from: url.path) else {
            print("\(record.sourceId.prefix(8))  LOAD FAILED\t\(record.displayName)"); continue
        }
        print("\(record.sourceId.prefix(8))  root=\(store.rootPath)  live=\(store.liveCount)\t\(record.displayName)")
    }

case "scope":
    // 本机内容索引范围（P0 选择器的无头入口；实弹/自动化用，GUI 走设置页确认流）
    //   scope list | scope add <目录> | scope estimate <目录> | scope remove <前缀>
    let sub = positionals.first ?? "list"
    switch sub {
    case "list":
        let scopes = engine.localContentScopes()
        if scopes.isEmpty { print("(no local content scopes)") }
        for scope in scopes {
            print("\(scope.sourceId.prefix(8))  \(engine.liveAssetCount(sourceId: scope.sourceId)) 个文件\t\(scope.displayName)\t\(scope.locator)")
        }
    case "estimate":
        guard let dir = positionals.dropFirst().first else { fail("scope estimate <绝对路径>") }
        let e = engine.localContentEstimate(dirPath: dir)
        print("图片=\(e.images) 文档=\(e.documents) 共=\(e.total) 大小=\(ByteCountFormatter.string(fromByteCount: e.totalBytes, countStyle: .file)) 预计\(e.estimatedSeconds(lanes: engine.extractionLanes))s@\(engine.extractionLanes)路")
    case "add":
        guard let dir = positionals.dropFirst().first else { fail("scope add <绝对路径>") }
        let storeURL = home.appendingPathComponent("index.oilfind")
        guard let store = IndexStore.load(from: storeURL.path) else {
            fail("面板主索引不存在（\(storeURL.path)）——需 App 至少完成过一次本机文件名索引")
        }
        do {
            let record = try engine.ensureLocalContentSource(dirPath: dir, store: store)
            engine.start()   // 踢抽取泵
            print("scope \(record.sourceId.prefix(8)) \(record.displayName) assets=\(engine.liveAssetCount(sourceId: record.sourceId))")
        } catch { fail("scope add failed: \(error)") }
    case "remove":
        guard let key = positionals.dropFirst().first else { fail("scope remove <sourceId 或前缀>") }
        let match = engine.localContentScopes().filter { $0.sourceId.hasPrefix(key) }
        guard match.count == 1 else { fail("匹配 \(match.count) 个范围") }
        do { try engine.remove(sourceId: match[0].sourceId); print("removed \(match[0].displayName)") }
        catch { fail("remove failed: \(error)") }
    default:
        fail("scope list|add|estimate|remove")
    }

case "progress":
    // 抽取进度（动刀清单 3 号）：各源 已完成/剩余/失败；速率/预计只在本进程泵运转时有值
    let items = engine.extractionProgress()
    if items.isEmpty { print("(no extraction jobs)") }
    for item in items {
        let rate = item.ratePerMinute.map { String(format: "%.0f/分", $0) } ?? "—"
        let eta = item.etaSeconds.map { "\($0)s" } ?? "—"
        print("\(item.sourceId.prefix(8))  done=\(item.done) remaining=\(item.remaining) failed=\(item.failed) rate=\(rate) eta=\(eta)\t\(item.displayName)")
        if item.failed > 0, args.contains("--failed") {
            for path in engine.failedExtractionSamples(sourceId: item.sourceId, limit: 5) { print("    failed: \(path)") }
        }
    }

case "video":
    // 视频帧 OCR 开关（L2，默认关）：video status | video on | video off
    switch positionals.first ?? "status" {
    case "on":
        engine.setVideoOCR(enabled: true)
        engine.start(); engine.waitForScans(timeout: 5)
        print("video OCR enabled（已为全部来源排队视频，泵在跑）")
        engine.stop()
    case "off":
        engine.setVideoOCR(enabled: false)
        print("video OCR disabled（未处理的视频任务已清）")
    default:
        print("video OCR: \(engine.videoOCREnabled ? "on" : "off")")
    }

case "providers":
    // A1 Provider 骨架：providers list|probe|add-http|remove|egress on|off|embed
    let hub = engine.providers
    func runAsync<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox2<T>()
        Task { box.value = await body(); semaphore.signal() }
        semaphore.wait()
        return box.value!
    }
    switch positionals.first ?? "list" {
    case "list":
        let config = hub.current
        let status = hub.semanticStatus()
        let active = status.providerId.map { "\($0)（\(status.mode.displayName)）" } ?? "（未配置）"
        print("semantic mode: \(status.mode.displayName)\(status.inferred ? "（旧配置推断）" : "")  当前模型: \(active)")
        if config.httpEmbeddings.isEmpty { print("(no providers configured)") }
        for item in config.httpEmbeddings {
            let probe = hub.lastProbe(id: item.id).map { detail -> String in
                if case .available(let ms, let caps) = detail { return "可用 \(ms)ms dim=\(caps.dimensions.map(String.init) ?? "?")" }
                if case .unavailable(let e) = detail { return "不可用(\(e))" }
                return ""
            } ?? "未探测"
            let mark = item.id == status.providerId ? "\t← 语义模型" : ""
            print("\(item.id)\t\(probe)\t\(item.displayName)\t\(item.model)\t\(item.endpoint.absoluteString)\(mark)")
        }
        print("remote egress: \(hub.egress.allowsRemote ? "允许（已授权外发）" : "拒绝（默认，仅本机回环）")")
    case "mode":
        guard let raw = positionals.dropFirst().first else {
            let status = hub.semanticStatus()
            print("semantic mode: \(status.mode.rawValue)（\(status.mode.displayName)）\(status.inferred ? " · 旧配置按 Provider 推断" : "")")
            print("用法：providers mode off|remote|local")
            break
        }
        guard let mode = SemanticMode(rawValue: raw) else { fail("mode 只能是 off|remote|local") }
        do {
            try engine.setSemanticMode(mode)
            print("semantic mode → \(mode.displayName)（已停掉入库泵；用 semantic on 显式开始建向量）")
            switch mode {
            case .off: print("语义通道关闭：不注册图片 Provider，文件名/OCR/正文不受影响")
            case .remote: print("只使用非回环端点；未授权外发时一个字节都不发（providers egress on 授权）")
            case .local: print("只使用本机回环端点（127.0.0.1/localhost/::1），永不外发")
            }
        } catch { fail("mode failed: \(error)") }
    case "probe":
        let results = runAsync { await hub.probeAll() }
        for (id, probe) in results.sorted(by: { $0.key < $1.key }) {
            switch probe {
            case .available(let ms, let caps): print("\(id)  可用 latency=\(ms)ms dim=\(caps.dimensions.map(String.init) ?? "?") model=\(caps.model ?? "?") 图片=\(caps.embedImage ? "支持（实测）" : "不支持") 批量=\(caps.batchImages > 1 ? "×\(caps.batchImages)（实测）" : "串行")")
            case .unavailable(let e): print("\(id)  不可用 \(e)")
            }
        }
    case "add-http":
        guard let id = positionals.dropFirst().first, let endpoint = positionals.dropFirst(2).first,
              let model = positionals.dropFirst(3).first else {
            fail("providers add-http <id> <endpoint> <model> [--name 显示名] [--key-ref 密钥引用名] [--images dataurl] [--batch N]")
        }
        guard let url = URL(string: endpoint), url.scheme != nil else { fail("endpoint 非法") }
        let images: HTTPEmbeddingProvider.ImageInput = option("--images") == "dataurl" ? .dataURL : .unsupported
        let batch = option("--batch").flatMap(Int.init)
        do {
            try hub.addHTTPEmbedding(.init(id: id, displayName: option("--name") ?? id, endpoint: url,
                                           model: model, apiKeyRef: option("--key-ref"), imageInput: images,
                                           maxBatchImages: (batch ?? 1) > 1 ? batch : nil))
            print("added \(id) → \(model) @ \(endpoint)\(images == .dataURL ? "（声明图片 data URL 约定，探测时实测）" : "")\(batch != nil && batch! > 1 ? "（批量 ×\(batch!)，探测时实测确认）" : "")")
        } catch { fail("add failed: \(error)") }
    case "set-batch":
        guard let id = positionals.dropFirst().first, let n = positionals.dropFirst(2).first.flatMap(Int.init) else {
            fail("providers set-batch <id> <N>  （N≤1 关闭批量）")
        }
        do {
            try hub.updateHTTPEmbedding(id: id) { $0.maxBatchImages = n > 1 ? n : nil }
            print("\(id) maxBatchImages=\(n > 1 ? n : 1)（重启引擎/重跑 providers probe 后生效于能力）")
        } catch { fail("set-batch failed: \(error)") }
    case "embed-image":
        guard let id = positionals.dropFirst().first, let path = positionals.dropFirst(2).first else {
            fail("providers embed-image <id> <图片路径>")
        }
        guard let provider = hub.embeddingProviders.first(where: { $0.id == id }) else { fail("无此 provider") }
        let began = Date()
        let result = runAsync { () -> Result<[Float], ProviderError> in
            do { return .success(try await provider.embedImage(at: URL(fileURLWithPath: path))) }
            catch { return .failure(ProviderError.classify(error)) }
        }
        switch result {
        case .success(let vector): print("dim=\(vector.count) 耗时=\(Int(Date().timeIntervalSince(began) * 1000))ms 前4维=\(vector.prefix(4).map { String(format: "%.4f", $0) }.joined(separator: ", "))")
        case .failure(let e): fail("embed-image failed: \(e)")
        }
    case "remove":
        guard let id = positionals.dropFirst().first else { fail("providers remove <id>") }
        try? hub.remove(id: id); print("removed \(id)")
    case "egress":
        let value = positionals.dropFirst().first
        do {
            switch value {
            case "on": try hub.setAllowRemoteEgress(true); print("remote egress: 允许（内容将外发到远端 Provider）")
            case "off": try hub.setAllowRemoteEgress(false); print("remote egress: 拒绝")
            default: print("remote egress: \(hub.egress.allowsRemote ? "on" : "off")")
            }
        } catch { fail("egress failed: \(error)") }
    case "embed":
        guard let id = positionals.dropFirst().first, let text = positionals.dropFirst(2).first else {
            fail("providers embed <id> <文本>")
        }
        guard let provider = hub.embeddingProviders.first(where: { $0.id == id }) else { fail("无此 provider") }
        let result = runAsync { () -> Result<[Float], ProviderError> in
            do { return .success(try await provider.embedText(text)) } catch { return .failure(ProviderError.classify(error)) }
        }
        switch result {
        case .success(let vector): print("dim=\(vector.count) 前4维=\(vector.prefix(4).map { String(format: "%.4f", $0) }.joined(separator: ", "))")
        case .failure(let e): fail("embed failed: \(e)")
        }
    default:
        fail("providers list|mode|probe|add-http|set-batch|embed-image|remove|egress|embed")
    }

final class ResultBox2<T>: @unchecked Sendable { var value: T? }

case "face":
    // M0.8b 人脸索引：status | on | off | enable <前缀> | disable <前缀> | enqueue [前缀|all] | run [--limit N] | detect <图> | search <图> [--face-index N]
    guard let face = engine.face else { fail("face indexer unavailable") }
    let faceCommand = positionals.first ?? "status"
    switch faceCommand {
    case "status":
        let status = engine.faceStatus()
        print("face search: \(status.enabled ? "on" : "off")   model: \(status.modelAvailable ? "ready" : "missing")   sources=\(status.enabledSources)")
        print("face jobs: pending=\(status.counts.pending) running=\(status.counts.running) done=\(status.counts.done) failed=\(status.counts.failed)")
        print("face vectors: \(status.embeddings)   model path: \(engine.faceModelURL.path)")
    case "on":
        engine.setFaceSearchEnabled(true)
        print("face search enabled; model=\(engine.faceModelAvailable ? "ready" : "missing")")
    case "off":
        engine.setFaceSearchEnabled(false)
        print("face search disabled")
    case "enable", "disable":
        guard let key = positionals.dropFirst().first else { fail("face \(faceCommand) <sourceId 或其前缀>") }
        let matches = engine.records().filter { $0.sourceId.hasPrefix(key) }
        guard matches.count == 1 else { fail("匹配 \(matches.count) 个来源") }
        let enabled = faceCommand == "enable"
        let cleared = try engine.setFaceIndexEnabled(sourceId: matches[0].sourceId, enabled: enabled)
        print("face source \(enabled ? "enabled" : "disabled"): \(matches[0].displayName) cleared=\(cleared)")
    case "scope":
        guard let key = positionals.dropFirst().first,
              let raw = positionals.dropFirst(2).first else {
            fail("face scope <sourceId 或其前缀> <相对路径前缀|clear>")
        }
        let matches = engine.records().filter { $0.sourceId.hasPrefix(key) }
        guard matches.count == 1 else { fail("匹配 \(matches.count) 个来源") }
        let prefix = (raw == "clear" || raw == "-") ? nil : raw
        let cleared = try engine.setFaceIndexPrefix(sourceId: matches[0].sourceId, prefix: prefix)
        print("face scope \(matches[0].displayName): \(prefix ?? "整个来源") cleared=\(cleared)")
    case "enqueue":
        let key = positionals.dropFirst().first ?? "all"
        let targets = engine.records().filter { $0.faceIndexEnabled && (key == "all" || $0.sourceId.hasPrefix(key)) }
        guard !targets.isEmpty else { fail("没有启用 face_index 的来源") }
        for record in targets {
            let n = (try? face.enqueuePending(sourceId: record.sourceId)) ?? 0
            print("\(record.sourceId.prefix(8))  +\(n) face jobs\t\(record.displayName)")
        }
    case "run":
        let limit = Int(option("--limit") ?? "25") ?? 25
        let summary = try face.runPending(limit: limit)
        print("METRIC face processed=\(summary.processed) embedded=\(summary.embedded) noFace=\(summary.noFace) failed=\(summary.failed) offline=\(summary.deferredOffline) modelUnavailable=\(summary.modelUnavailable)")
    case "detect":
        guard let path = positionals.dropFirst().first else { fail("face detect <参考图片>") }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let candidates = try engine.faceCandidates(imageData: data)
            print("faces=\(candidates.count)")
            for candidate in candidates {
                print("#\(candidate.index) quality=\(String(format: "%.3f", candidate.quality)) bbox=\(candidate.boundingBox)")
            }
        } catch { fail("face detect failed: \(error)") }
    case "search":
        guard let path = positionals.dropFirst().first else { fail("face search <参考图片>") }
        let limit = Int(option("--limit") ?? "20") ?? 20
        let faceIndex = Int(option("--face-index") ?? "0") ?? 0
        let minScore = Double(option("--min-score") ?? "0.5") ?? 0.5
        do {
            let hits = try engine.faceSearch(imageURL: URL(fileURLWithPath: path), faceIndex: faceIndex,
                                             limit: limit, minScore: minScore)
            for hit in hits {
                let tc = hit.startMs.map { " @" + String(format: "%d:%02d", $0 / 60_000, ($0 / 1_000) % 60) } ?? ""
                print(String(format: "%.4f", hit.score) + "\t" + hit.relativePath + tc + "\t" + hit.sourceId.prefix(8))
            }
            print("hits=\(hits.count)")
        } catch { fail("face search failed: \(error)") }
    default:
        fail("face status|on|off|enable|disable|scope|enqueue|run|detect|search")
    }

case "semantic":
    // A2 图片语义：semantic status | on | off | enqueue [前缀|all] | run [--lanes N] | search <查询>
    guard let semantic = engine.semantic else { fail("embedding indexer unavailable") }
    switch positionals.first ?? "status" {
    case "status":
        let counts = (try? semantic.counts()) ?? .init()
        let status = engine.semanticStatus()
        print("semantic mode: \(status.mode.displayName)\(status.inferred ? "（旧配置推断）" : "")  索引: \(engine.semanticSearchEnabled ? "on" : "off")")
        if let active = engine.activeImageEmbedding() {
            print("provider: \(active.provider.id) profile=\(active.profile.id) dim=\(active.profile.dimension) vectors=\(semantic.embeddingCount(profile: active.profile))")
        } else if status.mode == .off {
            print("provider: （语义模型已关闭）")
        } else { print("provider: （无经探测支持图片的 \(status.mode.displayName) Provider）") }
        print("embed jobs: pending=\(counts.pending) running=\(counts.running) done=\(counts.done) failed=\(counts.failed)")
        let videos = (try? semantic.videoCounts()) ?? .init()
        print("embed-video jobs: pending=\(videos.pending) running=\(videos.running) done=\(videos.done) failed=\(videos.failed)")
    case "on":
        if engine.semanticStatus().mode == .off {
            print("注意：语义模型模式为关闭（先 providers mode remote|local）——不会建立任何向量")
        }
        engine.setSemanticSearch(enabled: true); print("semantic search enabled")
    case "off": engine.setSemanticSearch(enabled: false); print("semantic search disabled")
    case "enqueue":
        guard let active = engine.activeImageEmbedding() else { fail("无可用图片 Provider（先 providers add-http … --images dataurl 并 egress on）") }
        try? semantic.ensureProfile(active.profile)
        let key = positionals.dropFirst().first ?? "all"
        let targets = ((try? engine.records()) ?? []).filter { $0.contentIndexEnabled && (key == "all" || $0.sourceId.hasPrefix(key)) }
        for record in targets {
            let n = (try? semantic.enqueuePending(sourceId: record.sourceId, profile: active.profile)) ?? 0
            print("\(record.sourceId.prefix(8))  +\(n) embed jobs\t\(record.displayName)")
        }
    case "run":
        // 前台跑泵（实弹/无头用）；常驻 App 内由引擎泵自动跑，二者勿同时对同库跑
        guard let active = engine.activeImageEmbedding() else { fail("无可用图片 Provider") }
        let lanes = Int(option("--lanes") ?? "2") ?? 2
        let began = Date(); var total = 0
        while true {
            let sources = (try? semantic.pendingSourceIds()) ?? []
            if sources.isEmpty { break }
            for sourceId in sources {
                let s = (try? semantic.runPending(limit: 25, sourceId: sourceId, lanes: lanes, provider: active.provider, profile: active.profile)) ?? .init()
                total += s.embedded
                print("round src=\(sourceId.prefix(8)) embedded=\(s.embedded) unchanged=\(s.skippedUnchanged) failed=\(s.failed) transient=\(s.transientFailures) deferred=\(s.deferredOffline) elapsed=\(Int(Date().timeIntervalSince(began)))s total=\(total)")
                if s.transientFailures > 0 && s.embedded == 0 { Thread.sleep(forTimeInterval: 15) }
            }
        }
        print("done: embedded=\(total) in \(Int(Date().timeIntervalSince(began)))s")
    case "enqueue-video":
        guard let active = engine.activeImageEmbedding() else { fail("无可用图片 Provider") }
        try? semantic.ensureProfile(active.profile)
        let key = positionals.dropFirst().first ?? "all"
        let targets = ((try? engine.records()) ?? []).filter { $0.contentIndexEnabled && (key == "all" || $0.sourceId.hasPrefix(key)) }
        for record in targets {
            let n = (try? semantic.enqueuePendingVideos(sourceId: record.sourceId, profile: active.profile)) ?? 0
            print("\(record.sourceId.prefix(8))  +\(n) embed-video jobs\t\(record.displayName)")
        }
    case "run-video":
        // 前台跑视频帧语义（实弹/无头用）；常驻 App 内由引擎泵视频优先自动跑，二者勿同时对同库跑
        guard let active = engine.activeImageEmbedding() else { fail("无可用图片 Provider") }
        let key = positionals.dropFirst().first
        let began = Date(); var total = 0
        while true {
            let sources = (try? semantic.videoPendingSourceIds()) ?? []
                .filter { key == nil || $0.hasPrefix(key!) }
            if sources.isEmpty { break }
            for sourceId in sources {
                let s = (try? semantic.runPendingVideo(limit: 2, sourceId: sourceId, lanes: 2, provider: active.provider, profile: active.profile)) ?? .init()
                total += s.embedded
                print("round src=\(sourceId.prefix(8)) embedded=\(s.embedded) failed=\(s.failed) transient=\(s.transientFailures) quarantined=\(s.quarantined) deferred=\(s.deferredOffline) elapsed=\(Int(Date().timeIntervalSince(began)))s total=\(total)")
                if s.transientFailures > 0 && s.embedded == 0 { Thread.sleep(forTimeInterval: 15) }
            }
        }
        print("done: videos=\(total) in \(Int(Date().timeIntervalSince(began)))s")
    case "search":
        guard let term = positionals.dropFirst().first else { fail("semantic search <查询>") }
        let began = Date()
        let hits = engine.semanticSearch(term, limit: Int(option("--limit") ?? "10") ?? 10, timeout: 15)
        for hit in hits {
            let timecode = hit.kind == "video" ? hit.startMs.map { " @" + ContentSupplementaryProvider.timecode($0) } ?? "" : ""
            print(String(format: "%.3f", hit.score), "\t", "\(timecode)\t", hit.relativePath)
        }
        print("hits=\(hits.count) elapsed=\(Int(Date().timeIntervalSince(began) * 1000))ms")
    case "image-search":
        guard let path = positionals.dropFirst().first else { fail("semantic image-search <图片路径> [--limit N]") }
        guard let query = ImageQuery.make(fromFile: URL(fileURLWithPath: path), timeout: 10) else {
            fail("无法读取或解码图片（读取超过 10s 或格式不支持）")
        }
        let began = Date()
        let limit = Int(option("--limit") ?? "20") ?? 20
        switch engine.imageSearch(query, limit: limit, timeout: 30) {
        case .hits(let hits):
            for hit in hits {
                let timecode = hit.kind == "video" ? hit.startMs.map { " @" + ContentSupplementaryProvider.timecode($0) } ?? "" : ""
                print(String(format: "%.3f", hit.score), "\t", "\(hit.kind)\(timecode)\t", hit.relativePath)
            }
            print("hits=\(hits.count) elapsed=\(Int(Date().timeIntervalSince(began) * 1000))ms")
        case .analyzing:
            fail("查询仍在后台进行（不应发生在同步路径）")
        case .unavailable(let reason), .failed(let reason):
            fail(reason)
        }
    case "joint-search":
        // 真实素材标定入口：joint-search <图片> <文字> [--alpha 0.7] [--limit N]
        guard positionals.count >= 3 else { fail("semantic joint-search <图片路径> <文字> [--alpha 0.7] [--limit N]") }
        guard let query = ImageQuery.make(fromFile: URL(fileURLWithPath: positionals[1]), timeout: 10) else {
            fail("无法读取或解码图片（读取超过 10s 或格式不支持）")
        }
        let term = positionals[2]
        let limit = Int(option("--limit") ?? "20") ?? 20
        let alpha = Float(option("--alpha") ?? "0.7") ?? JointImageQuery.defaultAlpha
        let began = Date()
        switch engine.jointImageSearch(JointImageQuery(image: query, text: term, alpha: alpha),
                                       limit: limit, timeout: 30) {
        case .hits(let result):
            for hit in result.hits {
                let timecode = hit.kind == "video" ? hit.startMs.map { " @" + ContentSupplementaryProvider.timecode($0) } ?? "" : ""
                print(String(format: "%.3f", hit.score), "\t", "\(hit.kind)\(timecode)\t", hit.relativePath)
            }
            print("hits=\(result.hits.count) mode=\(result.mode.rawValue) fallback=\(result.fallback?.rawValue ?? "none") elapsed=\(Int(Date().timeIntervalSince(began) * 1000))ms")
        case .analyzing:
            fail("查询仍在后台进行（不应发生在同步路径）")
        case .unavailable(let reason), .failed(let reason):
            fail(reason)
        }
    default: fail("semantic status|on|off|enqueue|enqueue-video|run|run-video|search|image-search|joint-search")
    }

case "probe-supplementary":
    // 复刻面板补充通道全链路（prepareSearch → resolve）——面板无结果时区分引擎侧/面板侧。
    // 2026-10-21 起语义走异步缓存：第一波应 <1s 只有内容命中；等后台算完第二波应并入语义行。
    guard let term = positionals.first else { fail("probe-supplementary <词>") }
    engine.start()   // sources() 依赖调度器会话（attach+loadOffline），必须走完整启动
    Thread.sleep(forTimeInterval: 3)
    let provider = ContentSupplementaryProvider(engine: engine)
    let sources = engine.sources()
    print("sources=\(sources.count) isOnline=\(sources.map { $0.isOnline })")

    let run: (String) -> [String] = { label in
        let began = Date()
        let options = SearchOptions(kind: (option("--kind").flatMap { UInt8($0) }))
        let hits = provider.prepareSearch(Query.parse(term), options: options,
                                          sources: sources, isCancelled: { false })()
        let ms = Int(Date().timeIntervalSince(began) * 1000)
        print("[\(label)] supplementary hits=\(hits.count) elapsed=\(ms)ms")
        for hit in hits.prefix(5) { print("  ", hit.detail) }
        return hits.map(\.detail)
    }
    let wave1 = run("第一波")
    let semanticDone = { engine.cachedSemanticHits(for: term)?.isEmpty == false }
    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline, !semanticDone() { Thread.sleep(forTimeInterval: 0.2) }
    let wave2 = run("第二波")
    let hasSemantic = wave2.contains { $0.contains("语义") }
    print("语义并入=\(hasSemantic ? "是" : "否（Provider 关闭/不可达/无命中均可能）") 缓存=\(engine.cachedSemanticHits(for: term) != nil ? "有" : "无")")
    if wave1.isEmpty, wave2.isEmpty { print("两波皆空：引擎侧问题") }
    else if !wave1.isEmpty { print("引擎侧正常；面板仍无结果 → 面板侧问题") }

default:
    fail("unknown command \(command)")
}
