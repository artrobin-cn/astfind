import Foundation

/// 内容索引器：`index_jobs` 记账驱动的可恢复提取管线（D6）。
///
/// 第一性原理：
/// 1. 提取是**低优先级、可恢复**的工作——绝不阻塞文件名搜索（热路径零交集）；
/// 2. **变更检测**（size/mtime token）避免重复提取——OCR/PDF 都不便宜；
/// 3. 源离线 → 任务留 pending，重连后续跑（NAS 失联可恢复）；
/// 4. 观察与资产解耦（D2 schema）：text_observations 挂 asset_id，FTS 由应用层事务同步。
public final class ContentIndexer {
    public struct Summary: Equatable, Sendable {
        public var enqueued = 0
        public var processed = 0
        public var extracted = 0
        public var skippedUnchanged = 0
        public var failed = 0
        public var deferredOffline = 0
        public var cleanedDeletions = 0
    }

    public struct ContentHit: Equatable, Sendable {
        public let assetId: String
        public let sourceId: String
        public let relativePath: String
        public let snippet: String
        public let textKind: String
        /// 时间媒体命中的起始时间码（毫秒）；非时间媒体为 nil
        public let startMs: Int?
        public init(assetId: String, sourceId: String, relativePath: String, snippet: String, textKind: String, startMs: Int? = nil) {
            self.assetId = assetId; self.sourceId = sourceId; self.relativePath = relativePath
            self.snippet = snippet; self.textKind = textKind; self.startMs = startMs
        }
    }

    private let database: Database
    /// 同来源执行门：ready/一次性触发/泵轮竞争时，后到批次快速返回（M0.6）。
    private let batchGate = ContentBatchGate()
    /// 提取器组合（视频帧 OCR 按开关热切换；仅在写队列内读写）
    private var extractors: ContentExtractorRegistry
    private let queue = DispatchQueue(label: "astfind.content")   // 单写者（抽取/入队/落库）
    // 检索热路径独立只读连接 + 独立队列：WAL 之下读写并发，搜索永不排在抽取批次后
    // （2026-10-19 实锤：App 后台抽取 12 万任务时，共用队列曾致面板内容检索长时间无响应）
    private let readerQueue = DispatchQueue(label: "astfind.content.reader", qos: .userInitiated)
    private lazy var reader: Database? = Database.openReadOnly(url: databaseURL)

    private let databaseURL: URL
    /// 测试/诊断：当前实际执行的批次数量（同一来源最多 1）。
    var activeBatchCountForTesting: Int { batchGate.activeCount }
    public init(databaseURL: URL, extractors: ContentExtractorRegistry = ContentExtractorRegistry()) throws {
        self.databaseURL = databaseURL
        self.database = try Database(url: databaseURL)
        try Migrations.apply(to: database)   // v2 trigram 等随内容层演进
        self.extractors = extractors
    }

    // MARK: - 入队（幂等：每资产至多一个 pending 任务）

    public func enqueuePending(sourceId: String) throws -> Int {
        try queue.sync {
            // 单次候选查询 + 事务内批量插入。旧实现逐资产 COUNT+INSERT，
            // 9 万资产的源一次入队独占写队列数分钟，把泵轮/触发全部堵死（2026-10-20 采样实锤）。
            let candidates = try database.query("""
                SELECT a.asset_id, a.relative_path FROM assets a
                WHERE a.source_id = ? AND a.deleted_confirmed_at IS NULL
                  AND NOT EXISTS (SELECT 1 FROM index_jobs j
                                  WHERE j.asset_id = a.asset_id AND j.job_type = 'extract_text'
                                    AND (j.state IN ('pending', 'failed')
                                         OR (j.state = 'done'
                                             AND j.checkpoint_json = (a.size || ':' || COALESCE(a.mtime_ns, 0)))))
                """, [.text(sourceId)]) { ($0.columnText(0), $0.columnText(1)) }
            var inserted = 0
            try database.transaction {
                for (assetId, relativePath) in candidates {
                    let name = (relativePath as NSString).lastPathComponent
                    // exFAT/FAT 的 AppleDouble 边车与 .DS_Store 是元数据碎片，不是可读内容
                    if name.hasPrefix("._") || name == ".DS_Store" { continue }
                    guard extractors.extractor(for: name) != nil else { continue }
                    // 视频帧 OCR 优先于图片（认领按 priority DESC）：图片积压数万，
                    // 不提级则视频关键字要等图片排空才轮到（用户当下要搜视频）
                    let priority = VideoFrameOCRExtractor.supportedExtensions
                        .contains((name as NSString).pathExtension.lowercased()) ? 1 : 0
                    try database.run("""
                        INSERT INTO index_jobs (job_id, source_id, asset_id, job_type, state, priority)
                        VALUES (?,?,?,?, 'pending', ?)
                        """, [.text(UUID().uuidString), .text(sourceId), .text(assetId), .text("extract_text"), .int(Int64(priority))])
                    inserted += 1
                }
            }
            return inserted
        }
    }

