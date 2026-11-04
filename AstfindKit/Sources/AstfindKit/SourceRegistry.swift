import Foundation
import OilFindCore

// MARK: - 稳定身份（冻结给 D3/D4/D6/A1 的公共契约）

/// 存储来源身份。`sourceId` 全局唯一且永久；挂载点/卷名只是运行态字段，
/// 不得用于判定同一来源（ADL-109；D1 实测：跨挂载点重绑靠快照根路径映射）。
public struct SourceRecord: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case local, external, smb }
    public enum OnlineState: String, Sendable { case offline, online }
    public enum IndexState: String, Sendable { case empty, partial, ready, stale }

    public let sourceId: String
    /// var：R1 存量迁移会把位于 SMB 挂载下的无 UUID 来源升级为 .smb（物理事实优先）。
    public var kind: Kind
    public var id: String { sourceId }
    /// 标准化、不含凭据的来源定位符（如 smb://host/share/sub，不含密码）。
    /// var：SMB 存量迁移（路径型 → smb:// 身份）与 R2 relink 会更新它；身份语义不变。
    public var locator: String
    public var displayName: String
    /// 可选的稳定卷身份（本地/外置卷的 volume UUID）；SMB 通常为空。
    public var volumeIdentity: String?
    /// 当前挂载点（运行态，不做永久身份）。
    public var mountPath: String?
    /// Keychain / 权限书签的引用名——绝不存密钥明文。
    public var authRef: String?
    public var onlineState: OnlineState
    public var indexState: IndexState
    /// 快照构建时的根路径；离线加载必须用它构造 config（指纹匹配的前提）。
    public var snapshotRootPath: String?
    public var lastScanAt: Date?
    public var lastSuccessfulScanAt: Date?
    public let createdAt: Date
    /// 内容专用来源：复用面板已建的文件名索引登记资产，只做 OCR/正文抽取；
    /// 不参与 sources()（文件名检索归面板），对用户来源清单隐藏。
    public let contentOnly: Bool
    /// 是否对该来源做内容索引（OCR/正文/语义）。关闭=停止新增内容索引；
    /// 关闭时由引擎清理该来源尚未处理的内容任务，已完成结果保留。
    public var contentIndexEnabled: Bool = true
    /// 是否对该来源做人脸索引（M0.8b）。默认关闭，与内容 OCR 开关解耦。
    public var faceIndexEnabled: Bool = false
    /// 人脸索引相对路径前缀；nil/空 = 整个来源。大型照片库只索引指定目录。
    public var faceIndexPrefix: String? = nil
}

/// 文件资产身份：`sourceId + relativePath` 唯一；同一文件名跨来源不合并。
public struct AssetRecord: Equatable, Sendable {
    public let assetId: String
    public let sourceId: String
    public let relativePath: String
    public var kind: String
    public var size: Int64
    public var mtimeNs: Int64?
    public var lastSeenScanId: String?
    public var deletedConfirmedAt: Date?

    public init(assetId: String, sourceId: String, relativePath: String, kind: String = "file",
                size: Int64 = 0, mtimeNs: Int64? = nil, lastSeenScanId: String? = nil, deletedConfirmedAt: Date? = nil) {
        self.assetId = assetId; self.sourceId = sourceId; self.relativePath = relativePath
        self.kind = kind; self.size = size; self.mtimeNs = mtimeNs
        self.lastSeenScanId = lastSeenScanId; self.deletedConfirmedAt = deletedConfirmedAt
    }
}

public struct ScanRunRecord: Equatable, Sendable {
    public enum Status: String, Sendable { case running, completed, failed, cancelled }
    public let scanRunId: String
    public let sourceId: String
    public let startedAt: Date
    public var completedAt: Date?
    public var status: Status
}

public struct AssetSyncSummary: Equatable, Sendable {
    public var seen = 0
    public var added = 0
    public var updated = 0
    public var resurrected = 0
    public var confirmedDeleted = 0
    /// 扫描未完成时保留的旧条目（stale/partial，不删除）。
    public var staleUntouched = 0
}

