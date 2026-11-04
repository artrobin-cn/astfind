import Foundation

/// 顺序迁移：user_version 记录已应用版本，逐版在事务内执行。
/// 规则（技术架构 §3 / D2 卡）：只追加不改历史版本；缓存写入走事务；
/// scan-run 完整提交才允许确认删除——由 SourceRegistry 在应用层保证。
enum Migrations {
    static let schemaV1 = """
    CREATE TABLE storage_sources (
      source_id TEXT PRIMARY KEY,
      kind TEXT NOT NULL CHECK(kind IN ('local','external','smb')),
      locator TEXT NOT NULL,
      display_name TEXT NOT NULL,
      volume_identity TEXT,
      mount_path TEXT,
      auth_ref TEXT,
      index_policy TEXT NOT NULL DEFAULT 'metadata',
      online_state TEXT NOT NULL DEFAULT 'offline',
      index_state TEXT NOT NULL DEFAULT 'empty',
      snapshot_root_path TEXT,
      last_scan_at INTEGER,
      last_successful_scan_at INTEGER,
      created_at INTEGER NOT NULL,
      UNIQUE(kind, locator)
    );
    CREATE TABLE assets (
      asset_id TEXT PRIMARY KEY,
      source_id TEXT NOT NULL REFERENCES storage_sources(source_id) ON DELETE CASCADE,
      relative_path TEXT NOT NULL,
      native_file_id TEXT,
      kind TEXT NOT NULL DEFAULT 'file',
      size INTEGER NOT NULL DEFAULT 0,
      mtime_ns INTEGER,
      change_token TEXT,
      last_seen_scan_id TEXT,
      deleted_confirmed_at INTEGER,
      UNIQUE(source_id, relative_path)
    );
    CREATE INDEX ix_assets_source ON assets(source_id, deleted_confirmed_at);
    CREATE TABLE media_segments (
      segment_id TEXT PRIMARY KEY,
      asset_id TEXT NOT NULL REFERENCES assets(asset_id) ON DELETE CASCADE,
      kind TEXT NOT NULL,
      start_ms INTEGER NOT NULL DEFAULT 0,
      end_ms INTEGER NOT NULL DEFAULT 0,
      thumbnail_cache_key TEXT,
      UNIQUE(asset_id, kind, start_ms, end_ms)
    );
    CREATE TABLE text_observations (
      observation_id TEXT PRIMARY KEY,
      asset_id TEXT NOT NULL REFERENCES assets(asset_id) ON DELETE CASCADE,
      segment_id TEXT REFERENCES media_segments(segment_id) ON DELETE CASCADE,
      text_kind TEXT NOT NULL,
      body TEXT NOT NULL,
      start_ms INTEGER,
      end_ms INTEGER,
      extractor_profile TEXT NOT NULL,
      content_change_token TEXT NOT NULL
    );
    CREATE INDEX ix_text_obs_asset ON text_observations(asset_id);
    CREATE VIRTUAL TABLE text_observation_fts
      USING fts5(body, content='text_observations', content_rowid='rowid');
    CREATE TABLE embedding_profiles (
      profile_id TEXT PRIMARY KEY,
      provider_kind TEXT NOT NULL,
      model_id TEXT NOT NULL,
      model_revision TEXT NOT NULL,
      preprocessor_revision TEXT NOT NULL,
      modality TEXT NOT NULL,
      dimension INTEGER NOT NULL CHECK(dimension > 0),
      normalization TEXT NOT NULL,
      quantization TEXT NOT NULL,
      profile_json TEXT NOT NULL
    );
    CREATE TABLE embeddings (
      embedding_id TEXT PRIMARY KEY,
      segment_id TEXT NOT NULL REFERENCES media_segments(segment_id) ON DELETE CASCADE,
      profile_id TEXT NOT NULL REFERENCES embedding_profiles(profile_id),
      vector_blob BLOB NOT NULL,
      content_change_token TEXT NOT NULL,
      indexed_at INTEGER NOT NULL,
      UNIQUE(segment_id, profile_id)
    );
    CREATE TABLE scan_runs (
      scan_run_id TEXT PRIMARY KEY,
      source_id TEXT NOT NULL REFERENCES storage_sources(source_id),
      started_at INTEGER NOT NULL,
      completed_at INTEGER,
      status TEXT NOT NULL,
      checkpoint_json TEXT
    );
    CREATE INDEX ix_scan_runs_source ON scan_runs(source_id, started_at);
    CREATE TABLE index_jobs (
      job_id TEXT PRIMARY KEY,
      source_id TEXT NOT NULL REFERENCES storage_sources(source_id),
      asset_id TEXT REFERENCES assets(asset_id),
      job_type TEXT NOT NULL,
      state TEXT NOT NULL,
      priority INTEGER NOT NULL DEFAULT 0,
      retry_count INTEGER NOT NULL DEFAULT 0,
      checkpoint_json TEXT
    );
    CREATE INDEX ix_index_jobs_pending ON index_jobs(state, priority);
    """

    /// v2（D6）：FTS 重建为 trigram 分词——默认 unicode61 无法命中中文子串
    /// （无空格整句成单 token）；trigram 为精确子串语义（SQLite ≥3.34，实测 3.51.0）。
    /// 2 字以内查询 trigram 无法表达（需 ≥3 字符），由检索层 LIKE 兜底。
    /// content 表镜像：重建后按外部内容表回填存量行。
    static let schemaV2 = """
    DROP TABLE IF EXISTS text_observation_fts;
    CREATE VIRTUAL TABLE text_observation_fts
      USING fts5(body, content='text_observations', content_rowid='rowid', tokenize='trigram');
    INSERT INTO text_observation_fts(rowid, body)
      SELECT rowid, body FROM text_observations;
    """

