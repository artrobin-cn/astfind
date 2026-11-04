import Foundation
import Accelerate
import ImageIO
import CoreGraphics
import AVFoundation
import UniformTypeIdentifiers

/// A2 图片语义：向量入库与检索（D2 `media_segments`/`embeddings`/`embedding_profiles` 预留位兑现）。
///
/// 第一性原理：
/// 1. 向量存 Mac 本地（决策 #4）；4096 维 float32=16KB/图 → **int8 量化**（每向量 max-abs 刻度）4KB/图，
///    12 万图 ≈0.5GB；检索=归一化后点积（余弦），暴力扫描先行，ANN 后置。
/// 2. 身份=资产+profile；content_change_token 未变不重算（与内容观测同一变更检测语义）。
/// 3. 与内容泵同构的三段式：写队列原子认领 → 并发调 Provider → 写队列统一回写；
///    `job_type='embed_image'` 与 `extract_text` 共表隔离，互不认领。
/// 4. 图片**本地下采样**（长边 ≤1024 JPEG）再发——保护网络与服务端，也是隐私最小化（发的是缩略图）。
public final class EmbeddingIndexer {
    public struct Profile: Equatable, Sendable {
        public let id: String
        public let providerId: String
        public let model: String
        public let dimension: Int
        public init(id: String, providerId: String, model: String, dimension: Int) {
            self.id = id; self.providerId = providerId; self.model = model; self.dimension = dimension
        }
        /// 约定：`<providerId>-image-v1`
        public static func image(providerId: String, model: String, dimension: Int) -> Profile {
            Profile(id: "\(providerId)-image-v1", providerId: providerId, model: model, dimension: dimension)
        }
    }
    public struct Summary: Equatable, Sendable {
        public var processed = 0, embedded = 0, skippedUnchanged = 0, failed = 0, deferredOffline = 0
        /// 本轮失败是否全为环境类（服务端/超时/配额）——泵据此退避
        public var transientFailures = 0
        /// 毒图隔离：近期有成功证据期间的失败记满 10 笔后终态 failed 的任务数
        public var quarantined = 0
        /// 本轮最后一次失败的原因（错误分类 + 批大小）——泵日志排障用；批量被毒图拖死时一眼可辨
        public var lastFailure: String?
        public init() {}
    }
    public struct SemanticHit: Equatable, Sendable {
        public let assetId: String
        public let sourceId: String
        public let relativePath: String
        public let score: Float
        /// 视频帧命中的时间码（毫秒）；图片为 nil。
        public let startMs: Int?
        /// 段类型："image" / "video"——展示层选标签用。
        public let kind: String
    }

    private let databaseURL: URL
    private let database: Database
    private let queue = DispatchQueue(label: "astfind.embedding")   // 单写者
    private let readerQueue = DispatchQueue(label: "astfind.embedding.reader", qos: .userInitiated)
    private lazy var reader: Database? = Database.openReadOnly(url: databaseURL)
    public var maxLongSide: CGFloat = 1024
    public var jpegQuality: CGFloat = 0.85
    /// 最近一次成功入库时间（写队列内访问）——毒图隔离的"服务端健康证据"。
    /// 进程重启即清零（保守：重启后的首批失败不记笔，直到出现成功）。
    private var lastSuccessAt: Date?
    /// 隔离阈值：健康证据期间的连续失败记满 N 笔 → 终态 failed（毒图不再每轮空转）。
    /// 10 笔配合退避（15s→5min）足够分辨"个别毒图"与"间歇抖动"，且远低于纯宕机误杀窗口。
    public static let quarantineStrikes = 10
    /// 健康证据窗口：此窗口内的成功入库才证明服务端活着（跨源共享证据——
    /// 毒图所在源只剩毒图时，靠其他源的成功给记笔背书）。
    public static let healthyWindow: TimeInterval = 600