public enum RegistryError: Error, Equatable {
    case duplicateSource(kind: String, locator: String)
    case unknownSource(String)
    case missingSnapshotRoot(String)
}

// MARK: - SourceRegistry

public final class SourceRegistry {
    private let database: Database
    private let queue = DispatchQueue(label: "astfind.registry")  // 单写者纪律

    public init(databaseURL: URL) throws {
        self.database = try Database(url: databaseURL)
        try Migrations.apply(to: database)
    }
    init(database: Database) throws {
        self.database = database
        try Migrations.apply(to: database)
    }

    // MARK: 来源 CRUD

    @discardableResult
    public func registerSource(kind: SourceRecord.Kind, locator: String, displayName: String,
                               volumeIdentity: String? = nil, authRef: String? = nil,
                               contentOnly: Bool = false) throws -> SourceRecord {
        try queue.sync {
            let normalized = Self.normalizeLocator(locator)
            let existing = try database.query(
                "SELECT source_id FROM storage_sources WHERE kind = ? AND locator = ?",
                [.text(kind.rawValue), .text(normalized)]
            ) { $0.columnText(0) }
            guard existing.isEmpty else { throw RegistryError.duplicateSource(kind: kind.rawValue, locator: normalized) }
            let record = SourceRecord(
                sourceId: UUID().uuidString, kind: kind, locator: normalized, displayName: displayName,
                volumeIdentity: volumeIdentity, mountPath: nil, authRef: authRef,
                onlineState: .offline, indexState: .empty, snapshotRootPath: nil,
                lastScanAt: nil, lastSuccessfulScanAt: nil, createdAt: Date(), contentOnly: contentOnly)
            try database.run("""
                INSERT INTO storage_sources
                (source_id, kind, locator, display_name, volume_identity, auth_ref, online_state, index_state, created_at, content_only)
                VALUES (?,?,?,?,?,?,?,?,?,?)
                """, [.text(record.sourceId), .text(kind.rawValue), .text(normalized), .text(displayName),
                      volumeIdentity.map { .text($0) } ?? .null, authRef.map { .text($0) } ?? .null,
                      .text(SourceRecord.OnlineState.offline.rawValue), .text(SourceRecord.IndexState.empty.rawValue),
                      .int(Int64(record.createdAt.timeIntervalSince1970)), .int(contentOnly ? 1 : 0)])
            return record
        }
    }

    public func sources() throws -> [SourceRecord] {
        try queue.sync {
            try database.query("SELECT * FROM storage_sources ORDER BY created_at", map: Self.decodeSource)
        }
    }
    public func source(id: String) throws -> SourceRecord? {
        try queue.sync {
            try database.query("SELECT * FROM storage_sources WHERE source_id = ?", [.text(id)], map: Self.decodeSource).first
        }
    }

    public func updateMount(sourceId: String, mountPath: String?, online: Bool) throws {
        try queue.sync {
            let count = try database.query("SELECT COUNT(*) FROM storage_sources WHERE source_id = ?", [.text(sourceId)]) { Int($0.columnInt(0)) }.first ?? 0
            guard count > 0 else { throw RegistryError.unknownSource(sourceId) }
            try database.run("UPDATE storage_sources SET mount_path = ?, online_state = ? WHERE source_id = ?",
                             [mountPath.map { .text($0) } ?? .null,
                              .text(online ? SourceRecord.OnlineState.online.rawValue : SourceRecord.OnlineState.offline.rawValue),
                              .text(sourceId)])
        }
    }

    /// 切换某来源的内容索引（OCR/正文/语义）。只改登记表策略；pending 任务由引擎清理。
    public func setContentIndexEnabled(sourceId: String, enabled: Bool) throws {
        try queue.sync {
            let count = try database.query("SELECT COUNT(*) FROM storage_sources WHERE source_id = ?", [.text(sourceId)]) { Int($0.columnInt(0)) }.first ?? 0
            guard count > 0 else { throw RegistryError.unknownSource(sourceId) }
            try database.run("UPDATE storage_sources SET content_index_enabled = ? WHERE source_id = ?",
                             [.int(enabled ? 1 : 0), .text(sourceId)])
        }
    }