    // MARK: - 执行（批处理；离线任务自动留队）

    /// - Parameter sourceId: 优先处理该来源的任务——按源触发（内容专用来源建立/
    ///   新源扫描就绪）时不必排在全局积压之后（曾致外置盘内容卡在数万 NAS 任务后面）。
    /// - Parameter lanes: 并发提取路数（1=省电 2=标准 4=全速）。并行的是"读文件+OCR"，
    ///   数据库写入仍走单写者——认领（running）防并发双跑，结果统一回写；看门狗每路保留。
    @discardableResult
    public func runPending(limit: Int = 200, sourceId: String? = nil, lanes: Int = 1,
                           shouldPause: @escaping () -> Bool = { false }) throws -> Summary {
        // limit=0 只做入队/空批次，不占执行门，保持原行为。
        let gated = limit > 0
        if gated {
            guard batchGate.tryAcquire(sourceId) else {
                NSLog("astfind extract merge src=%@ reason=source-busy", sourceId ?? "*")
                return Summary()
            }
        }
        defer { if gated { batchGate.release(sourceId) } }
        let roundBegan = Date()
        let summary = try runPendingLocked(limit: limit, sourceId: sourceId, lanes: max(1, lanes),
                                           shouldPause: shouldPause)
        NSLog("astfind extract src=%@ lanes=%d limit=%d processed=%d failed=%d deferred=%d unchanged=%d cleaned=%d elapsed=%.1fs",
              sourceId ?? "*", max(1, lanes), limit, summary.processed, summary.failed, summary.deferredOffline,
              summary.skippedUnchanged, summary.cleanedDeletions, Date().timeIntervalSince(roundBegan))
        return summary
    }

    /// 启动回收：上一进程崩溃/被杀时残留在 running 的任务放回 pending（进程边界执行，避免抢并发在飞任务）。
    public func reclaimOrphanedJobs() throws {
        try queue.sync {
            try database.run("UPDATE index_jobs SET state = 'pending' WHERE state = 'running'", [])
        }
    }

    private struct ExtractionWork {
        let jobId: String, sourceId: String, assetId: String
        let url: URL, extractor: ContentExtracting, token: String
        let kind: String, profile: String
    }