    public init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        self.database = try Database(url: databaseURL)
        try Migrations.apply(to: database)
    }

    // MARK: - Profile

    public func ensureProfile(_ profile: Profile) throws {
        try queue.sync {
            let json = "{\"provider\":\"\(profile.providerId)\",\"model\":\"\(profile.model)\",\"input\":\"image\"}"
            try database.run("""
                INSERT OR IGNORE INTO embedding_profiles
                (profile_id, provider_kind, model_id, model_revision, preprocessor_revision, modality, dimension, normalization, quantization, profile_json)
                VALUES (?,?,?,?,?,?,?,?,?,?)
                """, [.text(profile.id), .text("http"), .text(profile.model), .text("unversioned"),
                      .text("downscale\(Int(maxLongSide))-jpeg\(Int(jpegQuality * 100))"), .text("image"),
                      .int(Int64(profile.dimension)), .text("l2"), .text("int8-maxabs"), .text(json)])
        }
    }

    // MARK: - 向量空间身份（换模型/换维度不得复用同一 profile）

    /// 向量空间的身份 = 模型 + 预处理 + 维度，而**不是** Provider 槽位。
    ///
    /// 若同一 provider id 换了模型/维度却继续写 `<providerId>-image-v1`：
    /// `enqueuePending` 会把旧进程写下的向量当成"已入库"而永不补算，检索时维度不符又被
    /// `dot` 静默跳过——语义通道看似开着、结果永远为空（假死）。所以身份必须随模型变化。
    ///
    /// 兼容既有数据：旧库只有一条 `<providerId>-image-v1`；签名一致则继续用它
    /// （**绝不触发全量重嵌**）；签名不一致才派生带模型指纹的新 id，旧 profile 原样保留只读。
    public func resolveProfile(providerId: String, model: String, dimension: Int) -> Profile {
        let legacy = Profile.image(providerId: providerId, model: model, dimension: dimension)
        guard let stored = storedProfileSignature(id: legacy.id) else { return legacy }
        if stored.model == model && stored.dimension == dimension { return legacy }
        return Profile(id: Self.derivedProfileId(providerId: providerId, model: model, dimension: dimension),
                       providerId: providerId, model: model, dimension: dimension)
    }

    /// 模型/维度已经变化时的 profile id：可读前缀 + 模型短指纹 + 维度（确定性，同输入同 id）。
    static func derivedProfileId(providerId: String, model: String, dimension: Int) -> String {
        let slug = model.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let trimmed = String(slug).split(separator: "-").joined(separator: "-")
        let base = trimmed.isEmpty ? "model" : String(trimmed.prefix(24))
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in model.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return "\(providerId)-image-\(base)-\(dimension)-v1-\(String(format: "%08x", UInt32(truncatingIfNeeded: hash)))"
    }

    private func storedProfileSignature(id: String) -> (model: String, dimension: Int)? {
        let rows: [(String, Int)] = readRows(
            "SELECT model_id, dimension FROM embedding_profiles WHERE profile_id = ?", [.text(id)]) {
                ($0.columnText(0), Int($0.columnInt(1)))
            } ?? []
        return rows.first.map { (model: $0.0, dimension: $0.1) }
    }

    /// 全部向量空间及向量数（设置页「切换模型」提示用）。只读连接，不阻塞入库。
    public struct ProfileSummary: Equatable, Sendable {
        public let id: String
        public let model: String
        public let dimension: Int
        public let vectors: Int
        public init(id: String, model: String, dimension: Int, vectors: Int) {
            self.id = id; self.model = model; self.dimension = dimension; self.vectors = vectors
        }
    }

    public func profileSummaries() -> [ProfileSummary] {
        let sql = """
            SELECT p.profile_id, p.model_id, p.dimension, COUNT(e.embedding_id)
            FROM embedding_profiles p LEFT JOIN embeddings e ON e.profile_id = p.profile_id
            GROUP BY p.profile_id
            ORDER BY COUNT(e.embedding_id) DESC, p.profile_id
            """
        return readRows(sql, []) {
            ProfileSummary(id: $0.columnText(0), model: $0.columnText(1),
                           dimension: Int($0.columnInt(2)), vectors: Int($0.columnInt(3)))
        } ?? []
    }

    /// 读连接优先（有 reader 时不与写队列抢锁）；返回 nil 表示查询失败，与「空结果」区分。
    private func readRows<T>(_ sql: String, _ params: [SQLiteValue], map: (Statement) -> T) -> [T]? {
        if let reader { return try? readerQueue.sync { try reader.query(sql, params, map: map) } }
        return try? queue.sync { try database.query(sql, params, map: map) }
    }

    // MARK: - 入队（幂等：每资产至多一个 pending embed 任务；已有同 token 向量者不排）

    public func enqueuePending(sourceId: String, profile: Profile) throws -> Int {
        try queue.sync {
            let exts = VisionOCRExtractor.supportedExtensions
            // 单遍 LEFT JOIN（配 v5 索引）取代逐资产相关子查询：9 万资产入队秒级而非数分钟（采样实锤）。
            // SQL 侧先按扩展名粗筛（LIKE 对 ASCII 不区分大小写），Swift 侧再精确过滤。
            let likeClauses = exts.map { "a.relative_path LIKE '%.\($0)'" }.joined(separator: " OR ")
            let candidates = try database.query("""
                SELECT a.asset_id, a.relative_path FROM assets a
                LEFT JOIN index_jobs j ON j.asset_id = a.asset_id AND j.job_type = 'embed_image'
                                      AND j.state IN ('pending', 'running', 'failed')
                LEFT JOIN media_segments s ON s.asset_id = a.asset_id AND s.kind = 'image' AND s.start_ms = 0 AND s.end_ms = 0
                LEFT JOIN embeddings e ON e.segment_id = s.segment_id AND e.profile_id = ?
                                      AND e.content_change_token = (a.size || ':' || COALESCE(a.mtime_ns, 0))
                WHERE a.source_id = ? AND a.deleted_confirmed_at IS NULL
                  AND j.job_id IS NULL AND e.embedding_id IS NULL
                  AND (\(likeClauses))
                """, [.text(profile.id), .text(sourceId)]) { ($0.columnText(0), $0.columnText(1)) }
            var inserted = 0
            try database.transaction {
                for (assetId, relativePath) in candidates {
                    let name = (relativePath as NSString).lastPathComponent
                    if name.hasPrefix("._") || name == ".DS_Store" { continue }
                    guard exts.contains((name as NSString).pathExtension.lowercased()) else { continue }
                    try database.run("""
                        INSERT INTO index_jobs (job_id, source_id, asset_id, job_type, state, priority)
                        VALUES (?,?,?,'embed_image','pending',0)
                        """, [.text(UUID().uuidString), .text(sourceId), .text(assetId)])
                    inserted += 1
                }
            }
            return inserted
        }
    }

    public func pendingSourceIds() throws -> [String] {
        try queue.sync {
            try database.query("SELECT DISTINCT source_id FROM index_jobs WHERE state = 'pending' AND job_type = 'embed_image'") { $0.columnText(0) }
        }
    }

    /// 关闭内容索引来源时清理尚未处理的图片/视频向量任务；running 允许完成。
    @discardableResult
    public func clearPending(sourceId: String) throws -> Int {
        try queue.sync {
            let count = try database.query("""
                SELECT COUNT(*) FROM index_jobs
                WHERE source_id = ? AND state = 'pending'
                  AND job_type IN ('embed_image', 'embed_video')
                """, [.text(sourceId)]) { Int($0.columnInt(0)) }.first ?? 0
            guard count > 0 else { return 0 }
            try database.run("""
                DELETE FROM index_jobs
                WHERE source_id = ? AND state = 'pending'
                  AND job_type IN ('embed_image', 'embed_video')
                """, [.text(sourceId)])
            return count
        }
    }

    public struct Counts: Equatable, Sendable {
        public var pending = 0, running = 0, done = 0, failed = 0
        public init() {}
    }
    public func counts() throws -> Counts {
        let rows = try queue.sync {
            try database.query("SELECT state, COUNT(*) FROM index_jobs WHERE job_type = 'embed_image' GROUP BY state") { ($0.columnText(0), Int($0.columnInt(1))) }
        }
        var counts = Counts()
        for (state, n) in rows {
            switch state {
            case "pending": counts.pending = n
            case "running": counts.running = n
            case "done": counts.done = n
            case "failed": counts.failed = n
            default: break
            }
        }
        return counts
    }

    public func embeddingCount(profile: Profile) -> Int {
        (try? queue.sync {
            try database.query("SELECT COUNT(*) FROM embeddings WHERE profile_id = ?", [.text(profile.id)]) { Int($0.columnInt(0)) }.first
        }) ?? 0
    }

    /// 视频帧向量数（设置页进度展示用；读连接，不阻塞入库）
    public func videoVectorCount(profile: Profile) -> Int {
        let sql = """
            SELECT COUNT(*) FROM embeddings e JOIN media_segments s ON s.segment_id = e.segment_id
            WHERE e.profile_id = ? AND s.kind = 'video'
            """
        if let reader { return (try? readerQueue.sync { try reader.query(sql, [.text(profile.id)]) { Int($0.columnInt(0)) }.first }) ?? 0 }
        return (try? queue.sync { try database.query(sql, [.text(profile.id)]) { Int($0.columnInt(0)) }.first }) ?? 0
    }

    // MARK: - 执行（三段式）

    private struct Work { let jobId, assetId, sourceId: String; let url: URL; let token: String }

    public func runPending(limit: Int = 25, sourceId: String? = nil, lanes: Int = 2,
                           provider: EmbeddingProvider, profile: Profile) throws -> Summary {
        var summary = Summary()
        var work: [Work] = []
        // 阶段 1：认领 + 分类（写队列内）
        try queue.sync {
            let jobs: [(String, String, String)]
            if let sourceId {
                jobs = try database.query("""
                    SELECT job_id, source_id, asset_id FROM index_jobs
                    WHERE state = 'pending' AND job_type = 'embed_image' AND source_id = ? ORDER BY rowid LIMIT ?
                    """, [.text(sourceId), .int(Int64(limit))]) { ($0.columnText(0), $0.columnText(1), $0.columnText(2)) }
            } else {
                jobs = try database.query("""
                    SELECT job_id, source_id, asset_id FROM index_jobs
                    WHERE state = 'pending' AND job_type = 'embed_image' ORDER BY rowid LIMIT ?
                    """, [.int(Int64(limit))]) { ($0.columnText(0), $0.columnText(1), $0.columnText(2)) }
            }
            for (jobId, jobSource, assetId) in jobs {
                try database.run("UPDATE index_jobs SET state = 'running' WHERE job_id = ? AND state = 'pending'", [.text(jobId)])
                guard database.changes == 1 else { continue }
                guard let mount = try database.query("SELECT mount_path FROM storage_sources WHERE source_id = ?", [.text(jobSource)]) { $0.columnText(0) }.first,
                      !mount.isEmpty, FileManager.default.fileExists(atPath: mount) else {
                    try finish(jobId, "pending"); summary.deferredOffline += 1; continue
                }
                guard let asset = try database.query("SELECT relative_path, size, mtime_ns, deleted_confirmed_at FROM assets WHERE asset_id = ?",
                                                     [.text(assetId)], map: { ($0.columnText(0), $0.columnInt(1), $0.columnIsNull(2) ? Int64(0) : $0.columnInt(2), !$0.columnIsNull(3)) }).first,
                      !asset.3 else {
                    try finish(jobId, "done"); continue
                }
                let path = mount + "/" + asset.0
                guard FileManager.default.fileExists(atPath: path) else { try finish(jobId, "failed"); summary.failed += 1; continue }
                let token = "\(asset.1):\(asset.2)"
                let existing = try database.query("""
                    SELECT e.content_change_token FROM media_segments s JOIN embeddings e ON e.segment_id = s.segment_id
                    WHERE s.asset_id = ? AND s.kind = 'image' AND e.profile_id = ? LIMIT 1
                    """, [.text(assetId), .text(profile.id)]) { $0.columnText(0) }.first
                if existing == token { try finish(jobId, "done"); summary.skippedUnchanged += 1; continue }
                summary.processed += 1
                work.append(Work(jobId: jobId, assetId: assetId, sourceId: jobSource, url: URL(fileURLWithPath: path), token: token))
            }
        }
        guard !work.isEmpty else { return summary }

        // 阶段 2（流式）：读盘车道边产出缩略图边攒批，攒满即发——读写重叠，服务端不空转
        // （2026-10-21 首版分相实现的教训：先全读后全发，NAS/USB 读 30-60s 期间服务器闲置，
        //  批量提速被占空比吃掉一半）。
        // **每任务读盘看门狗**（外置 USB 盘 I/O 挂死实锤 2026-10-21：CGImageSourceCreateWithURL 卡在不可中断
        // D 态，把协作线程与车道信号量一起拖死——读盘必须在带超时的看门狗线程里，超时弃线程保泵，与 OCR 同一纪律）。
        let batchSize = max(1, provider.capabilities.batchImages)
        let semaphore = DispatchSemaphore(value: max(1, lanes))
        let group = DispatchGroup()
        let embedGroup = DispatchGroup()
        let outcomes = OutcomeBox()
        let staging = BatchStaging()
        let perItemTimeout: TimeInterval = 120   // 读盘+下采样的单项上限

        // 一批缩略图 → 一个批量请求（看门狗预算随图数放大）。
        // 批量失败放大问题（2026-10-21 NAS 源实弹：整批 25 张被个别毒图拖成 transient=25、embedded=0）：
        // 非超时失败且批 >1 → 二分重试，把坏图隔离成单张失败，好图不陪葬；超时不二分（服务器
        // 挂起时二分只会翻倍等待者，正确答案是整批留队 + 泵退避）。
        let failureNote = FailureNote()
        func dispatchEmbed(_ batch: [(work: Work, thumb: Data)]) {
            embedGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { embedGroup.leave() }
                let done = DispatchSemaphore(value: 0)
                let resultBox = BatchResultBox()
                Task.detached(priority: .utility) {
                    do { resultBox.value = .success(try await provider.embedImagesData(batch.map { ($0.thumb, "image/jpeg") })) }
                    catch { resultBox.value = .failure(ProviderError.classify(error)) }
                    done.signal()
                }
                // 批量预算：单项上限 + 每图 4s（32 图 ≈ 248s 上限；正常 ~10s）
                let budget = perItemTimeout + Double(batch.count) * 4
                guard done.wait(timeout: .now() + budget) == .success, let result = resultBox.value else {
                    for entry in batch { outcomes.append(entry.work, .failure(.timeout)) }
                    failureNote.record("timeout batch=\(batch.count)")
                    return
                }
                switch result {
                case .success(let vectors):
                    for (entry, vector) in zip(batch, vectors) { outcomes.append(entry.work, .success(vector)) }
                case .failure(let error):
                    if batch.count > 1, error != .timeout, error != .cancelled {
                        let mid = batch.count / 2
                        dispatchEmbed(Array(batch.prefix(mid)))
                        dispatchEmbed(Array(batch.dropFirst(mid)))
                    } else {
                        for entry in batch { outcomes.append(entry.work, .failure(error)) }
                        failureNote.record("\(error) batch=\(batch.count)")
                    }
                }
            }
        }

        for item in work {
            semaphore.wait(); group.enter()
            let maxSide = maxLongSide, quality = jpegQuality
            DispatchQueue.global(qos: .utility).async {
                defer { semaphore.signal(); group.leave() }
                let watch = DispatchSemaphore(value: 0)
                let thumbBox = ThumbBox()
                DispatchQueue(label: "astfind.embed.watch", qos: .utility).async {
                    thumbBox.value = Self.downsampledJPEG(at: item.url, maxLongSide: maxSide, quality: quality)
                    watch.signal()
                }
                guard watch.wait(timeout: .now() + perItemTimeout) == .success else {
                    outcomes.append(item, .failure(.timeout)); return   // 读盘卡死：弃线程，记超时（环境类，留队）
                }
                guard let thumb = thumbBox.value else {
                    outcomes.append(item, .failure(.unsupported("undecodable image"))); return
                }
                if batchSize > 1 {
                    staging.append((item, thumb))
                    if let full = staging.takeFullBatch(size: batchSize) { dispatchEmbed(full) }
                } else {
                    dispatchEmbed([(work: item, thumb: thumb)])   // 串行：逐图即发（行为同旧版）
                }
            }
        }
        group.wait()
        // 读盘全部结束：冲刷不满批的尾批
        for remainder in staging.drainBatches(size: batchSize) { dispatchEmbed(remainder) }
        embedGroup.wait()
        summary.lastFailure = failureNote.value

        // 阶段 3：统一回写（单写者）
        try queue.sync {
            // 服务端健康证据：本轮有过成功入库，或近期（healthyWindow 内）有过成功。
            // 先汇总本轮结果再判定——并发批次完成顺序不定，失败可能先于成功被处理。
            // 毒图隔离记笔只在这个证据下进行——纯宕机期间不记笔，恢复后整队照常，
            // 绝不因长时间故障误杀；毒图则在服务端明显健康时持续记笔直至隔离。
            let drained = outcomes.drain()
            let roundHasSuccess = drained.contains { if case .success = $1 { return true } else { return false } }
            let serverProvenHealthy = roundHasSuccess
                || lastSuccessAt.map { Date().timeIntervalSince($0) < Self.healthyWindow } ?? false
            for (item, result) in drained {
                switch result {
                case .success(let vector):
                    guard vector.count == profile.dimension else {
                        try finish(item.jobId, "failed"); summary.failed += 1; continue
                    }
                    try storeVector(vector, assetId: item.assetId, profile: profile, token: item.token)
                    try finish(item.jobId, "done"); summary.embedded += 1
                    lastSuccessAt = Date()
                case .failure(let error):
                    if error.isTransient {
                        let attempts = (try database.query("SELECT attempts FROM index_jobs WHERE job_id = ?",
                                                           [.text(item.jobId)]) { Int($0.columnInt(0)) }.first) ?? 0
                        if serverProvenHealthy, attempts + 1 >= Self.quarantineStrikes {
                            try finish(item.jobId, "failed"); summary.failed += 1; summary.quarantined += 1
                        } else {
                            // 留队重试；有健康证据才记笔（无证据时保持原笔数，宕机不累加）
                            let next = serverProvenHealthy ? attempts + 1 : attempts
                            try database.run("UPDATE index_jobs SET state = 'pending', attempts = ? WHERE job_id = ?",
                                             [.int(Int64(next)), .text(item.jobId)])
                            summary.transientFailures += 1
                        }
                    } else {
                        try finish(item.jobId, "failed"); summary.failed += 1
                    }
                }
            }
        }
        return summary
    }

    private func finish(_ jobId: String, _ state: String) throws {
        try database.run("UPDATE index_jobs SET state = ? WHERE job_id = ?", [.text(state), .text(jobId)])
    }

    final class ThumbBox: @unchecked Sendable { var value: Data? }
    final class BatchResultBox: @unchecked Sendable { var value: Result<[[Float]], ProviderError>? }
    final class FailureNote: @unchecked Sendable {
        private let lock = NSLock()
        private var note: String?
        func record(_ text: String) { lock.lock(); if note == nil { note = text }; lock.unlock() }
        var value: String? { lock.lock(); defer { lock.unlock() }; return note }
    }
    /// 流式攒批缓冲：读盘车道并发产出缩略图，攒满一批原子取走发请求（末批由收尾冲刷）。
    private final class BatchStaging: @unchecked Sendable {
        private let lock = NSLock()
        private var staged: [(work: Work, thumb: Data)] = []
        func append(_ entry: (work: Work, thumb: Data)) { lock.lock(); staged.append(entry); lock.unlock() }
        /// 攒满 size 才取（不满不取——避免小批提前发浪费请求）；并发取批安全。
        func takeFullBatch(size: Int) -> [(work: Work, thumb: Data)]? {
            lock.lock(); defer { lock.unlock() }
            guard staged.count >= size else { return nil }
            let batch = Array(staged.prefix(size))
            staged.removeFirst(size)
            return batch
        }
        /// 收尾冲刷：剩余项按 size 切批（末批允许不满）。
        func drainBatches(size: Int) -> [[(work: Work, thumb: Data)]] {
            lock.lock(); defer { lock.unlock() }
            var batches: [[(work: Work, thumb: Data)]] = []
            while staged.count > size { batches.append(Array(staged.prefix(size))); staged.removeFirst(size) }
            if !staged.isEmpty { batches.append(staged); staged = [] }
            return batches
        }
    }

    /// 并发阶段的结果收集（锁操作收敛在同步方法内，async 任务只调用）。
    private final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(Work, Result<[Float], ProviderError>)] = []
        func append(_ work: Work, _ result: Result<[Float], ProviderError>) {
            lock.lock(); items.append((work, result)); lock.unlock()
        }
        func drain() -> [(Work, Result<[Float], ProviderError>)] {
            lock.lock(); defer { lock.unlock() }; return items
        }
    }

    private func storeVector(_ vector: [Float], assetId: String, profile: Profile, token: String) throws {
        let blob = Self.quantize(vector)
        try database.transaction {
            try database.run("""
                INSERT OR IGNORE INTO media_segments (segment_id, asset_id, kind, start_ms, end_ms) VALUES (?,?,'image',0,0)
                """, [.text(UUID().uuidString), .text(assetId)])
            let segmentId = try database.query(
                "SELECT segment_id FROM media_segments WHERE asset_id = ? AND kind = 'image' AND start_ms = 0 AND end_ms = 0",
                [.text(assetId)]) { $0.columnText(0) }.first ?? ""
            try database.run("DELETE FROM embeddings WHERE segment_id = ? AND profile_id = ?", [.text(segmentId), .text(profile.id)])
            try database.run("""
                INSERT INTO embeddings (embedding_id, segment_id, profile_id, vector_blob, content_change_token, indexed_at)
                VALUES (?,?,?,?,?,?)
                """, [.text(UUID().uuidString), .text(segmentId), .text(profile.id), .blob(blob), .text(token),
                      .int(Int64(Date().timeIntervalSince1970))])
        }
    }

    // MARK: - 视频画面语义（A2 纵切之二，2026-10-21）
    // 帧采样（AVFoundation 同帧 OCR 纪律）→ 批量向量化（批量 32 实测甜点）→
    // media_segments kind='video' + start_ms 逐帧落库；检索带时间码（PRD：结果含时间码）。

    /// AVFoundation 原生可解码容器（与帧 OCR 一致；mkv/avi 不排——解码失败徒增 failed）
    public static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    /// 语义采样间隔（秒）与每视频帧上限——更长视频自动放稀间隔。
    /// 依据：WeMM 批量产能 ≈3 帧/s + "搜画面"粒度；A0 基准后可调。
    public var videoSampleInterval: TimeInterval = 10
    public var videoMaxFrames = 60
    /// 单视频采样+向量化的看门狗（解码挂死保护，同读盘纪律）
    private static let videoWatchdogSeconds: TimeInterval = 300

    public func enqueuePendingVideos(sourceId: String, profile: Profile) throws -> Int {
        try queue.sync {
            let likeClauses = Self.videoExtensions
                .map { "a.relative_path LIKE '%.\($0)'" }.joined(separator: " OR ")
            let candidates = try database.query("""
                SELECT a.asset_id, a.relative_path FROM assets a
                LEFT JOIN index_jobs j ON j.asset_id = a.asset_id AND j.job_type = 'embed_video'
                                      AND j.state IN ('pending', 'running', 'failed')
                LEFT JOIN media_segments s ON s.asset_id = a.asset_id AND s.kind = 'video'
                LEFT JOIN embeddings e ON e.segment_id = s.segment_id AND e.profile_id = ?
                                      AND e.content_change_token = (a.size || ':' || COALESCE(a.mtime_ns, 0))
                WHERE a.source_id = ? AND a.deleted_confirmed_at IS NULL
                  AND j.job_id IS NULL AND e.embedding_id IS NULL
                  AND (\(likeClauses))
                """, [.text(profile.id), .text(sourceId)]) { ($0.columnText(0), $0.columnText(1)) }
            var inserted = 0
            try database.transaction {
                for (assetId, relativePath) in candidates {
                    let name = (relativePath as NSString).lastPathComponent
                    if name.hasPrefix("._") || name == ".DS_Store" { continue }
                    try database.run("""
                        INSERT INTO index_jobs (job_id, source_id, asset_id, job_type, state, priority)
                        VALUES (?,?,?,'embed_video','pending',0)
                        """, [.text(UUID().uuidString), .text(sourceId), .text(assetId)])
                    inserted += 1
                }
            }
            return inserted
        }
    }

    public func videoPendingSourceIds() throws -> [String] {
        try queue.sync {
            try database.query("SELECT DISTINCT source_id FROM index_jobs WHERE job_type = 'embed_video' AND state = 'pending' ORDER BY rowid") { $0.columnText(0) }
        }
    }

    /// 视频任务计数（状态面板/CLI status 用）
    public func videoCounts() throws -> Counts {
        var counts = Counts()
        let rows: [(String, Int)] = try queue.sync {
            try database.query("SELECT state, COUNT(*) FROM index_jobs WHERE job_type = 'embed_video' GROUP BY state") { ($0.columnText(0), Int($0.columnInt(1))) }
        }
        for (state, n) in rows {
            switch state {
            case "pending": counts.pending = n
            case "running": counts.running = n
            case "done": counts.done = n
            case "failed": counts.failed = n
            default: break
            }
        }
        return counts
    }

    /// 视频语义执行：认领 → 采样（看门狗）→ 帧批向量化（二分隔离毒帧）→ 整视频落库。
    /// 帧级部分成功即入库（毒帧跳过，好帧可搜）；零帧成功才按任务级失败处理（同图片的隔离纪律）。
    public func runPendingVideo(limit: Int = 3, sourceId: String? = nil, lanes: Int = 1,
                                provider: EmbeddingProvider, profile: Profile) throws -> Summary {
        var summary = Summary()
        var work: [Work] = []
        try queue.sync {
            let jobs: [(String, String, String)]
            if let sourceId {
                jobs = try database.query("""
                    SELECT job_id, source_id, asset_id FROM index_jobs
                    WHERE state = 'pending' AND job_type = 'embed_video' AND source_id = ? ORDER BY rowid LIMIT ?
                    """, [.text(sourceId), .int(Int64(limit))]) { ($0.columnText(0), $0.columnText(1), $0.columnText(2)) }
            } else {
                jobs = try database.query("""
                    SELECT job_id, source_id, asset_id FROM index_jobs
                    WHERE state = 'pending' AND job_type = 'embed_video' ORDER BY rowid LIMIT ?
                    """, [.int(Int64(limit))]) { ($0.columnText(0), $0.columnText(1), $0.columnText(2)) }
            }
            for (jobId, jobSource, assetId) in jobs {
                try database.run("UPDATE index_jobs SET state = 'running' WHERE job_id = ? AND state = 'pending'", [.text(jobId)])
                guard database.changes == 1 else { continue }
                guard let mount = try database.query("SELECT mount_path FROM storage_sources WHERE source_id = ?", [.text(jobSource)]) { $0.columnText(0) }.first,
                      !mount.isEmpty, FileManager.default.fileExists(atPath: mount) else {
                    try finish(jobId, "pending"); summary.deferredOffline += 1; continue
                }
                guard let asset = try database.query("SELECT relative_path, size, mtime_ns, deleted_confirmed_at FROM assets WHERE asset_id = ?",
                                                     [.text(assetId)], map: { ($0.columnText(0), $0.columnInt(1), $0.columnIsNull(2) ? Int64(0) : $0.columnInt(2), !$0.columnIsNull(3)) }).first,
                      !asset.3 else {
                    try finish(jobId, "done"); continue
                }
                let path = mount + "/" + asset.0
                guard FileManager.default.fileExists(atPath: path) else { try finish(jobId, "failed"); summary.failed += 1; continue }
                let token = "\(asset.1):\(asset.2)"
                let existing = try database.query("""
                    SELECT e.content_change_token FROM media_segments s JOIN embeddings e ON e.segment_id = s.segment_id
                    WHERE s.asset_id = ? AND s.kind = 'video' AND e.profile_id = ? LIMIT 1
                    """, [.text(assetId), .text(profile.id)]) { $0.columnText(0) }.first
                if existing == token { try finish(jobId, "done"); summary.skippedUnchanged += 1; continue }
                summary.processed += 1
                work.append(Work(jobId: jobId, assetId: assetId, sourceId: jobSource, url: URL(fileURLWithPath: path), token: token))
            }
        }
        guard !work.isEmpty else { return summary }

        // 阶段 2：逐视频（车道并发）采样 + 帧批向量化
        let semaphore = DispatchSemaphore(value: max(1, lanes))
        let group = DispatchGroup()
        let outcomes = VideoOutcomeBox()
        let batchSize = max(1, provider.capabilities.batchImages)
        let interval = videoSampleInterval, maxFrames = videoMaxFrames, maxSide = maxLongSide, quality = jpegQuality
        for item in work {
            semaphore.wait(); group.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { semaphore.signal(); group.leave() }
                // 采样看门狗：视频解码可能挂死（NAS/损坏容器），超时弃线程保泵
                let sampled = DispatchSemaphore(value: 0)
                let framesBox = FramesBox()
                DispatchQueue(label: "astfind.embed.video", qos: .utility).async {
                    framesBox.frames = Self.sampledFrames(at: item.url, interval: interval, maxFrames: maxFrames,
                                                          maxLongSide: maxSide, quality: quality)
                    sampled.signal()
                }
                guard sampled.wait(timeout: .now() + Self.videoWatchdogSeconds) == .success else {
                    outcomes.append(item, .failure(.timeout)); return
                }
                guard let frames = framesBox.frames, !frames.isEmpty else {
                    outcomes.append(item, .failure(.unsupported("no decodable frames"))); return
                }
                // 帧批向量化：分块请求；块失败二分隔离毒帧，好帧不陪葬
                var vectors: [(startMs: Int, vector: [Float])] = []
                var chunkStart = 0
                var chunkError: ProviderError?
                while chunkStart < frames.count {
                    let chunk = Array(frames[chunkStart..<min(chunkStart + batchSize, frames.count)])
                    switch Self.embedChunkSync(chunk, provider: provider, perFrameTimeout: 60) {
                    case .success(let embedded):
                        vectors.append(contentsOf: embedded)
                    case .failure(let error):
                        if chunkError == nil { chunkError = error }
                    }
                    chunkStart += batchSize
                }
                if vectors.isEmpty {
                    outcomes.append(item, .failure(chunkError ?? .invalidResponse("no frames embedded")))
                } else {
                    outcomes.append(item, .success(vectors))
                }
            }
        }
        group.wait()

        // 阶段 3：回写（单写者；毒图隔离纪律与图片一致）
        try queue.sync {
            let drained = outcomes.drain()
            let roundHasSuccess = drained.contains { if case .success = $0.1 { return true } else { return false } }
            let serverProvenHealthy = roundHasSuccess
                || lastSuccessAt.map { Date().timeIntervalSince($0) < Self.healthyWindow } ?? false
            for (item, result) in drained {
                switch result {
                case .success(let vectors):
                    try storeVideoVectors(vectors, assetId: item.assetId, profile: profile, token: item.token)
                    try finish(item.jobId, "done"); summary.embedded += 1
                    lastSuccessAt = Date()
                case .failure(let error):
                    if error.isTransient {
                        let attempts = (try database.query("SELECT attempts FROM index_jobs WHERE job_id = ?",
                                                           [.text(item.jobId)]) { Int($0.columnInt(0)) }.first) ?? 0
                        if serverProvenHealthy, attempts + 1 >= Self.quarantineStrikes {
                            try finish(item.jobId, "failed"); summary.failed += 1; summary.quarantined += 1
                        } else {
                            let next = serverProvenHealthy ? attempts + 1 : attempts
                            try database.run("UPDATE index_jobs SET state = 'pending', attempts = ? WHERE job_id = ?",
                                             [.int(Int64(next)), .text(item.jobId)])
                            summary.transientFailures += 1
                        }
                    } else {
                        try finish(item.jobId, "failed"); summary.failed += 1
                    }
                }
            }
        }
        return summary
    }

    final class FramesBox: @unchecked Sendable { var frames: [(startMs: Int, jpeg: Data)]? }
    private final class VideoOutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(Work, Result<[(startMs: Int, vector: [Float])], ProviderError>)] = []
        func append(_ work: Work, _ result: Result<[(startMs: Int, vector: [Float])], ProviderError>) {
            lock.lock(); items.append((work, result)); lock.unlock()
        }
        func drain() -> [(Work, Result<[(startMs: Int, vector: [Float])], ProviderError>)] {
            lock.lock(); defer { lock.unlock() }; return items
        }
    }

    /// 帧块同步向量化：一请求一批；失败且批 >1 → 二分重试隔离毒帧（同图片纪律；超时不二分）。
    private static func embedChunkSync(_ chunk: [(startMs: Int, jpeg: Data)],
                                       provider: EmbeddingProvider, perFrameTimeout: TimeInterval) -> Result<[(startMs: Int, vector: [Float])], ProviderError> {
        let done = DispatchSemaphore(value: 0)
        let box = BatchResultBox()
        Task.detached(priority: .utility) {
            do { box.value = .success(try await provider.embedImagesData(chunk.map { ($0.jpeg, "image/jpeg") })) }
            catch { box.value = .failure(ProviderError.classify(error)) }
            done.signal()
        }
        guard done.wait(timeout: .now() + perFrameTimeout + Double(chunk.count) * 2) == .success,
              let result = box.value else { return .failure(.timeout) }
        switch result {
        case .success(let vectors):
            guard vectors.count == chunk.count else { return .failure(.server(500)) }
            return .success(zip(chunk, vectors).map { ($0.0.startMs, $0.1) })
        case .failure(let error):
            if chunk.count > 1, error != .timeout, error != .cancelled {
                let mid = chunk.count / 2
                var collected: [(Int, [Float])] = []
                var finalError: ProviderError?
                for half in [Array(chunk.prefix(mid)), Array(chunk.dropFirst(mid))] {
                    switch embedChunkSync(half, provider: provider, perFrameTimeout: perFrameTimeout) {
                    case .success(let vectors): collected.append(contentsOf: vectors)
                    case .failure(let halfError): if finalError == nil { finalError = halfError }
                    }
                }
                if collected.isEmpty { return .failure(finalError ?? error) }
                return .success(collected)
            }
            return .failure(error)
        }
    }

    private func storeVideoVectors(_ vectors: [(startMs: Int, vector: [Float])], assetId: String,
                                   profile: Profile, token: String) throws {
        let intervalMs = Int(videoSampleInterval * 1000)
        try database.transaction {
            // 同 profile 重嵌：旧帧段与向量整体替换（帧数/时间码随采样参数变化）
            try database.run("""
                DELETE FROM embeddings WHERE profile_id = ? AND segment_id IN
                (SELECT segment_id FROM media_segments WHERE asset_id = ? AND kind = 'video')
                """, [.text(profile.id), .text(assetId)])
            try database.run("DELETE FROM media_segments WHERE asset_id = ? AND kind = 'video'", [.text(assetId)])
            for frame in vectors {
                let segmentId = UUID().uuidString
                try database.run("""
                    INSERT INTO media_segments (segment_id, asset_id, kind, start_ms, end_ms) VALUES (?,?,'video',?,?)
                    """, [.text(segmentId), .text(assetId), .int(Int64(frame.startMs)), .int(Int64(frame.startMs + intervalMs))])
                try database.run("""
                    INSERT INTO embeddings (embedding_id, segment_id, profile_id, vector_blob, content_change_token, indexed_at)
                    VALUES (?,?,?,?,?,?)
                    """, [.text(UUID().uuidString), .text(segmentId), .text(profile.id),
                          .blob(Self.quantize(frame.vector)), .text(token), .int(Int64(Date().timeIntervalSince1970))])
            }
        }
    }

    /// 视频抽帧（AVAssetImageGenerator，精确采样时刻——时间码可信；同帧 OCR 纪律）。
    /// 返回 nil = 容器不可解码/无视频轨。
    static func sampledFrames(at url: URL, interval: TimeInterval, maxFrames: Int,
                              maxLongSide: CGFloat, quality: CGFloat) -> [(startMs: Int, jpeg: Data)]? {
        let asset = AVURLAsset(url: url)
        let duration = CMTimeGetSeconds(asset.duration)
        guard duration.isFinite, duration > 0 else { return nil }
        let step = max(interval, duration / Double(maxFrames))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: maxLongSide, height: maxLongSide)
        var frames: [(startMs: Int, jpeg: Data)] = []
        var time: TimeInterval = 0
        var count = 0
        while time < duration, count < maxFrames {
            count += 1
            if let image = try? generator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil),
               let jpeg = Self.jpegData(from: image, quality: quality) {
                frames.append((Int(time * 1000), jpeg))
            }
            time += step
        }
        return frames
    }

    static func jpegData(from image: CGImage, quality: CGFloat) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    // MARK: - 检索（只读连接；归一化点积=余弦）

    public func search(queryVector: [Float], profile: Profile, limit: Int = 20) throws -> [SemanticHit] {
        let query = Self.normalized(queryVector)
        let rows: [(String, String, String, Data, String, Int64?)]
        let sql = """
            SELECT a.asset_id, a.source_id, a.relative_path, e.vector_blob, s.kind, s.start_ms
            FROM embeddings e JOIN media_segments s ON s.segment_id = e.segment_id
            JOIN assets a ON a.asset_id = s.asset_id AND a.deleted_confirmed_at IS NULL
            WHERE e.profile_id = ?
            """
        let map: (Statement) -> (String, String, String, Data, String, Int64?) = {
            ($0.columnText(0), $0.columnText(1), $0.columnText(2), $0.columnBlob(3), $0.columnText(4),
             $0.columnIsNull(5) ? nil : $0.columnInt(5))
        }
        if let reader { rows = try readerQueue.sync { try reader.query(sql, [.text(profile.id)], map: map) } }
        else { rows = try queue.sync { try database.query(sql, [.text(profile.id)], map: map) } }
        var scored: [SemanticHit] = []
        scored.reserveCapacity(rows.count)
        var buffer = [Float](repeating: 0, count: query.count)
        for (assetId, sourceId, path, blob, kind, startMs) in rows {
            guard let score = Self.dot(quantized: blob, query: query, scratch: &buffer) else { continue }
            scored.append(SemanticHit(assetId: assetId, sourceId: sourceId, relativePath: path, score: score,
                                      startMs: startMs.map(Int.init), kind: kind))
        }
        scored.sort { $0.score > $1.score }
        return Array(scored.prefix(limit))
    }

    // MARK: - 量化 / 向量工具

    /// 归一化后 int8 量化：[Float32 scale][Int8 × N]。
    static func quantize(_ vector: [Float]) -> Data {
        let unit = normalized(vector)
        let scale = unit.map { abs($0) }.max() ?? 1
        var data = Data(capacity: 4 + unit.count)
        var s = Float32(scale == 0 ? 1 : scale)
        data.append(Data(bytes: &s, count: 4))
        let q = unit.map { Int8(clamping: Int(($0 / Float(s) * 127).rounded())) }
        q.withUnsafeBufferPointer { data.append(UnsafeBufferPointer(start: UnsafeRawPointer($0.baseAddress!).assumingMemoryBound(to: UInt8.self), count: q.count)) }
        return data
    }

    static func dequantize(_ blob: Data) -> [Float]? {
        guard blob.count > 4 else { return nil }
        let scale: Float32 = blob.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) }
        let n = blob.count - 4
        var out = [Float](repeating: 0, count: n)
        blob.withUnsafeBytes { raw in
            let src = raw.baseAddress!.advanced(by: 4).assumingMemoryBound(to: Int8.self)
            vDSP_vflt8(src, 1, &out, 1, vDSP_Length(n))
        }
        var k = scale / 127
        vDSP_vsmul(out, 1, &k, &out, 1, vDSP_Length(n))
        return out
    }

    /// blob 与查询向量的点积（dequantize 进 scratch 复用缓冲）；维度不符返回 nil。
    static func dot(quantized blob: Data, query: [Float], scratch: inout [Float]) -> Float? {
        let n = blob.count - 4
        guard n == query.count, n > 0 else { return nil }
        let scale: Float32 = blob.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) }
        blob.withUnsafeBytes { raw in
            let src = raw.baseAddress!.advanced(by: 4).assumingMemoryBound(to: Int8.self)
            vDSP_vflt8(src, 1, &scratch, 1, vDSP_Length(n))
        }
        var result: Float = 0
        vDSP_dotpr(scratch, 1, query, 1, &result, vDSP_Length(n))
        return result * scale / 127
    }

    static func normalized(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
        norm = sqrt(norm)
        guard norm > 0 else { return v }
        var inv = 1 / norm
        var out = [Float](repeating: 0, count: v.count)
        vDSP_vsmul(v, 1, &inv, &out, 1, vDSP_Length(v.count))
        return out
    }

    /// 本地下采样成 JPEG（长边 ≤ maxLongSide）；不可解码返回 nil。
    static func downsampledJPEG(at url: URL, maxLongSide: CGFloat, quality: CGFloat) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxLongSide),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