    /// 设置来源人脸索引范围（相对 source 根的路径前缀）；nil/空 = 整个来源。
    public func setFaceIndexPrefix(sourceId: String, prefix: String?) throws {
        try queue.sync {
            let count = try database.query("SELECT COUNT(*) FROM storage_sources WHERE source_id = ?", [.text(sourceId)]) { Int($0.columnInt(0)) }.first ?? 0
            guard count > 0 else { throw RegistryError.unknownSource(sourceId) }
            let value = prefix?.trimmingCharacters(in: .whitespacesAndNewlines)
            try database.run("UPDATE storage_sources SET face_index_prefix = ? WHERE source_id = ?",
                             [value.flatMap { $0.isEmpty ? nil : .text($0) } ?? .null, .text(sourceId)])
        }
    }

    /// 切换某来源的人脸索引（M0.8b）。只改登记表策略；pending 任务由 FaceIndexer 清理。
    public func setFaceIndexEnabled(sourceId: String, enabled: Bool) throws {
        try queue.sync {
            let count = try database.query("SELECT COUNT(*) FROM storage_sources WHERE source_id = ?", [.text(sourceId)]) { Int($0.columnInt(0)) }.first ?? 0
            guard count > 0 else { throw RegistryError.unknownSource(sourceId) }
            try database.run("UPDATE storage_sources SET face_index_enabled = ? WHERE source_id = ?",
                             [.int(enabled ? 1 : 0), .text(sourceId)])
        }
    }

    /// R1 存量迁移：路径型来源（kind 曾被记为 external/local——App 添加页对 /Volumes 一律记
    /// external，NAS 共享因此漏挂 smb 身份）升级为 smb:// 身份源，kind 与 locator 一次写入。
    public func upgradeToSMB(sourceId: String, locator: String) throws {
        try queue.sync {
            let count = try database.query("SELECT COUNT(*) FROM storage_sources WHERE source_id = ?", [.text(sourceId)]) { Int($0.columnInt(0)) }.first ?? 0
            guard count > 0 else { throw RegistryError.unknownSource(sourceId) }
            try database.run("UPDATE storage_sources SET kind = 'smb', locator = ? WHERE source_id = ?",
                             [.text(Self.normalizeLocator(locator)), .text(sourceId)])
        }
    }

    /// R2 手动重链接：挂载点、locator、在线态一次落库（单写者一个事务）。
    /// 快照文件、资产行、内容观测全部不动——身份=sourceId+relativePath 不变。
    public func relinkSource(sourceId: String, mountPath: String?, locator: String, online: Bool) throws {
        try queue.sync {
            let count = try database.query("SELECT COUNT(*) FROM storage_sources WHERE source_id = ?", [.text(sourceId)]) { Int($0.columnInt(0)) }.first ?? 0
            guard count > 0 else { throw RegistryError.unknownSource(sourceId) }
            try database.transaction {
                try database.run("""
                    UPDATE storage_sources
                    SET mount_path = ?, online_state = ?, locator = ? WHERE source_id = ?
                    """, [mountPath.map { .text($0) } ?? .null,
                          .text(online ? SourceRecord.OnlineState.online.rawValue : SourceRecord.OnlineState.offline.rawValue),
                          .text(Self.normalizeLocator(locator)), .text(sourceId)])
            }
        }
    }

    public func removeSource(sourceId: String) throws {
        try queue.sync {
            // scan_runs/index_jobs 对来源无级联（技术规范 §3 原样），须先清子表；
            // assets→segments→observations/embeddings 链路有 ON DELETE CASCADE。
            try database.transaction {
                try database.run("DELETE FROM index_jobs WHERE source_id = ?", [.text(sourceId)])
                try database.run("DELETE FROM scan_runs WHERE source_id = ?", [.text(sourceId)])
                try database.run("DELETE FROM storage_sources WHERE source_id = ?", [.text(sourceId)])
            }
        }
    }

