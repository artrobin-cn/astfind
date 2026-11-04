import XCTest
@testable import AstfindKit

/// A1 Provider 协议骨架：合同的核心不是 HTTP 细节，而是能力声明、失败分类、取消/超时、
/// 外发授权边界。全部用注入的 Mock 传输验证——不依赖真模型与网络。
final class ProviderTests: XCTestCase {
    /// 可脚本化的传输：记录每个请求，按脚本返回响应/抛错。
    final class MockTransport: HTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var requests: [URLRequest] = []
        var handler: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
        init(handler: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) { self.handler = handler }
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lock.lock(); requests.append(request); lock.unlock()
            return try await handler(request)
        }
        static func response(_ status: Int, for request: URLRequest) -> HTTPURLResponse {
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        }
        static func embedding(_ vector: [Double], for request: URLRequest) -> (Data, HTTPURLResponse) {
            let json: [String: Any] = ["data": [["embedding": vector]]]
            return (try! JSONSerialization.data(withJSONObject: json), response(200, for: request))
        }
    }
    struct StaticSecrets: SecretResolving {
        let values: [String: String]
        func secret(named ref: String) -> String? { values[ref] }
    }

    private var home: URL!
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("astfind-providers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private func remoteConfig(id: String = "cloud", keyRef: String? = nil) -> HTTPEmbeddingProvider.Config {
        .init(id: id, displayName: "云端向量", endpoint: URL(string: "https://api.example.com/v1/embeddings")!,
              model: "text-embedding-3-small", apiKeyRef: keyRef)
    }
    private func loopbackConfig() -> HTTPEmbeddingProvider.Config {
        .init(id: "ollama", displayName: "本机 Ollama", endpoint: URL(string: "http://127.0.0.1:11434/v1/embeddings")!,
              model: "bge-m3")
    }

    /// 隐私红线（决策 #7）：远端 Provider 在未授权时**一个字节都不发**；探测与调用均分类为 egressDenied。
    func testRemoteEgressDeniedByDefaultSendsNothing() async throws {
        let transport = MockTransport { MockTransport.embedding([0.1, 0.2], for: $0) }
        let provider = HTTPEmbeddingProvider(config: remoteConfig(), egress: ContentEgressPolicy(), transport: transport)
        let probe = await provider.probe()
        XCTAssertEqual(probe, .unavailable(.egressDenied))
        do { _ = try await provider.embedText("合同金额"); XCTFail("应拒绝") }
        catch { XCTAssertEqual(ProviderError.classify(error), .egressDenied) }
        XCTAssertTrue(transport.requests.isEmpty, "未授权状态下零请求——可抓包验证的承诺")
        XCTAssertFalse(ProviderError.egressDenied.isTransient, "配置类错误不重试，提示用户")
    }

    /// 本机回环=本地推理不外发，默认即放行；探测以实测维度更新能力声明。
    func testLoopbackPermittedAndProbeFillsDimensions() async throws {
        let transport = MockTransport { MockTransport.embedding([0.1, 0.2, 0.3], for: $0) }
        let provider = HTTPEmbeddingProvider(config: loopbackConfig(), egress: ContentEgressPolicy(), transport: transport)
        XCTAssertNil(provider.capabilities.dimensions, "探测前维度未知")
        let probe = await provider.probe()
        guard case .available(_, let caps) = probe else { return XCTFail("\(probe)") }
        XCTAssertEqual(caps.dimensions, 3)
        XCTAssertTrue(caps.embedText)
        XCTAssertFalse(caps.embedImage, "HTTP 兼容端点不自动视为支持图片（PRD 明文）")
        XCTAssertEqual(provider.capabilities.dimensions, 3)
        XCTAssertEqual(transport.requests.count, 1)
    }

    /// 授权后的回环：请求体含 model/input、Bearer 来自密钥引用（不存明文）；embedImage 恒 unsupported。
    func testAuthorizedRemoteRoundtripAndHonestCapabilities() async throws {
        let transport = MockTransport { MockTransport.embedding([1, 2, 3, 4], for: $0) }
        let egress = ContentEgressPolicy(allowRemote: true)
        let provider = HTTPEmbeddingProvider(config: remoteConfig(keyRef: "OPENAI"), egress: egress, transport: transport,
                                             secrets: StaticSecrets(values: ["OPENAI": "sk-test"]))
        let vector = try await provider.embedText("视频会议系统合同")
        XCTAssertEqual(vector, [1, 2, 3, 4])
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "text-embedding-3-small")
        XCTAssertEqual(body["input"] as? String, "视频会议系统合同")
        do { _ = try await provider.embedImage(at: URL(fileURLWithPath: "/tmp/x.png")); XCTFail() }
        catch { XCTAssertEqual(ProviderError.classify(error), .unsupported("embedImage")) }
    }

    /// 失败分类：鉴权/配额/服务端/超时/不可达/坏响应各归其类；transient 语义正确。
    func testFailureTaxonomy() async throws {
        let egress = ContentEgressPolicy(allowRemote: true)
        func probe(_ handler: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) async -> ProviderError? {
            let provider = HTTPEmbeddingProvider(config: remoteConfig(), egress: egress, transport: MockTransport(handler: handler))
            if case .unavailable(let e) = await provider.probe() { return e }
            return nil
        }
        let unauthorized = await probe { (Data(), MockTransport.response(401, for: $0)) }
        let quota = await probe { (Data(), MockTransport.response(429, for: $0)) }
        let server = await probe { (Data(), MockTransport.response(503, for: $0)) }
        let notFound = await probe { (Data(), MockTransport.response(404, for: $0)) }
        let timedOut = await probe { _ in throw URLError(.timedOut) }
        let refused = await probe { _ in throw URLError(.cannotConnectToHost) }
        let notJSON = await probe { (Data("not json".utf8), MockTransport.response(200, for: $0)) }
        let empty = await probe { (try! JSONSerialization.data(withJSONObject: ["data": []]), MockTransport.response(200, for: $0)) }
        XCTAssertEqual(unauthorized, .unauthorized)
        XCTAssertEqual(quota, .quotaExceeded)
        XCTAssertEqual(server, .server(503))
        XCTAssertEqual(notFound, .unsupported("endpoint 404"))
        XCTAssertEqual(timedOut, .timeout)
        XCTAssertEqual(refused, .unreachable(URLError(.cannotConnectToHost).localizedDescription))
        XCTAssertEqual(notJSON, .invalidResponse("not a JSON object"))
        XCTAssertEqual(empty, .invalidResponse("no embedding in response"))
        XCTAssertTrue(ProviderError.timeout.isTransient); XCTAssertTrue(ProviderError.server(503).isTransient)
        XCTAssertFalse(ProviderError.unauthorized.isTransient); XCTAssertFalse(ProviderError.unsupported("x").isTransient)
    }

    /// 取消：Task 取消协作式传递，分类为 cancelled（静默，不计失败）。
    func testCancellationIsClassified() async throws {
        let transport = MockTransport { request in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return MockTransport.embedding([0], for: request)
        }
        let provider = HTTPEmbeddingProvider(config: loopbackConfig(), egress: ContentEgressPolicy(), transport: transport)
        let task = Task { try await provider.embedText("x") }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("应被取消") }
        catch { XCTAssertEqual(ProviderError.classify(error), .cancelled) }
    }

    /// Hub：配置持久化往返（密钥只存引用名）、外发开关持久化、降级入口语义。
    func testHubPersistenceAndDegradation() async throws {
        let file = home.appendingPathComponent("providers.json")
        let failing = MockTransport { _ in throw URLError(.cannotConnectToHost) }
        let hub = ProviderHub(fileURL: file, transport: failing)
        XCTAssertNil(hub.availableTextEmbedder(), "空 Hub：无向量路径，一切照旧")
        try hub.addHTTPEmbedding(remoteConfig(keyRef: "OPENAI"))
        try hub.addHTTPEmbedding(loopbackConfig())
        try hub.setAllowRemoteEgress(true)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("\"apiKeyRef\":\"OPENAI\""))
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("sk-"), "配置文件绝不含密钥明文")

        // 重新加载 = 同一份配置（含授权状态）
        let reloaded = ProviderHub(fileURL: file, transport: failing)
        XCTAssertEqual(reloaded.current, hub.current)
        XCTAssertTrue(reloaded.egress.allowsRemote)

        // 全部探测失败 → 降级：没有可用 embedder（搜索不受影响）
        _ = await reloaded.probeAll()
        XCTAssertNil(reloaded.availableTextEmbedder())
        XCTAssertEqual(reloaded.lastProbe(id: "ollama"), .unavailable(.unreachable(URLError(.cannotConnectToHost).localizedDescription)))

        // 传输恢复 → 探测可用 → 降级入口给出 provider；关闭外发后远端立即失效、回环仍可用
        let healthy = ProviderHub(fileURL: file, transport: MockTransport { MockTransport.embedding([0.5, 0.5], for: $0) })
        _ = await healthy.probeAll()
        XCTAssertNotNil(healthy.availableTextEmbedder())
        try healthy.setAllowRemoteEgress(false)
        XCTAssertEqual(healthy.availableTextEmbedder()?.id, "ollama", "远端被外发门拦下，仅本机回环可用")
        XCTAssertNil(healthy.lastProbe(id: "cloud"), "关闭外发后远端探测结果作废")
        try healthy.remove(id: "ollama")
        XCTAssertNil(healthy.availableTextEmbedder())
    }

    /// 图片向量须显式声明约定；请求体为 [{"image": data URL}]；探测用 1×1 PNG 实测验证；超限不发。
    func testImageEmbeddingRequiresDeclarationAndIsVerifiedByProbe() async throws {
        let transport = MockTransport { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            if let list = body?["input"] as? [[String: Any]], let image = list.first?["image"] as? String {
                XCTAssertTrue(image.hasPrefix("data:image/png;base64,"), image.prefix(40).description)
                return MockTransport.embedding([9, 9], for: request)
            }
            return MockTransport.embedding([1, 2], for: request)
        }
        var config = loopbackConfig()
        config.imageInput = .dataURL
        let provider = HTTPEmbeddingProvider(config: config, egress: ContentEgressPolicy(), transport: transport)
        XCTAssertTrue(provider.capabilities.embedImage, "显式声明先登记为能力")
        let probe = await provider.probe()
        guard case .available(_, let caps) = probe else { return XCTFail("\(probe)") }
        XCTAssertTrue(caps.embedImage, "1×1 PNG 实测通过才确认")
        XCTAssertEqual(transport.requests.count, 2, "探测 = 文本 ping + 图片 ping")
        let file = home.appendingPathComponent("x.png")
        try HTTPEmbeddingProvider.probePNG.write(to: file)
        let vector = try await provider.embedImage(at: file)
        XCTAssertEqual(vector, [9, 9])

        var tiny = config
        tiny.maxImageBytes = 10
        let limited = HTTPEmbeddingProvider(config: tiny, egress: ContentEgressPolicy(), transport: transport)
        do { _ = try await limited.embedImage(at: file); XCTFail("超限应拒发") }
        catch { guard case .unsupported = ProviderError.classify(error) else { return XCTFail("\(error)") } }
    }

    /// 声明≠能力：服务端对图片实测失败 → 能力降为仅文本，文本探测仍可用。
    func testProbeDowngradesImageCapabilityWhenServerRejectsImages() async throws {
        let transport = MockTransport { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            if body?["input"] is [[String: Any]] { return (Data("boom".utf8), MockTransport.response(500, for: request)) }
            return MockTransport.embedding([1, 2, 3], for: request)
        }
        var config = loopbackConfig()
        config.imageInput = .dataURL
        let provider = HTTPEmbeddingProvider(config: config, egress: ContentEgressPolicy(), transport: transport)
        let probe = await provider.probe()
        guard case .available(_, let caps) = probe else { return XCTFail("\(probe)") }
        XCTAssertFalse(caps.embedImage, "实测失败即降级，不按声明虚报")
        XCTAssertEqual(caps.dimensions, 3)

        // 旧版配置（无 imageInput 字段）解码回落 unsupported——持久化向前兼容
        let legacy = Data("""
        {"id":"old","displayName":"旧","endpoint":"http://127.0.0.1:1/v1/embeddings","model":"m"}
        """.utf8)
        let decoded = try JSONDecoder().decode(HTTPEmbeddingProvider.Config.self, from: legacy)
        XCTAssertEqual(decoded.imageInput, .unsupported)
        XCTAssertEqual(decoded.timeoutSeconds, 30)
    }

    /// 批量多图（2026-10-21 WeMM 实测 2.5~2.9x）：探测以 2×1×1 PNG 实测确认能力（声明≠能力）；
    /// 数量不符=服务端异常，按环境类整批重试不终态废图；旧配置解码 maxBatchImages 回落 nil。
    func testBatchEmbeddingProbeVerifyRoundtripAndCountMismatch() async throws {
        // 服务端按 input 数量返回向量（OpenAI 形状）
        let transport = MockTransport { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            if let list = body?["input"] as? [[String: Any]] {
                let data: [[String: Any]] = list.enumerated().map { index, _ in ["embedding": [0.5, 0.5, 0.5], "index": index] }
                let json: [String: Any] = ["data": data]
                return (try! JSONSerialization.data(withJSONObject: json), MockTransport.response(200, for: request))
            }
            return MockTransport.embedding([1, 2, 3], for: request)
        }
        var config = loopbackConfig()
        config.imageInput = .dataURL
        config.maxBatchImages = 8
        let provider = HTTPEmbeddingProvider(config: config, egress: ContentEgressPolicy(), transport: transport)
        let probe = await provider.probe()
        guard case .available(_, let caps) = probe else { return XCTFail("\(probe)") }
        XCTAssertEqual(caps.batchImages, 8, "2 图批量实测通过 → 能力=声明上限")
        XCTAssertEqual(caps.embedImage, true)
        XCTAssertEqual(transport.requests.count, 3, "探测 = 文本 ping + 单图 + 2 图批量")
        let vectors = try await provider.embedImagesData([(data: HTTPEmbeddingProvider.probePNG, mime: "image/png"),
                                                          (data: HTTPEmbeddingProvider.probePNG, mime: "image/png")])
        XCTAssertEqual(vectors.count, 2)
        XCTAssertEqual(vectors.first, [0.5, 0.5, 0.5])

        // 截断服务端：2 图只回 1 向量 → 探测降级回串行；直接调用抛环境类（整批可重试）
        let truncating = MockTransport { MockTransport.embedding([1, 2, 3], for: $0) }
        let truncProvider = HTTPEmbeddingProvider(config: config, egress: ContentEgressPolicy(), transport: truncating)
        _ = await truncProvider.probe()
        XCTAssertEqual(truncProvider.capabilities.batchImages, 0, "数量不符即降级，不按声明虚报")
        XCTAssertEqual(truncProvider.capabilities.embedImage, true, "单图能力不受影响")
        do {
            _ = try await truncProvider.embedImagesData([(data: HTTPEmbeddingProvider.probePNG, mime: "image/png"),
                                                         (data: HTTPEmbeddingProvider.probePNG, mime: "image/png")])
            XCTFail("数量不符应抛错")
        } catch {
            let classified = ProviderError.classify(error)
            XCTAssertEqual(classified, .server(500))
            XCTAssertTrue(classified.isTransient, "截断是服务端异常，整批留队重试")
        }

        // 旧版配置（无 maxBatchImages 字段）解码回落 nil——持久化向前兼容
        let legacy = Data("""
        {"id":"old","displayName":"旧","endpoint":"http://127.0.0.1:1/v1/embeddings","model":"m","imageInput":"dataURL"}
        """.utf8)
        XCTAssertNil(try JSONDecoder().decode(HTTPEmbeddingProvider.Config.self, from: legacy).maxBatchImages)
    }

    /// ASR 合同：带时间戳文本复用 TimedText（与视频帧 OCR 同一落库通道）；fake 实现即可满足合同。
    func testASRContractWithFakeProvider() async throws {
        final class FakeASR: ASRProvider, @unchecked Sendable {
            let id = "fake-asr", displayName = "本机 Whisper（假）"
            let capabilities = ProviderCapabilities(transcribeAudio: true, model: "whisper-small")
            func probe() async -> ProviderProbe { .available(latencyMs: 1, capabilities: capabilities) }
            func transcribe(audioAt url: URL) async throws -> [TimedText] {
                [TimedText(startMs: 0, endMs: 2500, text: "大家好"), TimedText(startMs: 2500, endMs: 6000, text: "今天讲第一章")]
            }
        }
        let asr = FakeASR()
        let probe = await asr.probe()
        XCTAssertTrue(probe.isAvailable)
        let segments = try await asr.transcribe(audioAt: URL(fileURLWithPath: "/tmp/a.m4a"))
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[1].startMs, 2500)
        XCTAssertTrue(asr.capabilities.transcribeAudio)
        XCTAssertFalse(asr.capabilities.embedText)
    }

    /// 发送端点白名单：只认带主机的 http(s)，且地址内不得内嵌凭据。
    /// `file://` 不是网络端点；`https://user:pass@host` 会把凭据带进状态卡/日志链路。
    func testEgressRejectsNonHTTPAndCredentialedEndpoints() {
        let authorized = ContentEgressPolicy(allowRemote: true)
        XCTAssertTrue(authorized.permits(URL(string: "https://api.example.com/v1/embeddings")!))
        XCTAssertTrue(authorized.permits(URL(string: "http://127.0.0.1:11434/v1/embeddings")!))
        XCTAssertFalse(authorized.permits(URL(string: "file:///etc/passwd")!), "非网络 scheme 不是发送端点")
        XCTAssertFalse(authorized.permits(URL(string: "https://user:secret@api.example.com/v1/embeddings")!),
                       "内嵌凭据不得进入发送链路")
        XCTAssertFalse(ContentEgressPolicy().permits(URL(string: "https://api.example.com/v1/embeddings")!),
                       "未授权远端仍然拒绝")
    }

    /// providers.json 只含引用名，也仍是本机配置：仅属主可读。
    func testProviderConfigurationIsOwnerReadableOnly() throws {
        let file = home.appendingPathComponent("providers.json")
        let hub = ProviderHub(fileURL: file, transport: MockTransport { _ in throw URLError(.badURL) })
        try hub.addHTTPEmbedding(loopbackConfig())
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    /// 改端点/模型后必须丢弃旧探测结论：否则新地址会在“已可用”的假象下直接收到内容。
    func testEditingProviderInvalidatesCachedProbe() async throws {
        let hub = ProviderHub(fileURL: home.appendingPathComponent("providers.json"),
                              transport: MockTransport { MockTransport.embedding([0.1, 0.2], for: $0) })
        try hub.addHTTPEmbedding(loopbackConfig())
        _ = await hub.probeAll()
        XCTAssertNotNil(hub.lastProbe(id: "ollama"))
        try hub.updateHTTPEmbedding(id: "ollama") { $0.endpoint = URL(string: "http://127.0.0.1:11435/v1/embeddings")! }
        XCTAssertNil(hub.lastProbe(id: "ollama"), "换端点后必须先重探才能再发送")
    }

    /// 内网明文 HTTP 是受支持场景：授权后照常发送。安全边界是「显式授权 + 回环例外」，不是强制 HTTPS。
    func testLANHTTPRemoteRemainsUsableWithAuthorization() async throws {
        let config = HTTPEmbeddingProvider.Config(
            id: "lan", displayName: "校园网 GPU",
            endpoint: URL(string: "http://192.168.1.20:8000/v1/embeddings")!, model: "weemm")
        let transport = MockTransport { MockTransport.embedding([0.3, 0.7], for: $0) }

        let denied = HTTPEmbeddingProvider(config: config, egress: ContentEgressPolicy(), transport: transport)
        do { _ = try await denied.embedText("x"); XCTFail("未授权应拒绝") }
        catch { XCTAssertEqual(ProviderError.classify(error), .egressDenied) }
        XCTAssertTrue(transport.requests.isEmpty)

        let allowed = HTTPEmbeddingProvider(config: config, egress: ContentEgressPolicy(allowRemote: true), transport: transport)
        let vector = try await allowed.embedText("x")
        XCTAssertEqual(vector.count, 2)
        XCTAssertEqual(transport.requests.count, 1)
    }

    /// 重定向：同主机改路径/端口/http→https 放行；跨主机一律阻断（307/308 会带走请求正文）。
    func testRedirectPolicyOnlyAllowsSameHost() {
        let original = URL(string: "http://192.168.1.20:8000/v1/embeddings")!
        XCTAssertTrue(ContentEgressPolicy.mayFollowRedirect(
            from: original, to: URL(string: "http://192.168.1.20:8000/v2/embeddings")!))
        XCTAssertTrue(ContentEgressPolicy.mayFollowRedirect(
            from: original, to: URL(string: "https://192.168.1.20/v1/embeddings")!))
        XCTAssertFalse(ContentEgressPolicy.mayFollowRedirect(
            from: original, to: URL(string: "http://evil.example.com/collect")!))
        XCTAssertFalse(ContentEgressPolicy.mayFollowRedirect(
            from: original, to: URL(string: "file:///etc/passwd")!))
    }
}
