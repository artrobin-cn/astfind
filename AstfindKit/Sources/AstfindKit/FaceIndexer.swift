import AstfindFaceCore
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

/// M0.8b 本机人脸索引。
///
/// 职责边界：
/// - 图片 + 视频关键帧（2s 起，长视频自适应，最多 60 帧）；人脸向量独立表；
/// - 任务复用 `index_jobs(job_type='face_embed')`，遵守 M0.6 交互让路；
/// - 每个来源独立 `face_index_enabled`，默认关闭；与内容 OCR 开关解耦；
/// - 模型由用户按许可放置，App 不随包分发。
public final class FaceIndexer {
    public struct Summary: Equatable, Sendable {
        public var processed = 0
        public var embedded = 0
        public var noFace = 0
        public var failed = 0
        public var deferredOffline = 0
        public var paused = false
        public var modelUnavailable = false
        public init() {}
    }

    public struct Counts: Equatable, Sendable {
        public var pending = 0, running = 0, done = 0, failed = 0
        public init() {}
    }

    public struct Hit: Equatable, Sendable {
        public let assetId: String
        public let sourceId: String
        public let relativePath: String
        public let startMs: Int?
        public let score: Double
        public let bboxJSON: String
        public let quality: Double?
    }

    private struct Work {
        let jobId: String
        let sourceId: String
        let assetId: String
        let relativePath: String
        let size: Int64
        let mtimeNs: Int64?
        let deleted: Bool
        let mount: String
        let token: String
    }

    private struct FaceRow {
        let startMs: Int?
        let bboxJSON: String
        let quality: Double?
        let vector: [Float]
    }

    private enum ProcessingError: Error {
        case paused
        case videoUnreadable
        case noFrameExtracted
    }

    private final class ImageBox: @unchecked Sendable {
        var image: CGImage?
    }

    public let profile: FaceProfile
    public var embedder: FaceEmbeddingProviding?
    /// 视频最小采样间隔；长视频会自适应放大以不超过 `videoMaxFrames`。
    public var videoSampleIntervalMs = 2_000
    public var videoMaxFrames = 60
    public var videoFrameTimeout: TimeInterval = 20

    private let preprocessor: FacePreprocessing
    private let database: Database
    private let queue = DispatchQueue(label: "astfind.face")