    // MARK: 扫描运行（完整提交语义的记账侧）

    @discardableResult
    public func beginScanRun(sourceId: String) throws -> ScanRunRecord {
        try queue.sync {
            let run = ScanRunRecord(scanRunId: UUID().uuidString, sourceId: sourceId, startedAt: Date(), completedAt: nil, status: .running)
            try database.run("INSERT INTO scan_runs (scan_run_id, source_id, started_at, status) VALUES (?,?,?,?)",
                             [.text(run.scanRunId), .text(sourceId), .int(Int64(run.startedAt.timeIntervalSince1970)), .text(ScanRunRecord.Status.running.rawValue)])
            try database.run("UPDATE storage_sources SET last_scan_at = ? WHERE source_id = ?",
                             [.int(Int64(run.startedAt.timeIntervalSince1970)), .text(sourceId)])
            return run
        }
    }

    /// 扫描结束。`success` 才会推进 last_successful_scan_at / index_state=ready；
    /// 失败/取消只把 index_state 降为 stale——旧快照与资产行原样保留（离线 ≠ 删除）。
    public func endScanRun(_ run: ScanRunRecord, success: Bool, snapshotRootPath: String? = nil) throws {
        try queue.sync {
            let finished = Date()
            try database.run("UPDATE scan_runs SET completed_at = ?, status = ? WHERE scan_run_id = ?",
                             [.int(Int64(finished.timeIntervalSince1970)),
                              .text((success ? ScanRunRecord.Status.completed : ScanRunRecord.Status.failed).rawValue),
                              .text(run.scanRunId)])
            if success {
                if let root = snapshotRootPath {
                    try database.run("""
                        UPDATE storage_sources
                        SET last_successful_scan_at = ?, index_state = 'ready', snapshot_root_path = ?
                        WHERE source_id = ?
                        """, [.int(Int64(finished.timeIntervalSince1970)), .text(root), .text(run.sourceId)])
                } else {
                    try database.run("""
                        UPDATE storage_sources
                        SET last_successful_scan_at = ?, index_state = 'ready'
                        WHERE source_id = ?
                        """, [.int(Int64(finished.timeIntervalSince1970)), .text(run.sourceId)])
                }
            } else {
                try database.run("UPDATE storage_sources SET index_state = 'stale' WHERE source_id = ?", [.text(run.sourceId)])
            }
        }
    }

    // MARK: 资产同步（D1 语义：完整提交才确认删除）