    private func runPendingLocked(limit: Int, sourceId: String?, lanes: Int,
                                  shouldPause: () -> Bool) throws -> Summary {
        var summary = Summary()
        var work: [ExtractionWork] = []

        // ── 阶段 1：写队列内认领 + 分类（DB 与轻量 IO；旧语义全保留）──
        try queue.sync {
            // 删除清理不依赖任务存在：任何"已确认删除"资产的残留观察都主动清扫
            // （enqueue 不会给已删资产排队，靠任务路径清理永远不触发——曾致 cleanedDeletions 恒 0）
            let orphans = try database.query("""
                SELECT o.asset_id FROM text_observations o
                JOIN assets a ON a.asset_id = o.asset_id
                WHERE a.deleted_confirmed_at IS NOT NULL
                """, []) { $0.columnText(0) }
            for assetId in orphans {
                try removeObservations(assetId: assetId)
                summary.cleanedDeletions += 1
            }
            let jobs: [(String, String, String)]
            if let sourceId {
                jobs = try database.query("""
                    SELECT j.job_id, j.source_id, j.asset_id FROM index_jobs j
                    WHERE j.state = 'pending' AND j.job_type = 'extract_text' AND j.source_id = ? ORDER BY j.priority DESC, j.rowid LIMIT ?
                    """, [.text(sourceId), .int(Int64(limit))]) { ($0.columnText(0), $0.columnText(1), $0.columnText(2)) }
            } else {
                jobs = try database.query("""
                    SELECT j.job_id, j.source_id, j.asset_id FROM index_jobs j
                    WHERE j.state = 'pending' AND j.job_type = 'extract_text' ORDER BY j.priority DESC, j.rowid LIMIT ?
                    """, [.int(Int64(limit))]) { ($0.columnText(0), $0.columnText(1), $0.columnText(2)) }
            }
            // 每个源只查一次挂载点/做一次可达性判断：25 个任务不再重复 stat 同一个 SMB 根。
            var mountState: [String: (path: String, reachable: Bool)] = [:]
            for (jobId, jobSourceId, assetId) in jobs {
                // 用户回到面板/正在打开文件：停止继续认领，未认领的任务保持 pending。
                if shouldPause() { break }
                // 原子认领：并发调用方（泵轮 + 一次性触发）之间互斥，抢不到即让行
                try database.run("UPDATE index_jobs SET state = 'running' WHERE job_id = ? AND state = 'pending'",
                                 [.text(jobId)])
                guard database.changes == 1 else { continue }
                // 源挂载点（离线 = 挂起回 pending，绝不误删）；mount_path 为 NULL 时 columnText 得空串，同样视为离线
                if let cached = mountState[jobSourceId] {
                    guard cached.reachable else {
                        try finish(jobId, state: "pending")
                        summary.deferredOffline += 1
                        continue
                    }
                } else {
                    let mount = try database.query(
                        "SELECT mount_path FROM storage_sources WHERE source_id = ?",
                        [.text(jobSourceId)]) { $0.columnText(0) }.first ?? ""
                    let reachable = !mount.isEmpty && FileManager.default.fileExists(atPath: mount)
                    mountState[jobSourceId] = (mount, reachable)
                    guard reachable else {
                        try finish(jobId, state: "pending")
                        summary.deferredOffline += 1
                        continue
                    }
                }
                let mount = mountState[jobSourceId]!.path
                guard let asset = try database.query("""
                    SELECT relative_path, size, mtime_ns, deleted_confirmed_at FROM assets WHERE asset_id = ?
                    """, [.text(assetId)], map: {
                        ($0.columnText(0), $0.columnInt(1),
                         $0.columnIsNull(2) ? nil : $0.columnInt(2), !$0.columnIsNull(3))
                    }).first else {
                    try finish(jobId, state: "done"); continue
                }
                if asset.3 {   // 资产已被完整扫描确认删除 → 观察随之清理（兜底路径，常规清理在批首）
                    try removeObservations(assetId: assetId)
                    try finish(jobId, state: "done")
                    continue
                }
                let fileName = (asset.0 as NSString).lastPathComponent
                // 防御纵深：v4 迁移已清存量，这里保证任何来源的 ._/.DS_Store 永不被执行
                if fileName.hasPrefix("._") || fileName == ".DS_Store" {
                    try finish(jobId, state: "failed")
                    continue
                }
                let path = mount + "/" + asset.0
                let url = URL(fileURLWithPath: path)
                guard let extractor = extractors.extractor(for: fileName) else {
                    try finish(jobId, state: "failed")
                    summary.failed += 1
                    continue
                }
                summary.processed += 1
                // 变更 token 直接用扫描落库的 size/mtime，不再对每个任务同步 resourceValues：
                // NAS 失联时 getattrlist 会卡在失效的 smbfs 连接上，且这里在内容写队列内，
                // 一个坏源足以把整轮抽取（以及入队）拖死。
                // 注意：mtime_ns 列实际存 epoch 秒（与 EmbeddingIndexer 的 content_change_token 同源）。
                let newSize = asset.1
                let newMtime = asset.2
                let token = "\(newSize):\(newMtime ?? 0)"
                // "未变更"的真值 = 已存观察的 content_change_token（提取过的同一版本）。
                // 绝不能与 assets 行比较——那本来就镜像同一文件，恒相等（曾致首次提取被跳过）。
                let extractedBefore = try database.query(
                    "SELECT content_change_token FROM text_observations WHERE asset_id = ? LIMIT 1",
                    [.text(assetId)]) { $0.columnText(0) }.first
                if extractedBefore == token {
                    try finish(jobId, state: "done", checkpoint: token)
                    summary.skippedUnchanged += 1
                    continue
                }
                let textKind = extractor.profile.hasPrefix("video") ? "video"
                    : extractor.profile.hasPrefix("ocr") ? "ocr" : "document"
                work.append(ExtractionWork(jobId: jobId, sourceId: jobSourceId, assetId: assetId,
                                           url: url, extractor: extractor, token: token,
                                           kind: textKind, profile: extractor.profile))
            }
        }
        guard !work.isEmpty else { return summary }

        // ── 阶段 2：并发提取（读文件 + OCR；信号量限路，看门狗每任务）──
        let semaphore = DispatchSemaphore(value: lanes)
        let group = DispatchGroup()
        let outcomeLock = NSLock()
        var outcomes: [(work: ExtractionWork, payload: ExtractionPayload?, threw: Bool, deferred: Bool)] = []
        for item in work {
            semaphore.wait(); group.enter()
            // 已进入交互（面板可见/刚隐藏）：把已认领但还没开跑的任务退回 pending，
            // 不等它把 180s 看门狗跑满；最多只牺牲正在跑的那几路。
            if shouldPause() {
                outcomeLock.lock()
                outcomes.append((item, nil, false, true))
                outcomeLock.unlock()
                semaphore.signal(); group.leave(); continue
            }
            DispatchQueue.global(qos: .utility).async {
                defer { semaphore.signal(); group.leave() }
                // 看门狗：NAS 上的 ._ 假图片曾把 Vision 吊死在内部信号量上、整泵停摆。
                // 任何单文件超过时限即熔断记失败（牺牲线程自行了断，队列绝不陪葬）。
                // 时限按提取器（视频按帧 OCR 远慢于单图）。
                var payload: ExtractionPayload? = nil, threw = false
                do { payload = try Self.extractPayloadWithTimeout(item.extractor, url: item.url, seconds: item.extractor.watchdogSeconds) }
                catch { threw = true }
                outcomeLock.lock()
                outcomes.append((item, payload, threw, false))
                outcomeLock.unlock()
            }
        }
        group.wait()

        // ── 阶段 3：写队列统一回写（单写者语义不变）──
        var deferredCount = 0
        try queue.sync {
            for (item, payload, threw, deferred) in outcomes {
                if deferred {
                    deferredCount += 1
                    try finish(item.jobId, state: "pending")
                    continue
                }
                guard !threw, let payload else {
                    try finish(item.jobId, state: "failed")
                    summary.failed += 1
                    continue
                }
                try? upsertObservation(assetId: item.assetId, sourceId: item.sourceId, kind: item.kind,
                                       profile: item.profile, body: payload.body, token: item.token,
                                       segments: payload.segments)
                try finish(item.jobId, state: "done", checkpoint: item.token)
                summary.extracted += 1
            }
        }
        summary.processed = max(0, summary.processed - deferredCount)
        return summary
    }