    private static let imageExtensions: [String] = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "bmp"
    ]
    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    public init(databaseURL: URL,
                profile: FaceProfile = .buffaloSC,
                embedder: FaceEmbeddingProviding? = nil,
                preprocessor: FacePreprocessing = VisionFacePreprocessor()) throws {
        self.database = try Database(url: databaseURL)
        try Migrations.apply(to: database)
        self.profile = profile
        self.embedder = embedder
        self.preprocessor = preprocessor
    }

    // MARK: - 入队

    /// 为启用 face_index_enabled 的来源补齐未处理图片/视频；已 done 且 token 未变的不重复入队。
    @discardableResult
    public func enqueuePending(sourceId: String? = nil) throws -> Int {
        try queue.sync {
            let exts = Self.imageExtensions + Array(Self.videoExtensions)
            let like = exts.map { "a.relative_path LIKE '%.\($0)'" }.joined(separator: " OR ")
            let sourceClause = sourceId == nil ? "" : "AND a.source_id = ?"
            var binds: [SQLiteValue] = []
            if let sourceId { binds.append(.text(sourceId)) }
            let rows = try database.query("""
                SELECT a.asset_id, a.source_id FROM assets a
                JOIN storage_sources s ON s.source_id = a.source_id
                WHERE s.face_index_enabled = 1 AND a.deleted_confirmed_at IS NULL
                  AND (s.face_index_prefix IS NULL OR s.face_index_prefix = ''
                       OR substr(a.relative_path, 1, length(s.face_index_prefix)) = s.face_index_prefix)
                  \(sourceClause)
                  AND (\(like))
                  AND NOT EXISTS (
                    SELECT 1 FROM index_jobs j
                    WHERE j.asset_id = a.asset_id AND j.job_type = 'face_embed'
                      AND (j.state IN ('pending', 'running', 'failed')
                           OR (j.state = 'done'
                               AND j.checkpoint_json = (a.size || ':' || COALESCE(a.mtime_ns, 0))))
                  )
                """, binds) { ($0.columnText(0), $0.columnText(1)) }
            guard !rows.isEmpty else { return 0 }
            var inserted = 0
            try database.transaction {
                for (assetId, sourceId) in rows {
                    try database.run("""
                        INSERT INTO index_jobs (job_id, source_id, asset_id, job_type, state, priority)
                        VALUES (?,?,?,'face_embed','pending',0)
                        """, [.text(UUID().uuidString), .text(sourceId), .text(assetId)])
                    inserted += 1
                }
            }
            return inserted
        }
    }

    public func pendingSourceIds() throws -> [String] {
        try queue.sync {
            try database.query("""
                SELECT DISTINCT j.source_id FROM index_jobs j
                JOIN storage_sources s ON s.source_id = j.source_id
                WHERE j.job_type = 'face_embed' AND j.state = 'pending'
                  AND s.face_index_enabled = 1
                """, []) { $0.columnText(0) }
        }
    }

    public func counts() throws -> Counts {
        try queue.sync {
            let rows = try database.query(
                "SELECT state, COUNT(*) FROM index_jobs WHERE job_type = 'face_embed' GROUP BY state",
                []) { ($0.columnText(0), Int($0.columnInt(1))) }
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
    }

    public func embeddingCount() throws -> Int {
        try queue.sync {
            try database.query(
                "SELECT COUNT(*) FROM face_embeddings WHERE profile_id = ?",
                [.text(profile.id)]) { Int($0.columnInt(0)) }.first ?? 0
        }
    }

    // MARK: - 执行

    @discardableResult
    public func runPending(limit: Int = 25, sourceId: String? = nil,
                           shouldPause: @escaping () -> Bool = { false }) throws -> Summary {
        var summary = Summary()
        guard let embedder else {
            summary.modelUnavailable = true
            return summary
        }
        let jobs = try queue.sync { try claim(limit: max(1, limit), sourceId: sourceId) }
        for job in jobs {
            if shouldPause() {
                summary.paused = true
                break
            }
            try process(job, embedder: embedder, shouldPause: shouldPause, summary: &summary)
        }
        return summary
    }

    private func claim(limit: Int, sourceId: String?) throws -> [Work] {
        let sourceClause = sourceId == nil ? "" : "AND j.source_id = ?"
        var binds: [SQLiteValue] = []
        if let sourceId { binds.append(.text(sourceId)) }
        binds.append(.int(Int64(limit)))
        return try database.query("""
            SELECT j.job_id, j.source_id, j.asset_id, a.relative_path, a.size, a.mtime_ns,
                   a.deleted_confirmed_at, s.mount_path
            FROM index_jobs j
            JOIN assets a ON a.asset_id = j.asset_id
            JOIN storage_sources s ON s.source_id = j.source_id
            WHERE j.job_type = 'face_embed' AND j.state = 'pending'
              AND s.face_index_enabled = 1 \(sourceClause)
            ORDER BY j.rowid LIMIT ?
            """, binds) { statement -> Work in
                let size = statement.columnInt(4)
                let mtime = statement.columnIsNull(5) ? nil : statement.columnInt(5)
                return Work(
                    jobId: statement.columnText(0),
                    sourceId: statement.columnText(1),
                    assetId: statement.columnText(2),
                    relativePath: statement.columnText(3),
                    size: size,
                    mtimeNs: mtime,
                    deleted: !statement.columnIsNull(6),
                    mount: statement.columnText(7),
                    token: "\(size):\(mtime ?? 0)")
            }
    }

    private func process(_ work: Work, embedder: FaceEmbeddingProviding,
                         shouldPause: () -> Bool, summary: inout Summary) throws {
        let claimed = try queue.sync {
            try database.run("UPDATE index_jobs SET state = 'running' WHERE job_id = ? AND state = 'pending'",
                             [.text(work.jobId)])
            return database.changes == 1
        }
        guard claimed else { return }
        guard !work.deleted else {
            try finish(work.jobId, state: "done", checkpoint: work.token)
            return
        }
        guard !work.mount.isEmpty, FileManager.default.fileExists(atPath: work.mount) else {
            try finish(work.jobId, state: "pending")
            summary.deferredOffline += 1
            return
        }
        let url = URL(fileURLWithPath: work.mount).appendingPathComponent(work.relativePath)
        let rows: [FaceRow]
        do {
            if Self.videoExtensions.contains(url.pathExtension.lowercased()) {
                rows = try videoRows(url: url, embedder: embedder, shouldPause: shouldPause)
            } else {
                rows = try imageRows(url: url, embedder: embedder)
            }
        } catch ProcessingError.paused {
            try finish(work.jobId, state: "pending")
            summary.paused = true
            summary.deferredOffline += 1
            return
        } catch {
            try finish(work.jobId, state: "failed", checkpoint: work.token)
            summary.failed += 1
            return
        }
        guard !rows.isEmpty else {
            try finish(work.jobId, state: "done", checkpoint: work.token)
            summary.noFace += 1
            return
        }
        try queue.sync {
            try database.transaction {
                try database.run("DELETE FROM face_embeddings WHERE profile_id = ? AND asset_id = ?",
                                 [.text(profile.id), .text(work.assetId)])
                for row in rows {
                    let blob = row.vector.withUnsafeBytes { Data($0) }
                    try database.run("""
                        INSERT INTO face_embeddings
                        (face_id, asset_id, source_id, relative_path, start_ms, bbox_json, quality,
                         profile_id, vector_blob, content_change_token, created_at)
                        VALUES (?,?,?,?,?,?,?,?,?,?,?)
                        """, [.text(UUID().uuidString), .text(work.assetId), .text(work.sourceId),
                              .text(work.relativePath),
                              row.startMs.map { .int(Int64($0)) } ?? .null,
                              .text(row.bboxJSON),
                              row.quality.map { .double($0) } ?? .null,
                              .text(profile.id), .blob(blob), .text(work.token),
                              .int(Int64(Date().timeIntervalSince1970))])
                }
                try database.run("UPDATE index_jobs SET state = 'done', checkpoint_json = ? WHERE job_id = ?",
                                 [.text(work.token), .text(work.jobId)])
            }
        }
        summary.processed += 1
        summary.embedded += rows.count
    }

    private func imageRows(url: URL, embedder: FaceEmbeddingProviding) throws -> [FaceRow] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ProcessingError.videoUnreadable
        }
        do {
            let processed = try preprocessor.process(image: image)
            let vector = try embedder.embed(alignedImage: processed.alignedImage)
            guard vector.count == profile.dimension else { throw ProcessingError.videoUnreadable }
            return [FaceRow(startMs: nil, bboxJSON: Self.bboxJSON(processed.boundingBox),
                            quality: processed.quality, vector: vector)]
        } catch FaceAlignmentError.noFace {
            return []
        } catch FaceAlignmentError.missingLandmarks {
            return []
        }
    }

    private func videoRows(url: URL, embedder: FaceEmbeddingProviding,
                           shouldPause: () -> Bool) throws -> [FaceRow] {
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)
        guard seconds.isFinite, seconds > 0 else { throw ProcessingError.videoUnreadable }
        let durationMs = Int((seconds * 1_000).rounded(.down))
        let times = FaceVideoSampling.frameTimes(
            durationMs: durationMs, minIntervalMs: videoSampleIntervalMs, maxFrames: videoMaxFrames)
        guard !times.isEmpty else { throw ProcessingError.videoUnreadable }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let tolerance = CMTime(value: 100, timescale: 1_000)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        var rows: [FaceRow] = []
        var extractedFrames = 0
        for startMs in times {
            if shouldPause() { throw ProcessingError.paused }
            guard let image = Self.frame(generator, at: startMs, timeout: videoFrameTimeout) else {
                continue
            }
            extractedFrames += 1
            do {
                let processed = try preprocessor.process(image: image)
                let vector = try embedder.embed(alignedImage: processed.alignedImage)
                guard vector.count == profile.dimension else { continue }
                rows.append(FaceRow(startMs: startMs, bboxJSON: Self.bboxJSON(processed.boundingBox),
                                    quality: processed.quality, vector: vector))
            } catch FaceAlignmentError.noFace {
                continue
            } catch FaceAlignmentError.missingLandmarks {
                continue
            }
        }
        if rows.isEmpty, extractedFrames == 0 { throw ProcessingError.noFrameExtracted }
        return rows
    }

    /// AVAssetImageGenerator 同步调用可能卡在 SMB 坏文件；每帧独立看门狗，超时跳过。
    private static func frame(_ generator: AVAssetImageGenerator, at startMs: Int,
                              timeout: TimeInterval) -> CGImage? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ImageBox()
        DispatchQueue.global(qos: .utility).async {
            box.image = try? generator.copyCGImage(
                at: CMTime(value: CMTimeValue(startMs), timescale: 1_000),
                actualTime: nil)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.image
    }

    private func finish(_ jobId: String, state: String, checkpoint: String? = nil) throws {
        try queue.sync {
            if let checkpoint {
                try database.run("UPDATE index_jobs SET state = ?, checkpoint_json = ? WHERE job_id = ?",
                                 [.text(state), .text(checkpoint), .text(jobId)])
            } else {
                try database.run("UPDATE index_jobs SET state = ? WHERE job_id = ?",
                                 [.text(state), .text(jobId)])
            }
        }
    }

    private static func bboxJSON(_ rect: CGRect?) -> String {
        guard let rect else { return "{}" }
        let value: [String: Double] = [
            "x": Double(rect.origin.x),
            "y": Double(rect.origin.y),
            "w": Double(rect.size.width),
            "h": Double(rect.size.height)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    // MARK: - 查询 / 清理

    /// 同一资产（图片或视频）取最佳帧；视频 Hit 带 startMs，面板据此跳时间点。
    public func search(vector: [Float], limit: Int = 20, minScore: Double = 0.5,
                       sourceId: String? = nil) throws -> [Hit] {
        guard vector.count == profile.dimension, limit > 0 else { return [] }
        return try queue.sync {
            let sourceClause = sourceId == nil ? "" : "AND f.source_id = ?"
            var binds: [SQLiteValue] = [.text(profile.id)]
            if let sourceId { binds.append(.text(sourceId)) }
            let rows = try database.query("""
                SELECT f.asset_id, f.source_id, f.relative_path, f.start_ms, f.bbox_json, f.quality, f.vector_blob
                FROM face_embeddings f
                JOIN storage_sources s ON s.source_id = f.source_id
                WHERE f.profile_id = ? AND s.face_index_enabled = 1
                  AND (s.face_index_prefix IS NULL OR s.face_index_prefix = ''
                       OR substr(f.relative_path, 1, length(s.face_index_prefix)) = s.face_index_prefix)
                  \(sourceClause)
                """, binds) { statement -> Hit? in
                    let blob = statement.columnBlob(6)
                    let floats = blob.withUnsafeBytes { raw -> [Float] in
                        guard raw.count >= MemoryLayout<Float>.size else { return [] }
                        return Array(raw.bindMemory(to: Float.self))
                    }
                    guard floats.count == profile.dimension else { return nil }
                    let score = FaceVectorSearch.cosine(vector, floats)
                    guard score >= minScore else { return nil }
                    return Hit(
                        assetId: statement.columnText(0),
                        sourceId: statement.columnText(1),
                        relativePath: statement.columnText(2),
                        startMs: statement.columnIsNull(3) ? nil : Int(statement.columnInt(3)),
                        score: score,
                        bboxJSON: statement.columnText(4),
                        quality: statement.columnIsNull(5) ? nil : statement.columnDouble(5))
                }.compactMap { $0 }
            var bestByAsset: [String: Hit] = [:]
            for hit in rows {
                if let current = bestByAsset[hit.assetId], current.score >= hit.score { continue }
                bestByAsset[hit.assetId] = hit
            }
            return bestByAsset.values
                .sorted {
                    if $0.score != $1.score { return $0.score > $1.score }
                    return $0.assetId < $1.assetId
                }
                .prefix(limit)
                .map { $0 }
        }
    }

    @discardableResult
    public func clearPending(sourceId: String) throws -> Int {
        try queue.sync {
            let count = try database.query("""
                SELECT COUNT(*) FROM index_jobs
                WHERE source_id = ? AND job_type = 'face_embed' AND state = 'pending'
                """, [.text(sourceId)]) { Int($0.columnInt(0)) }.first ?? 0
            guard count > 0 else { return 0 }
            try database.run("""
                DELETE FROM index_jobs WHERE source_id = ? AND job_type = 'face_embed' AND state = 'pending'
                """, [.text(sourceId)])
            return count
        }
    }

    /// 隐私删除：清空所有人脸向量与该 profile 的任务。
    @discardableResult
    public func deleteAll() throws -> Int {
        try queue.sync {
            let count = try database.query(
                "SELECT COUNT(*) FROM face_embeddings WHERE profile_id = ?",
                [.text(profile.id)]) { Int($0.columnInt(0)) }.first ?? 0
            try database.transaction {
                try database.run("DELETE FROM face_embeddings WHERE profile_id = ?", [.text(profile.id)])
                try database.run("DELETE FROM index_jobs WHERE job_type = 'face_embed'", [])
            }
            return count
        }
    }
}
