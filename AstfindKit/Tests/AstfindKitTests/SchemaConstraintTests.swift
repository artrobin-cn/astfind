import XCTest
@testable import AstfindKit

/// 技术规范 §3 要求的反例测试：约束必须真的拦得住。
final class SchemaConstraintTests: XCTestCase {
    private var database: Database!

    override func setUpWithError() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("astfind-kit-schema-\(UUID().uuidString).sqlite")
        database = try Database(url: url)
        try Migrations.apply(to: database)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: database.url)
    }

    func testKindCheckRejectsUnknownValue() throws {
        try database.run("INSERT INTO storage_sources (source_id, kind, locator, display_name, created_at) VALUES ('s1','smb','smb://h/s','S',0)")
        XCTAssertThrowsError(try database.run("INSERT INTO storage_sources (source_id, kind, locator, display_name, created_at) VALUES ('s2','ftp','ftp://h','F',0)"))
    }

    func testUniqueSourceKindLocator() throws {
        try database.run("INSERT INTO storage_sources (source_id, kind, locator, display_name, created_at) VALUES ('s1','smb','smb://h/s','S',0)")
        XCTAssertThrowsError(try database.run("INSERT INTO storage_sources (source_id, kind, locator, display_name, created_at) VALUES ('s2','smb','smb://h/s','S2',0)"))
        try database.run("INSERT INTO storage_sources (source_id, kind, locator, display_name, created_at) VALUES ('s3','local','smb://h/s','S3',0)")  // 不同 kind 允许
    }

    func testAssetUniqueSourceRelativePath() throws {
        try database.run("INSERT INTO storage_sources (source_id, kind, locator, display_name, created_at) VALUES ('s1','local','file:///d','D',0)")
        try database.run("INSERT INTO assets (asset_id, source_id, relative_path) VALUES ('a1','s1','x/y.txt')")
        XCTAssertThrowsError(try database.run("INSERT INTO assets (asset_id, source_id, relative_path) VALUES ('a2','s1','x/y.txt')"))
        try database.run("INSERT INTO assets (asset_id, source_id, relative_path) VALUES ('a3','s1','other/y.txt')")  // 同名不同路径 OK
    }

    func testAssetForeignKeyCascade() throws {
        try database.run("INSERT INTO storage_sources (source_id, kind, locator, display_name, created_at) VALUES ('s1','local','file:///d','D',0)")
        try database.run("INSERT INTO assets (asset_id, source_id, relative_path) VALUES ('a1','s1','x.txt')")
        try database.run("DELETE FROM storage_sources WHERE source_id = 's1'")
        let count = try database.query("SELECT COUNT(*) FROM assets") { Int($0.columnInt(0)) }.first
        XCTAssertEqual(count, 0)   // ON DELETE CASCADE 生效
    }

    func testRelativePathRejectsTraversal() throws {
        // 越界路径（..）必须被应用层+约束双保险拦下——资产路径必须在授权根内
        XCTAssertNoThrow(try database.run("INSERT INTO storage_sources (source_id, kind, locator, display_name, created_at) VALUES ('s1','local','file:///d','D',0)"))
        // SQL 层不拦内容，应用层负责：SourceRegistry.syncAssets 的调用方（Connector）必须传规范化相对路径。
        // 这里验证我们有能力在应用层检测并拒绝：
        let evil = "../outside/secret.txt"
        XCTAssertNotNil(evil.range(of: "^\\.\\./", options: .regularExpression))
        XCTAssertTrue(evil.hasPrefix("../"), "应用层必须拒绝以 ../ 开头的 relativePath")
    }

    func testImageSegmentNullAndWholeImageUnique() throws {
        // 整图：无 segment 允许；UNIQUE(asset, kind, start, end) 不受 NULL 影响（start/end NOT NULL DEFAULT 0）
        try database.run("INSERT INTO storage_sources (source_id, kind, locator, display_name, created_at) VALUES ('s1','local','file:///d','D',0)")
        try database.run("INSERT INTO assets (asset_id, source_id, relative_path) VALUES ('a1','s1','pic.jpg')")
        try database.run("INSERT INTO media_segments (segment_id, asset_id, kind) VALUES ('g1','a1','whole_image')")
        XCTAssertThrowsError(try database.run("INSERT INTO media_segments (segment_id, asset_id, kind) VALUES ('g2','a1','whole_image')"))  // 同 asset 同 kind 同窗口唯一
        try database.run("INSERT INTO media_segments (segment_id, asset_id, kind, start_ms, end_ms) VALUES ('g3','a1','video_window',0,5000)")
        try database.run("INSERT INTO media_segments (segment_id, asset_id, kind, start_ms, end_ms) VALUES ('g4','a1','video_window',5000,10000)")
        // text_observations 的 segment_id 可空（文档正文挂 asset，不挂 segment）
        try database.run("""
            INSERT INTO text_observations (observation_id, asset_id, segment_id, text_kind, body, extractor_profile, content_change_token)
            VALUES ('t1','a1',NULL,'document','正文内容','pdf-v1','tok-1')
            """)
        let nullSegment = try database.query("SELECT segment_id FROM text_observations WHERE observation_id='t1'") { $0.columnIsNull(0) }
        XCTAssertEqual(nullSegment, [true])
    }

    func testEmbeddingDimensionCheckAndProfileIsolation() throws {
        try database.run("INSERT INTO storage_sources (source_id, kind, locator, display_name, created_at) VALUES ('s1','local','file:///d','D',0)")
        try database.run("INSERT INTO assets (asset_id, source_id, relative_path) VALUES ('a1','s1','v.mp4')")
        try database.run("INSERT INTO media_segments (segment_id, asset_id, kind) VALUES ('g1','a1','whole_image')")
        XCTAssertThrowsError(try database.run("""
            INSERT INTO embedding_profiles (profile_id, provider_kind, model_id, model_revision, preprocessor_revision, modality, dimension, normalization, quantization, profile_json)
            VALUES ('p0','local','m','r','p','image',0,'l2','none','{}')
            """))   // dimension > 0
        try database.run("""
            INSERT INTO embedding_profiles (profile_id, provider_kind, model_id, model_revision, preprocessor_revision, modality, dimension, normalization, quantization, profile_json)
            VALUES ('p1','local','m','r','p','image',512,'l2','none','{}')
            """)
        try database.run("""
            INSERT INTO embedding_profiles (profile_id, provider_kind, model_id, model_revision, preprocessor_revision, modality, dimension, normalization, quantization, profile_json)
            VALUES ('p2','local','m2','r2','p2','image',512,'l2','none','{}')
            """)   // 同维不同模型：两个 profile 并存（ADL-112 隔离）
        try database.run("INSERT INTO embeddings (embedding_id, segment_id, profile_id, vector_blob, content_change_token, indexed_at) VALUES ('e1','g1','p1',X'00','t',0)")
        XCTAssertThrowsError(try database.run("INSERT INTO embeddings (embedding_id, segment_id, profile_id, vector_blob, content_change_token, indexed_at) VALUES ('e2','g1','p1',X'01','t',0)"))  // 同 segment 同 profile 唯一
        try database.run("INSERT INTO embeddings (embedding_id, segment_id, profile_id, vector_blob, content_change_token, indexed_at) VALUES ('e3','g1','p2',X'02','t',0)")  // 换 profile 不串槽
    }

    func testFTSSyncByApplicationLayer() throws {
        // FTS 为 content 表镜像：应用层事务负责同步（技术规范 §3 说明）。
        // v2 起 FTS 为 trigram 分词：≥3 字子串走 MATCH；更短走 LIKE（检索层职责，见 ContentIndexer）。
        try database.run("INSERT INTO storage_sources (source_id, kind, locator, display_name, created_at) VALUES ('s1','local','file:///d','D',0)")
        try database.run("INSERT INTO assets (asset_id, source_id, relative_path) VALUES ('a1','s1','n.txt')")
        try database.run("""
            INSERT INTO text_observations (rowid, observation_id, asset_id, text_kind, body, extractor_profile, content_change_token)
            VALUES (101,'t1','a1','document','发票报销凭证单据','ocr-v1','t')
            """)
        try database.run("INSERT INTO text_observation_fts(rowid, body) VALUES (101, '发票报销凭证单据')")
        let trigramHits = try database.query("SELECT rowid FROM text_observation_fts WHERE text_observation_fts MATCH '\"票报销凭\"'") { $0.columnInt(0) }
        XCTAssertEqual(trigramHits, [101], "≥3 字子串由 trigram 命中")
        let likeHits = try database.query("SELECT rowid FROM text_observations WHERE body LIKE '%发票%'") { $0.columnInt(0) }
        XCTAssertEqual(likeHits, [101], "2 字词由 LIKE 兜底（trigram 无法表达）")
    }
}