    // MARK: - 检索（trigram ≥3 字；1–2 字 LIKE 兜底——中文双字词高频）

    public func search(_ term: String, limit: Int = 20) throws -> [ContentHit] {
        // 优先只读连接（独立队列）；首启竞态等场景回退写连接
        if let reader {
            return try readerQueue.sync {
                try Self.performSearch(reader, term: term, limit: limit)
            }
        }
        return try queue.sync {
            try Self.performSearch(database, term: term, limit: limit)
        }
    }

    fileprivate static func performSearch(_ database: Database, term: String, limit: Int) throws -> [ContentHit] {
        // 查询字符串一律走参数绑定：SQL 与 FTS/LIKE 语法都不能由用户输入改写。
        let sql: String
        let binds: [SQLiteValue]
        if term.count >= 3 {
            // FTS5 短语：内部双引号必须双写（`"` → `""`），否则一个引号就能闭合短语、
            // 把剩余输入当查询语法执行（轻则报错，重则 `*`/列限定改变命中范围）。
            let phrase = "\"" + term.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            sql = """
            SELECT o.asset_id, a.source_id, a.relative_path, o.text_kind,
                   snippet(text_observation_fts, 0, '「', '」', '…', 10), o.start_ms
            FROM text_observation_fts
            JOIN text_observations o ON o.rowid = text_observation_fts.rowid
            JOIN assets a ON a.asset_id = o.asset_id AND a.deleted_confirmed_at IS NULL
            WHERE text_observation_fts MATCH ?
            LIMIT ?
            """
            binds = [.text(phrase), .int(Int64(limit))]
        } else {
            // 1–2 字兜底：LIKE 的通配符必须先转义，否则 `%`/`_` 会变成“任意内容”查询。
            let pattern = "%" + term
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_") + "%"
            sql = """
            SELECT o.asset_id, a.source_id, a.relative_path, o.text_kind, substr(o.body, 1, 80), o.start_ms
            FROM text_observations o
            JOIN assets a ON a.asset_id = o.asset_id AND a.deleted_confirmed_at IS NULL
            WHERE o.body LIKE ? ESCAPE '\\'
            LIMIT ?
            """
            binds = [.text(pattern), .int(Int64(limit))]
        }
        return try database.query(sql, binds) {
            ContentHit(assetId: $0.columnText(0), sourceId: $0.columnText(1),
                       relativePath: $0.columnText(2), snippet: $0.columnText(4),
                       textKind: $0.columnText(3),
                       startMs: $0.columnIsNull(5) ? nil : Int($0.columnInt(5)))
        }
    }