    /// 将一次扫描看到的文件批次合入 assets。
    /// - `scanRunCompleted == false`（断线/取消/部分扫描）：只 upsert 见到的条目，
    ///   未见到的不动（stale 保留）——对应 POC-03 的实测行为。
    /// - `scanRunCompleted == true`：未见于本批的存活条目标记 deleted_confirmed_at。
    public func syncAssets(sourceId: String, scanRunId: String, scanRunCompleted: Bool,
                           entries: [(relativePath: String, kind: String, size: Int64, mtimeNs: Int64?)]) throws -> AssetSyncSummary {
        try queue.sync {
            var summary = AssetSyncSummary()
            summary.seen = entries.count
            let now = Int64(Date().timeIntervalSince1970)
            try database.transaction {
                // 复活检测必须先于 upsert：upsert 会把 deleted_confirmed_at 清空
                let previouslyDeleted = Set(try database.query(
                    "SELECT relative_path FROM assets WHERE source_id = ? AND deleted_confirmed_at IS NOT NULL",
                    [.text(sourceId)]) { $0.columnText(0) })
                let upsert = try database.prepare("""
                    INSERT INTO assets (asset_id, source_id, relative_path, kind, size, mtime_ns, last_seen_scan_id, deleted_confirmed_at)
                    VALUES (?,?,?,?,?,?,?,NULL)
                    ON CONFLICT(source_id, relative_path) DO UPDATE SET
                      kind = excluded.kind, size = excluded.size, mtime_ns = excluded.mtime_ns,
                      last_seen_scan_id = excluded.last_seen_scan_id, deleted_confirmed_at = NULL
                    """)
                for entry in entries {
                    try upsert.bind([.text(UUID().uuidString), .text(sourceId), .text(entry.relativePath),
                                     .text(entry.kind), .int(entry.size),
                                     entry.mtimeNs.map { .int($0) } ?? .null, .text(scanRunId)])
                    try upsert.step()
                }
                let existing = try database.query(
                    "SELECT relative_path FROM assets WHERE source_id = ? AND deleted_confirmed_at IS NULL",
                    [.text(sourceId)]) { $0.columnText(0) }
                let seenSet = Set(entries.map(\.relativePath))
                let existingSet = Set(existing)
                summary.resurrected = previouslyDeleted.intersection(seenSet).count
                summary.added = seenSet.subtracting(existingSet).subtracting(previouslyDeleted).count
                summary.updated = summary.seen - summary.added - summary.resurrected
                let unseen = existing.filter { !seenSet.contains($0) }
                if scanRunCompleted {
                    let mark = try database.prepare(
                        "UPDATE assets SET deleted_confirmed_at = ? WHERE source_id = ? AND relative_path = ? AND deleted_confirmed_at IS NULL")
                    for path in unseen {
                        try mark.bind([.int(now), .text(sourceId), .text(path)])
                        try mark.step()
                    }
                    summary.confirmedDeleted = unseen.count
                } else {
                    summary.staleUntouched = unseen.count
                }
            }
            return summary
        }
    }

    public func assets(sourceId: String, includeDeleted: Bool = false, limit: Int = 1000) throws -> [AssetRecord] {
        try queue.sync {
            try database.query("""
                SELECT asset_id, source_id, relative_path, kind, size, mtime_ns, last_seen_scan_id, deleted_confirmed_at
                FROM assets WHERE source_id = ? \(includeDeleted ? "" : "AND deleted_confirmed_at IS NULL")
                ORDER BY relative_path LIMIT ?
                """, [.text(sourceId), .int(Int64(limit))], map: Self.decodeAsset)
        }
    }

    public func liveAssetCount(sourceId: String) throws -> Int {
        try queue.sync {
            try database.query("SELECT COUNT(*) FROM assets WHERE source_id = ? AND deleted_confirmed_at IS NULL",
                               [.text(sourceId)]) { Int($0.columnInt(0)) }.first ?? 0
        }
    }

    // MARK: 从 oil-find store 提取条目

    /// 只读遍历公开 API；不持久化 entryID（ADL-109——它是 store 内临时下标）。
    /// 目录不进资产表：目录仍是 store 里的搜索结果，但内容管线（OCR/embedding）只关心文件。
    public static func entries(in store: IndexStore) -> [(relativePath: String, kind: String, size: Int64, mtimeNs: Int64?)] {
        entries(in: store, underPath: nil)
    }

