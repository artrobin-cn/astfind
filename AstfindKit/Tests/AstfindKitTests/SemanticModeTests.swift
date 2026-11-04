import XCTest
@testable import AstfindKit

/// 语义模型模式（关闭 / 远程 / 本地）与向量空间身份。
///
/// 第一性原理：
/// 1. 模式是**发送边界**：本地只许回环（零外发），远程仍需显式授权，关闭即不注册图片 Provider；
/// 2. 切换模型 = 新的向量空间：不同模型/维度绝不混写同一 profile（否则旧向量让新图永不补算、检索假死）；
/// 3. 旧配置（无 semanticMode 字段）行为不变，解码绝不失败丢配置。
final class SemanticModeTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("astfind-mode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private var providersFile: URL { home.appendingPathComponent("providers.json") }

    /// 记录请求的传输；可配置是否响应。
    final class CountingTransport: HTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var count = 0
        var respond = true
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lock.lock(); count += 1; lock.unlock()
            guard respond else { throw URLError(.cannotConnectToHost) }
            let body = try JSONSerialization.data(withJSONObject: ["data": [["embedding": [0.1, 0.2, 0.3]]]])
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        func makeHub(fileURL: URL) -> ProviderHub { ProviderHub(fileURL: fileURL, transport: self) }
        var requests: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    private func remoteConfig(id: String = "cloud") -> HTTPEmbeddingProvider.Config {
        .init(id: id, displayName: "云端向量", endpoint: URL(string: "https://api.example.com/v1/embeddings")!,
              model: "wemm", imageInput: .dataURL)
    }
    private func loopbackConfig(id: String = "ollama") -> HTTPEmbeddingProvider.Config {
        .init(id: id, displayName: "本机 WeMM", endpoint: URL(string: "http://127.0.0.1:8098/v1/embeddings")!,
              model: "weemm-2b", imageInput: .dataURL)
    }

    // MARK: - 旧配置向后兼容

    /// 旧 providers.json（无 semanticMode / imageInput）解码成功，模式按第一个端点性质推断——行为不变。
    func testLegacyConfigurationInfersModeWithoutChangingSelection() throws {
        try Data("""
        {"allowRemoteEgress": false, "httpEmbeddings": [
          {"id":"wemm","displayName":"WeMM","endpoint":"http://api.example.com/v1/embeddings","model":"wemm"}
        ]}
        """.utf8).write(to: providersFile)
        let hub = ProviderHub(fileURL: providersFile, transport: CountingTransport())
        XCTAssertNil(hub.storedSemanticMode(), "旧配置没有显式模式")
        XCTAssertEqual(hub.semanticMode(), .remote, "按第一个 Provider 的端点性质推断")
        XCTAssertEqual(hub.semanticEmbeddingProviders().map(\.id), ["wemm"], "旧行为：候选=全部已配置 Provider")
        let status = hub.semanticStatus()
        XCTAssertTrue(status.inferred)
        XCTAssertEqual(status.providerId, "wemm")
        XCTAssertTrue(status.isConfigured)
        XCTAssertEqual(status.model, "wemm")
    }

    /// 关闭：不注册图片 Provider；持久化后重启仍关闭。
    func testOffModeRegistersNoProvidersAndPersists() throws {
        let transport = CountingTransport()
        let hub = transport.makeHub(fileURL: providersFile)
        try hub.addHTTPEmbedding(remoteConfig())
        try hub.addHTTPEmbedding(loopbackConfig())
        XCTAssertEqual(hub.semanticEmbeddingProviders().count, 2)

        try hub.setSemanticMode(.off)
        XCTAssertTrue(hub.semanticEmbeddingProviders().isEmpty, "关闭 = 语义通道整体退出")
        XCTAssertEqual(hub.semanticMode(), .off)
        XCTAssertEqual(hub.embeddingProviders.count, 2, "高级列表仍可见（只是不参与语义）")

        let reloaded = ProviderHub(fileURL: providersFile, transport: transport)
        XCTAssertEqual(reloaded.storedSemanticMode(), .off)
        XCTAssertTrue(reloaded.semanticEmbeddingProviders().isEmpty, "重启用仍是关闭")
    }

    /// 本地模式只回环、远程模式只非回环——即便已有外发授权，本地也摸不到远端。
    func testModeFiltersProvidersByLocality() throws {
        let transport = CountingTransport()
        let hub = transport.makeHub(fileURL: providersFile)
        try hub.addHTTPEmbedding(remoteConfig())
        try hub.addHTTPEmbedding(loopbackConfig())
        try hub.setAllowRemoteEgress(true)

        try hub.setSemanticMode(.local)
        XCTAssertEqual(hub.semanticEmbeddingProviders().map(\.id), ["ollama"], "本地只许回环")

        try hub.setSemanticMode(.remote)
        XCTAssertEqual(hub.semanticEmbeddingProviders().map(\.id), ["cloud"], "远程只许非回环")
    }

    /// 本地模式：回环默认放行，无需外发授权。
    func testLocalModeProbesLoopbackWithoutEgressAuthorization() async throws {
        let transport = CountingTransport()
        let hub = transport.makeHub(fileURL: providersFile)
        try hub.addHTTPEmbedding(loopbackConfig())
        try hub.setSemanticMode(.local)
        XCTAssertFalse(hub.egress.allowsRemote)
        let results = await hub.probeAll()
        XCTAssertTrue(results["ollama"]?.isAvailable == true)
        XCTAssertGreaterThan(transport.requests, 0, "回环不算外发，默认放行")
    }

    /// 远程模式 + 未授权：探测都发不出去，一个字节都不发。
    func testRemoteModeWithoutAuthorizationSendsNothing() async throws {
        let transport = CountingTransport()
        let hub = transport.makeHub(fileURL: providersFile)
        try hub.addHTTPEmbedding(remoteConfig())
        try hub.setSemanticMode(.remote)
        let results = await hub.probeAll()
        XCTAssertEqual(results["cloud"], .unavailable(.egressDenied))
        XCTAssertEqual(transport.requests, 0, "未授权状态下零请求——可抓包验证")
    }

    // MARK: - 引擎：关闭 / 切换的副作用

    final class StubImageProvider: EmbeddingProvider, @unchecked Sendable {
        let id = "stub", displayName = "假图片模型"
        let capabilities = ProviderCapabilities(embedText: true, embedImage: true, dimensions: 3, model: "stub-v1")
        func probe() async -> ProviderProbe { .available(latencyMs: 1, capabilities: capabilities) }
        func embedText(_ text: String) async throws -> [Float] { [1, 0, 0] }
        func embedImageData(_ data: Data, mime: String) async throws -> [Float] { [0, 1, 0] }
    }

    /// 关闭 → 引擎不给出任何图片 Provider；本机（进程内注入）Provider 只在本地/旧配置下候选。
    func testEngineObeysModeForActiveProvider() throws {
        let engine = try AstfindEngine(home: home.appendingPathComponent("data"))
        let stub = StubImageProvider()
        engine.providers.addEmbeddingProvider(stub)
        engine.providers.record(probe: .available(latencyMs: 1, capabilities: stub.capabilities), id: stub.id)

        XCTAssertEqual(engine.semanticStatus().mode, .local, "无 HTTP Provider 时旧配置推断为本地")
        XCTAssertEqual(engine.activeImageEmbedding()?.provider.id, "stub")

        try engine.setSemanticMode(.off)
        XCTAssertNil(engine.activeImageEmbedding(), "关闭：不注册图片 Provider")

        try engine.setSemanticMode(.local)
        XCTAssertEqual(engine.activeImageEmbedding()?.provider.id, "stub", "进程内 Provider 视为本地")
        engine.stop()
    }

    /// 切换模式只写配置并停泵；建向量必须显式再开——绝不静默重嵌数小时。
    func testModeSwitchStopsIndexingAndDoesNotStartIt() throws {
        let engine = try AstfindEngine(home: home.appendingPathComponent("data"))
        engine.setSemanticSearch(enabled: true, persist: false)
        XCTAssertTrue(engine.semanticSearchEnabled)

        try engine.setSemanticMode(.local)
        XCTAssertFalse(engine.semanticSearchEnabled, "切换停泵，不自动开始建向量")
        XCTAssertEqual(engine.semanticStatus().mode, .local)

        engine.setSemanticSearch(enabled: true, persist: false)
        XCTAssertTrue(engine.semanticSearchEnabled, "显式开启才恢复索引")
        engine.setSemanticSearch(enabled: false, persist: false)
        engine.stop()
    }

    // MARK: - 向量空间身份

    /// 旧 profile 命名保留（4096 维 WeMM 现有数据零迁移）；换模型/维度才派生新空间。
    func testResolveProfileKeepsLegacySpaceAndSplitsOnModelChange() throws {
        let indexer = try EmbeddingIndexer(databaseURL: home.appendingPathComponent("embed.sqlite"))
        let legacy = indexer.resolveProfile(providerId: "sem", model: "wemm", dimension: 4096)
        XCTAssertEqual(legacy.id, "sem-image-v1", "首次建立沿用旧 id")
        try indexer.ensureProfile(legacy)
        XCTAssertEqual(indexer.resolveProfile(providerId: "sem", model: "wemm", dimension: 4096).id,
                       "sem-image-v1", "签名一致 → 复用（不重嵌现有数据）")

        let local = indexer.resolveProfile(providerId: "sem", model: "weemm-2b", dimension: 2048)
        XCTAssertNotEqual(local.id, legacy.id, "换模型 = 新向量空间")
        XCTAssertTrue(local.id.contains("2048"))
        try indexer.ensureProfile(local)
        XCTAssertEqual(indexer.resolveProfile(providerId: "sem", model: "weemm-2b", dimension: 2048).id,
                       local.id, "同输入同 id（确定性）")
        XCTAssertEqual(indexer.resolveProfile(providerId: "sem", model: "wemm", dimension: 4096).id,
                       legacy.id, "切回旧模型 → 旧向量可复用")

        XCTAssertEqual(indexer.profileSummaries().count, 2, "两个空间并存，互不覆盖")
    }

    /// 同模型换维度同样必须分空间（维度是身份的一部分）。
    func testResolveProfileSplitsOnDimensionChange() throws {
        let indexer = try EmbeddingIndexer(databaseURL: home.appendingPathComponent("embed.sqlite"))
        let a = indexer.resolveProfile(providerId: "mrl", model: "weemm-2b", dimension: 2048)
        try indexer.ensureProfile(a)
        let b = indexer.resolveProfile(providerId: "mrl", model: "weemm-2b", dimension: 512)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertTrue(b.id.contains("512"))
    }

    /// 检索层兜底：维度不符的 blob 不参与点积（即便历史数据混进来也不会算错）。
    func testDotRejectsDimensionMismatch() {
        let blob = EmbeddingIndexer.quantize([1, 0, 0])
        var scratch = [Float](repeating: 0, count: 2)
        XCTAssertNil(EmbeddingIndexer.dot(quantized: blob, query: [1, 0], scratch: &scratch))
        XCTAssertNotNil(EmbeddingIndexer.dot(quantized: blob, query: [1, 0, 0], scratch: &scratch))
    }

    /// 探测也是发送：关闭模式下显式 probeAll 也必须零请求。
    func testOffModeProbeAllSendsNothing() async throws {
        let transport = CountingTransport()
        let hub = transport.makeHub(fileURL: providersFile)
        try hub.addHTTPEmbedding(remoteConfig())
        try hub.addHTTPEmbedding(loopbackConfig())
        try hub.setAllowRemoteEgress(true)
        try hub.setSemanticMode(.off)
        let results = await hub.probeAll()
        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(transport.requests, 0, "关闭 = 一个探测请求都不发")
    }

    /// 本地模式即使曾有外发授权，也绝不探测远端端点。
    func testLocalModeProbeAllNeverTouchesRemote() async throws {
        let transport = CountingTransport()
        let hub = transport.makeHub(fileURL: providersFile)
        try hub.addHTTPEmbedding(remoteConfig())
        try hub.addHTTPEmbedding(loopbackConfig())
        try hub.setAllowRemoteEgress(true)
        try hub.setSemanticMode(.local)
        let results = await hub.probeAll()
        XCTAssertEqual(Set(results.keys), ["ollama"], "候选只有回环端点")
    }

    /// 降级入口同样受模式约束：关闭后不得从旁路拿到任何 Provider。
    func testAvailableTextEmbedderObeysOffMode() async throws {
        let transport = CountingTransport()
        let hub = transport.makeHub(fileURL: providersFile)
        try hub.addHTTPEmbedding(loopbackConfig())
        try hub.setSemanticMode(.local)
        _ = await hub.probeAll()
        XCTAssertEqual(hub.availableTextEmbedder()?.id, "ollama")
        try hub.setSemanticMode(.off)
        XCTAssertNil(hub.availableTextEmbedder(), "关闭后降级入口也必须为空")
    }
}