    /// 有 pending 任务的来源集合（抽取泵轮转用：各源公平分速，不互相饿死）。
    public func pendingSourceIds() throws -> [String] {
        try queue.sync {
            try database.query("SELECT DISTINCT source_id FROM index_jobs WHERE state = 'pending' AND job_type = 'extract_text'",
                               []) { $0.columnText(0) }
        }
    }

    public func pendingCount() throws -> Int {
        try queue.sync {
            try database.query("SELECT COUNT(*) FROM index_jobs WHERE state = 'pending' AND job_type = 'extract_text'",
                               []) { Int($0.columnInt(0)) }.first ?? 0
        }
    }

    /// 关闭某来源内容索引时清理尚未处理的任务；已完成/失败记录保留，便于重新开启后增量补齐。
    /// running 任务不在这里删除——当前批次允许完成，之后不再认领新任务。
    @discardableResult
    public func clearPending(sourceId: String) throws -> Int {
        try queue.sync {
            let count = try database.query("""
                SELECT COUNT(*) FROM index_jobs
                WHERE source_id = ? AND job_type = 'extract_text' AND state = 'pending'
                """, [.text(sourceId)]) { Int($0.columnInt(0)) }.first ?? 0
            guard count > 0 else { return 0 }
            try database.run("""
                DELETE FROM index_jobs
                WHERE source_id = ? AND job_type = 'extract_text' AND state = 'pending'
                """, [.text(sourceId)])
            return count
        }
    }

    /// 认领中（running）任务数。泵排空判定必须连同 pending 一起看：
    /// 认领瞬间任务离开 pending 但尚未回写，只看 pending 会提前宣布排空（竞态实锤 2026-10-20）。
    public func runningCount() throws -> Int {
        try queue.sync {
            try database.query("SELECT COUNT(*) FROM index_jobs WHERE state = 'running' AND job_type = 'extract_text'",
                               []) { Int($0.columnInt(0)) }.first ?? 0
        }
    }

    // MARK: - 进度可视化（只读连接：设置页 1.5s 轮询绝不排在抽取批次后）

    public struct JobCounts: Equatable, Sendable {
        public var pending = 0, running = 0, done = 0, failed = 0
    }