    /// 按目录前缀过滤的登记（本机内容范围用：面板主索引覆盖整盘，内容源只要所选目录的条目）。
    /// 过滤在读锁内流式完成——整盘 200 万+条目只物化所选子集。
    public static func entries(in store: IndexStore, underPath path: String?) -> [(relativePath: String, kind: String, size: Int64, mtimeNs: Int64?)] {
        store.read {
            let root = store.rootPath == "/" ? "" : store.rootPath
            var result: [(String, String, Int64, Int64?)] = []
            if let path {
                // 所选目录的绝对路径（组件级前缀：/a-b 不算 /a 之下）
                result.reserveCapacity(1024)
                let kindNames = ["folder", "app", "doc", "image", "video", "audio", "code", "archive"]
                for index in 1..<store.count where store.isLive(UInt32(index)) {
                    guard store.flags[index] & SiftFlag.dir == 0 else { continue }
                    let absolute = store.path(UInt32(index))
                    guard absolute == path || absolute.hasPrefix(path + "/") else { continue }
                    let kindIndex = Int(store.kind[index])
                    result.append((String(absolute.dropFirst(root.count + 1)),
                                   kindIndex < kindNames.count ? kindNames[kindIndex] : "file",
                                   Int64(store.size(UInt32(index))),
                                   Int64(store.mtime[index])))
                }
                return result.map { (relativePath: $0.0, kind: $0.1, size: $0.2, mtimeNs: $0.3) }
            }
            result.reserveCapacity(store.liveCount)
            let kindNames = ["folder", "app", "doc", "image", "video", "audio", "code", "archive"]
            for index in 1..<store.count where store.isLive(UInt32(index)) {
                guard store.flags[index] & SiftFlag.dir == 0 else { continue }
                let absolute = store.path(UInt32(index))
                guard absolute.hasPrefix(root + "/") else { continue }
                let kindIndex = Int(store.kind[index])
                result.append((String(absolute.dropFirst(root.count + 1)),
                               kindIndex < kindNames.count ? kindNames[kindIndex] : "file",
                               Int64(store.size(UInt32(index))),
                               Int64(store.mtime[index])))
            }
            return result.map { (relativePath: $0.0, kind: $0.1, size: $0.2, mtimeNs: $0.3) }
        }
    }

    // MARK: 私有

    static func normalizeLocator(_ locator: String) -> String {
        var trimmed = locator.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("://") { trimmed = "file://" + trimmed }
        // 剥离凭据：scheme://user:pass@host/path → scheme://host/path（密码绝入库）
        if let schemeRange = trimmed.range(of: "://") {
            var authority = String(trimmed[schemeRange.upperBound...])
            var path = ""
            if let slash = authority.firstIndex(of: "/") {
                path = String(authority[slash...])
                authority = String(authority[..<slash])
            }
            if let at = authority.firstIndex(of: "@") {
                authority = String(authority[authority.index(after: at)...])
            }
            trimmed = trimmed[..<schemeRange.upperBound] + authority + path
        }
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    static func decodeSource(_ statement: Statement) -> SourceRecord {
        SourceRecord(
            sourceId: statement.columnText(0),
            kind: SourceRecord.Kind(rawValue: statement.columnText(1)) ?? .local,
            locator: statement.columnText(2),
            displayName: statement.columnText(3),
            volumeIdentity: statement.columnIsNull(4) ? nil : statement.columnText(4),
            mountPath: statement.columnIsNull(5) ? nil : statement.columnText(5),
            authRef: statement.columnIsNull(6) ? nil : statement.columnText(6),
            onlineState: SourceRecord.OnlineState(rawValue: statement.columnText(8)) ?? .offline,
            indexState: SourceRecord.IndexState(rawValue: statement.columnText(9)) ?? .empty,
            snapshotRootPath: statement.columnIsNull(10) ? nil : statement.columnText(10),
            lastScanAt: statement.columnIsNull(11) ? nil : Date(timeIntervalSince1970: statement.columnDouble(11)),
            lastSuccessfulScanAt: statement.columnIsNull(12) ? nil : Date(timeIntervalSince1970: statement.columnDouble(12)),
            createdAt: Date(timeIntervalSince1970: statement.columnDouble(13)),
            contentOnly: statement.columnInt(14) != 0,
            contentIndexEnabled: statement.columnInt(15) != 0,
            faceIndexEnabled: statement.columnInt(16) != 0,
            faceIndexPrefix: statement.columnIsNull(17) ? nil : statement.columnText(17))
    }

    static func decodeAsset(_ statement: Statement) -> AssetRecord {
        AssetRecord(
            assetId: statement.columnText(0), sourceId: statement.columnText(1), relativePath: statement.columnText(2),
            kind: statement.columnText(3), size: statement.columnInt(4),
            mtimeNs: statement.columnIsNull(5) ? nil : statement.columnInt(5),
            lastSeenScanId: statement.columnIsNull(6) ? nil : statement.columnText(6),
            deletedConfirmedAt: statement.columnIsNull(7) ? nil : Date(timeIntervalSince1970: statement.columnDouble(7)))
    }
}