    /// v3（2026-10-19）：内容专用来源——复用面板外置盘索引登记资产、只做 OCR/正文抽取，
    /// 不重复扫描；sources()/records() 对用户隐藏（文件名检索仍归面板 catalog）。
    static let schemaV3 = "ALTER TABLE storage_sources ADD COLUMN content_only INTEGER NOT NULL DEFAULT 0"

    /// v4（2026-10-20）：清除 v3 之前入队的 AppleDouble/.DS_Store 僵尸任务——
    /// NAS 上的 ._ 假图片曾把 Vision 识别吊死（内部信号量永眠），整个抽取泵停摆。
    static let schemaV4 = """
    DELETE FROM index_jobs WHERE state = 'pending'
      AND asset_id IN (SELECT asset_id FROM assets
                       WHERE relative_path LIKE '._%' OR relative_path LIKE '%/._%'
                          OR relative_path = '.DS_Store' OR relative_path LIKE '%/.DS_Store')
    """

    /// v5（2026-10-21）：按资产反查的索引——入队候选查询对"该资产是否已有任务/向量"逐资产探询，
    /// 任务表 30 万行无 asset_id 索引时 9 万资产入队要全扫 9 万遍（App 启动 CPU 197% 卡数分钟，采样实锤）。
    static let schemaV5 = """
    CREATE INDEX IF NOT EXISTS ix_index_jobs_asset ON index_jobs(asset_id, job_type, state);
    CREATE INDEX IF NOT EXISTS ix_media_segments_asset ON media_segments(asset_id, kind);
    CREATE INDEX IF NOT EXISTS ix_assets_source_live ON assets(source_id, deleted_confirmed_at);
    """

    /// v6（2026-10-21）：任务失败计笔——毒图隔离。NAS 源一张 4MB 微信图让 WeMM 对单图恒 502，
    /// 环境类"留队重试"语义使其每轮被重新认领、永不收敛，还反复触发服务端异常。
    /// 仅在服务端近期有成功证据时记笔，满 10 笔终态 failed；纯宕机不记笔（不误杀整队）。
    static let schemaV6 = "ALTER TABLE index_jobs ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0"

    /// v7（2026-10-22）：进度聚合覆盖索引。设置页每 1.5s 轮询
    /// `WHERE job_type='extract_text' GROUP BY source_id, state`；69 万任务行无覆盖索引时
    /// 必须全表扫描 + 临时排序（实测单次 1.05s，排序溢出落盘）。建此索引后同一查询 0.04s。
    /// 只加索引不改数据；存量库首次启动一次性建索引（实测 ~1.2s）。
    static let schemaV7 = """
    CREATE INDEX IF NOT EXISTS ix_index_jobs_type_source_state ON index_jobs(job_type, source_id, state)
    """

    /// v8（2026-11-02）：按来源关闭内容索引。大型照片/视频归档只保留文件名/元数据搜索，
    /// 不再为几十万张图片排队 OCR/正文/语义任务；关闭时由 ContentIndexer 清理该来源 pending。
    static let schemaV8 = "ALTER TABLE storage_sources ADD COLUMN content_index_enabled INTEGER NOT NULL DEFAULT 1"

    /// v9（2026-11-02）：M0.8b 人脸索引基础。
    /// - 人脸是否参与索引按来源独立开关，默认关闭；与 content_index_enabled 解耦
    ///   （2026 照片库可能关闭 OCR 但仍想找人）。
    /// - 人脸向量独立表，不写 WeMM embeddings；profile + content token 支持增量与模型代次隔离。
    static let schemaV9 = """
    ALTER TABLE storage_sources ADD COLUMN face_index_enabled INTEGER NOT NULL DEFAULT 0;
    CREATE TABLE face_embeddings (
      face_id TEXT PRIMARY KEY,
      asset_id TEXT NOT NULL REFERENCES assets(asset_id) ON DELETE CASCADE,
      source_id TEXT NOT NULL REFERENCES storage_sources(source_id) ON DELETE CASCADE,
      relative_path TEXT NOT NULL,
      start_ms INTEGER,
      bbox_json TEXT NOT NULL,
      quality REAL,
      profile_id TEXT NOT NULL,
      vector_blob BLOB NOT NULL,
      content_change_token TEXT NOT NULL,
      created_at INTEGER NOT NULL
    );
    CREATE INDEX ix_face_embeddings_asset ON face_embeddings(asset_id);
    CREATE INDEX ix_face_embeddings_profile_source ON face_embeddings(profile_id, source_id);
    CREATE INDEX ix_face_embeddings_profile_asset ON face_embeddings(profile_id, asset_id);
    """

    /// v10（2026-11-03）：来源级人脸索引范围。大型照片库只索引指定相对路径前缀，
    /// 避免为了找人把 9 万张照片全部向量化；NULL/空 = 整个来源。
    static let schemaV10 = "ALTER TABLE storage_sources ADD COLUMN face_index_prefix TEXT"

    static let all: [(version: Int, sql: String)] = [
        (1, schemaV1),
        (2, schemaV2),
        (3, schemaV3),
        (4, schemaV4),
        (5, schemaV5),
        (6, schemaV6),
        (7, schemaV7),
        (8, schemaV8),
        (9, schemaV9),
        (10, schemaV10)
    ]

    static func apply(to database: Database) throws {
        let current = database.userVersion
        for migration in all where migration.version > current {
            try database.transaction {
                try database.exec(migration.sql)
                try database.exec("PRAGMA user_version = \(migration.version)")
            }
        }
    }
}