    /// 各源任务状态计数（一条 GROUP BY；走只读连接，首启竞态回退写连接）。
    public func jobCountsBySource() throws -> [String: JobCounts] {
        let sql = "SELECT source_id, state, COUNT(*) FROM index_jobs WHERE job_type = 'extract_text' GROUP BY source_id, state"
        let rows: [(String, String, Int)]
        if let reader {
            rows = try readerQueue.sync { try reader.query(sql) { ($0.columnText(0), $0.columnText(1), Int($0.columnInt(2))) } }
        } else {
            rows = try queue.sync { try database.query(sql) { ($0.columnText(0), $0.columnText(1), Int($0.columnInt(2))) } }
        }
        var result: [String: JobCounts] = [:]
        for (sourceId, state, count) in rows {
            var counts = result[sourceId] ?? JobCounts()
            switch state {
            case "pending": counts.pending = count
            case "running": counts.running = count
            case "done": counts.done = count
            case "failed": counts.failed = count
            default: break
            }
            result[sourceId] = counts
        }
        return result
    }

    /// 失败任务样本（相对路径）——抽查入口：830+ failed 到底是 ._ 垃圾还是真失败，一眼可辨。
    public func failedSamples(sourceId: String, limit: Int = 5) throws -> [String] {
        let sql = """
            SELECT a.relative_path FROM index_jobs j JOIN assets a ON a.asset_id = j.asset_id
            WHERE j.state = 'failed' AND j.job_type = 'extract_text' AND j.source_id = ? ORDER BY j.rowid DESC LIMIT ?
            """
        let args: [SQLiteValue] = [.text(sourceId), .int(Int64(limit))]
        if let reader {
            return try readerQueue.sync { try reader.query(sql, args) { $0.columnText(0) } }
        }
        return try queue.sync { try database.query(sql, args) { $0.columnText(0) } }
    }

    // MARK: - 私有

    /// 提取产物：全文 + 可选时间码分段（视频等时间媒体）。
    struct ExtractionPayload {
        let body: String
        let segments: [TimedText]?
    }

    /// 带超时的提取：超时返回 nil（调用方记失败）。信号量的 happens-before 保证结果交接安全；
    /// 超时后牺牲线程继续跑完自行释放（罕见病态文件才触发，线程泄漏有界）。
    static func extractWithTimeout(_ extractor: ContentExtracting, url: URL, seconds: TimeInterval) throws -> String? {
        try extractPayloadWithTimeout(extractor, url: url, seconds: seconds)?.body
    }

    /// 分段感知版：时间媒体走 extractSegments（全文=各段拼接，供 FTS），其余走 extract。
    static func extractPayloadWithTimeout(_ extractor: ContentExtracting, url: URL, seconds: TimeInterval) throws -> ExtractionPayload? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = PayloadBox()
        DispatchQueue(label: "astfind.extract.watch", qos: .utility).async {
            box.result = Result {
                if let segments = try extractor.extractSegments(at: url) {
                    return ExtractionPayload(body: segments.map(\.text).joined(separator: "\n"), segments: segments)
                }
                return ExtractionPayload(body: try extractor.extract(at: url), segments: nil)
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + seconds) == .success, let result = box.result else { return nil }
        return try result.get()   // 提取器错误原样上抛，走既有 failed 路径
    }

    final class PayloadBox: @unchecked Sendable {
        var result: Result<ExtractionPayload, Error>?
    }

    private func finish(_ jobId: String, state: String, checkpoint: String? = nil) throws {
        if let checkpoint {
            try database.run("UPDATE index_jobs SET state = ?, checkpoint_json = ? WHERE job_id = ?",
                             [.text(state), .text(checkpoint), .text(jobId)])
        } else {
            try database.run("UPDATE index_jobs SET state = ? WHERE job_id = ?", [.text(state), .text(jobId)])
        }
    }

    /// 落观测：非时间媒体一行全文；时间媒体每段一行（start/end_ms + media_segments 行），
    /// 全部共享同一 content_change_token（变更检测取任一行即可）。
    private func upsertObservation(assetId: String, sourceId: String, kind: String,
                                   profile: String, body: String, token: String,
                                   segments: [TimedText]? = nil) throws {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try database.transaction {
            try removeObservations(assetId: assetId)
            if let segments {
                for segment in segments where !segment.text.isEmpty {
                    let segmentId = UUID().uuidString
                    try database.run("""
                        INSERT OR IGNORE INTO media_segments (segment_id, asset_id, kind, start_ms, end_ms)
                        VALUES (?,?,?,?,?)
                        """, [.text(segmentId), .text(assetId), .text("video_frame_text"),
                              .int(Int64(segment.startMs)), .int(Int64(segment.endMs))])
                    try database.run("""
                        INSERT INTO text_observations (observation_id, asset_id, segment_id, text_kind, body,
                                                       start_ms, end_ms, extractor_profile, content_change_token)
                        VALUES (?,?,?,?,?,?,?,?,?)
                        """, [.text(UUID().uuidString), .text(assetId), .text(segmentId), .text(kind), .text(segment.text),
                              .int(Int64(segment.startMs)), .int(Int64(segment.endMs)), .text(profile), .text(token)])
                    try database.run("""
                        INSERT INTO text_observation_fts(rowid, body)
                        SELECT rowid, body FROM text_observations WHERE asset_id = ? ORDER BY rowid DESC LIMIT 1
                        """, [.text(assetId)])
                }
                return
            }
            try database.run("""
                INSERT INTO text_observations (observation_id, asset_id, segment_id, text_kind, body,
                                               extractor_profile, content_change_token)
                VALUES (?,?,NULL,?,?,?,?)
                """, [.text(UUID().uuidString), .text(assetId), .text(kind), .text(body), .text(profile), .text(token)])
            try database.run("""
                INSERT INTO text_observation_fts(rowid, body)
                SELECT rowid, body FROM text_observations WHERE asset_id = ? ORDER BY rowid DESC LIMIT 1
                """, [.text(assetId)])
        }
    }

    private func removeObservations(assetId: String) throws {
        let rowIds = try database.query(
            "SELECT rowid FROM text_observations WHERE asset_id = ?", [.text(assetId)]) { $0.columnInt(0) }
        for rowId in rowIds {
            try database.run("DELETE FROM text_observation_fts WHERE rowid = ?", [.int(rowId)])
        }
        try database.run("DELETE FROM text_observations WHERE asset_id = ?", [.text(assetId)])
        try database.run("DELETE FROM media_segments WHERE asset_id = ?", [.text(assetId)])
    }

    /// 热切换提取器时清掉指定扩展名的 done 任务，使 `enqueuePending` 重新入队。
    /// 仅视频 OCR 开关使用；普通重启/重扫不会调用，因此已索引内容不会反复排队。
    @discardableResult
    public func resetDoneJobs(extensions: Set<String>) throws -> Int {
        try queue.sync {
            let like = extensions.map { "a.relative_path LIKE '%.\($0)'" }.joined(separator: " OR ")
            guard !like.isEmpty else { return 0 }
            let jobs = try database.query("""
                SELECT j.job_id FROM index_jobs j JOIN assets a ON a.asset_id = j.asset_id
                WHERE j.job_type = 'extract_text' AND j.state = 'done' AND (\(like))
                """, []) { $0.columnText(0) }
            guard !jobs.isEmpty else { return 0 }
            try database.transaction {
                for jobId in jobs {
                    try database.run("DELETE FROM index_jobs WHERE job_id = ?", [.text(jobId)])
                }
            }
            return jobs.count
        }
    }

    // MARK: - 视频帧 OCR 开关（默认关；热切换）

    /// 切换提取器组合。关闭时清掉尚未处理的视频任务（否则每轮认领→无提取器→终态 failed，
    /// 把本可日后处理的视频永久标失败）；开启由调用方重新入队。
    public func setVideoOCR(enabled: Bool) throws {
        try queue.sync {
            extractors = ContentExtractorRegistry.standard(videoOCR: enabled)
            guard !enabled else { return }
            let exts = VideoFrameOCRExtractor.supportedExtensions
            let pending = try database.query("""
                SELECT j.job_id, a.relative_path FROM index_jobs j JOIN assets a ON a.asset_id = j.asset_id
                WHERE j.state = 'pending' AND j.job_type = 'extract_text'
                """) { ($0.columnText(0), $0.columnText(1)) }
            try database.transaction {
                for (jobId, path) in pending where exts.contains((path as NSString).pathExtension.lowercased()) {
                    try database.run("DELETE FROM index_jobs WHERE job_id = ?", [.text(jobId)])
                }
            }
        }
    }
}
