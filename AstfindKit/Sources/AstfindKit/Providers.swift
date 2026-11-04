import Foundation

// MARK: - A1 Provider 协议骨架（A2 图片语义 / V1 视频 ASR 的共同地基）
//
// 第一性原理：
// 1. 无 Provider 必须零影响——本地文件名/内容搜索是主体，AI 是增强（决策 #1）。Hub 为空=一切照旧。
// 2. 能力显式声明且可探测——"兼容 OpenAI/Ollama" 不等于支持图片/视频（PRD §4.2）。
// 3. 外发 = 内容上传（决策 #7）：默认拒绝，显式授权才放行；仅本机回环视为本地推理不外发。
// 4. 合同可注入 fake——传输层/密钥解析/探测全部可替换，行为级测试不依赖真模型与网络。

/// 能力声明：配置声明为起点，探测后以实测为准（维度/模型）。
public struct ProviderCapabilities: Equatable, Sendable, Codable {
    public var embedText: Bool
    public var embedImage: Bool
    public var embedVideoFrames: Bool
    public var transcribeAudio: Bool
    /// 向量维度（探测后填充；未知为 nil）
    public var dimensions: Int?
    public var model: String?
    /// 单请求多图批量的上限（0=不支持；探测以 2 图实测确认——声明≠能力）。
    /// WeMM 实测（2026-10-21）：批量 32 ≈ 3.4 图/s vs 串行 4 并发 1.15 图/s，GPU 批处理 2.5~2.9x。
    public var batchImages: Int
    public init(embedText: Bool = false, embedImage: Bool = false, embedVideoFrames: Bool = false,
                transcribeAudio: Bool = false, dimensions: Int? = nil, model: String? = nil,
                batchImages: Int = 0) {
        self.embedText = embedText; self.embedImage = embedImage; self.embedVideoFrames = embedVideoFrames
        self.transcribeAudio = transcribeAudio; self.dimensions = dimensions; self.model = model
        self.batchImages = batchImages
    }
}

/// 失败分类——决定降级策略：
/// 配置类（egressDenied/unauthorized/unsupported）不重试、提示用户；
/// 环境类（unreachable/timeout/server/quota）退避后重探；cancelled 静默。
public enum ProviderError: Error, Equatable, Sendable {
    case egressDenied
    case unreachable(String)
    case timeout
    case unauthorized
    case quotaExceeded
    case unsupported(String)
    case invalidResponse(String)
    case server(Int)
    case cancelled

    /// 是否值得稍后重探（环境类）；配置类返回 false。
    public var isTransient: Bool {
        switch self {
        case .unreachable, .timeout, .server, .quotaExceeded: return true
        case .egressDenied, .unauthorized, .unsupported, .invalidResponse, .cancelled: return false
        }
    }

    /// 任意错误 → 分类（URLError/CancellationError 映射；已分类的原样返回）。
    public static func classify(_ error: Error) -> ProviderError {
        if let classified = error as? ProviderError { return classified }
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return .timeout
            case .cancelled: return .cancelled
            default: return .unreachable(urlError.localizedDescription)
            }
        }
        return .unreachable("\(error)")
    }

    /// HTTP 状态码 → 分类（2xx 返回 nil）。
    public static func classify(status: Int) -> ProviderError? {
        switch status {
        case 200..<300: return nil
        case 401, 403: return .unauthorized
        case 404: return .unsupported("endpoint 404")
        case 429: return .quotaExceeded
        case 500...: return .server(status)
        default: return .invalidResponse("HTTP \(status)")
        }
    }
}

public enum ProviderProbe: Equatable, Sendable {
    case available(latencyMs: Int, capabilities: ProviderCapabilities)
    case unavailable(ProviderError)
    public var isAvailable: Bool { if case .available = self { return true } else { return false } }
}

/// 向量 Provider 合同（最小集）：能力探测 + embedText；embedImage 可选（默认 unsupported）。
/// 全部 async：取消走 Task 取消（协作式），超时由实现按配置落实。
public protocol EmbeddingProvider: AnyObject, Sendable {
    var id: String { get }
    var displayName: String { get }
    var capabilities: ProviderCapabilities { get }
    func probe() async -> ProviderProbe
    func embedText(_ text: String) async throws -> [Float]
    func embedImage(at url: URL) async throws -> [Float]
    /// 内存图像数据（A2 入库前本地下采样后的缩略图——隐私最小化，发的不是原图）
    func embedImageData(_ data: Data, mime: String) async throws -> [Float]
    /// 批量多图单请求（入库泵提吞吐）：默认回退为逐图串行——自定义 Provider 无需实现。
    func embedImagesData(_ batch: [(data: Data, mime: String)]) async throws -> [[Float]]
}
public extension EmbeddingProvider {
    func embedImage(at url: URL) async throws -> [Float] { throw ProviderError.unsupported("embedImage") }
    func embedImageData(_ data: Data, mime: String) async throws -> [Float] { throw ProviderError.unsupported("embedImage") }
    func embedImagesData(_ batch: [(data: Data, mime: String)]) async throws -> [[Float]] {
        var vectors: [[Float]] = []; vectors.reserveCapacity(batch.count)
        for image in batch { vectors.append(try await embedImageData(image.data, mime: image.mime)) }
        return vectors
    }
}

/// ASR 合同：音轨 → 带时间戳文本（复用 TimedText，与视频帧 OCR 同一落库通道；V1 地基）。
public protocol ASRProvider: AnyObject, Sendable {
    var id: String { get }
    var displayName: String { get }
    var capabilities: ProviderCapabilities { get }
    func probe() async -> ProviderProbe
    func transcribe(audioAt url: URL) async throws -> [TimedText]
}

// MARK: - 外发授权（隐私红线）

/// 任何媒体帧/语音/文本发往非本机地址均为内容上传。默认拒绝；本机回环（127.0.0.1/localhost/::1）
/// 视为本地推理不外发，始终放行。授权由用户显式开启并持久化。
public final class ContentEgressPolicy: @unchecked Sendable {
    private let lock = NSLock()
    private var allowRemote: Bool
    public init(allowRemote: Bool = false) { self.allowRemote = allowRemote }
    public var allowsRemote: Bool {
        get { lock.lock(); defer { lock.unlock() }; return allowRemote }
        set { lock.lock(); allowRemote = newValue; lock.unlock() }
    }
    public func permits(_ url: URL) -> Bool {
        Self.isSendableEndpoint(url) && (Self.isLoopback(url) || allowsRemote)
    }
    public static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
    }
    /// 端点白名单：只接受带主机的 http(s)，且 URL 内不得内嵌凭据。
    /// `file://` 等非网络 scheme 与 `https://user:pass@host` 一律视为不可发送
    /// （前者会把本地文件当响应读回，后者会把凭据写进状态卡/日志链路）。
    public static func isSendableEndpoint(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return false }
        return true
    }
    /// 重定向只允许回到**同一个主机**。
    ///
    /// 反代改路径、http→https、端口迁移都照常跟随；但跨主机一律拒绝——307/308 会原样转发
    /// 请求正文（用户的图片/查询），一次跨主机跳转就等于把内容发给了另一个端点，
    /// 绕开「本地模式零外发」和「远端只发已授权端点」的边界。
    public static func mayFollowRedirect(from original: URL?, to target: URL?) -> Bool {
        guard let originalHost = original?.host?.lowercased(), !originalHost.isEmpty,
              let target, let targetHost = target.host?.lowercased(), targetHost == originalHost,
              isSendableEndpoint(target) else { return false }
        return true
    }
}

// MARK: - 可注入传输与密钥解析

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public final class URLSessionTransport: HTTPTransport {
    private let session: URLSession
    public init(timeout: TimeInterval = 30) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        // 跨主机重定向绝不跟随：请求体是用户的图片/查询文本，一个 307/308 就能把它转给另一台主机，
        // 绕开「本地模式零外发」和「远端只发已授权端点」的边界。同主机（改路径/端口/http→https）照常放行。
        session = URLSession(configuration: config, delegate: ProviderRedirectPolicy(), delegateQueue: nil)
    }
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse("non-HTTP response") }
        return (data, http)
    }
}

/// 同主机重定向策略（与 UpdateClient 的“不跨主机”原则一致）：端点只能收到发往它自己主机的请求。
private final class ProviderRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let allowed = ContentEgressPolicy.mayFollowRedirect(from: task.originalRequest?.url, to: request.url)
        completionHandler(allowed ? request : nil)
    }
}

/// 密钥按引用名解析（绝不存明文）。默认实现读环境变量 ASTFIND_SECRET_<ref>；钥匙串适配器后续加。
public protocol SecretResolving: Sendable {
    func secret(named ref: String) -> String?
}
public struct EnvironmentSecretResolver: SecretResolving {
    public init() {}
    public func secret(named ref: String) -> String? {
        ProcessInfo.processInfo.environment["ASTFIND_SECRET_" + ref]
    }
}

// MARK: - HTTP 参考实现（OpenAI 兼容 /v1/embeddings：Ollama/LM Studio/vLLM/第三方 API 同款）

/// 文本向量恒声明；图片向量须**显式配置输入约定**并经探测实测（1×1 PNG）确认——
/// 不把"兼容 OpenAI"误当成多模态。WeMM 实测约定：`input: [{"image": "data:<mime>;base64,…"}]`。
public final class HTTPEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
    /// 图片输入约定（服务端各异，必须显式声明）。
    public enum ImageInput: String, Codable, Equatable, Sendable {
        /// 不支持图片（默认）
        case unsupported
        /// `[{"image": "data:image/png;base64,..."}]`（WeMM 实测；同时接受纯字符串 data URL）
        case dataURL
    }
    public struct Config: Codable, Equatable, Sendable {
        public var id: String
        public var displayName: String
        public var endpoint: URL
        public var model: String
        /// 密钥引用名（SecretResolving 解析）；nil=无鉴权（本机推理常见）
        public var apiKeyRef: String?
        public var timeoutSeconds: TimeInterval
        /// 图片输入约定；缺省 unsupported（旧配置解码时同样回落 unsupported）
        public var imageInput: ImageInput
        /// 单图上限（字节）；超限不发（保护网络与服务端，A2 再做本地缩放）
        public var maxImageBytes: Int
        /// 单请求多图上限（nil/1=串行；>1 需探测实测确认，能力以探测为准）。WeMM 实测甜点 32。
        public var maxBatchImages: Int?
        public init(id: String, displayName: String, endpoint: URL, model: String,
                    apiKeyRef: String? = nil, timeoutSeconds: TimeInterval = 30,
                    imageInput: ImageInput = .unsupported, maxImageBytes: Int = 8_000_000,
                    maxBatchImages: Int? = nil) {
            self.id = id; self.displayName = displayName; self.endpoint = endpoint
            self.model = model; self.apiKeyRef = apiKeyRef; self.timeoutSeconds = timeoutSeconds
            self.imageInput = imageInput; self.maxImageBytes = maxImageBytes; self.maxBatchImages = maxBatchImages
        }
        enum CodingKeys: String, CodingKey { case id, displayName, endpoint, model, apiKeyRef, timeoutSeconds, imageInput, maxImageBytes, maxBatchImages }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            displayName = try c.decode(String.self, forKey: .displayName)
            endpoint = try c.decode(URL.self, forKey: .endpoint)
            model = try c.decode(String.self, forKey: .model)
            apiKeyRef = try c.decodeIfPresent(String.self, forKey: .apiKeyRef)
            timeoutSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .timeoutSeconds) ?? 30
            imageInput = try c.decodeIfPresent(ImageInput.self, forKey: .imageInput) ?? .unsupported
            maxImageBytes = try c.decodeIfPresent(Int.self, forKey: .maxImageBytes) ?? 8_000_000
            maxBatchImages = try c.decodeIfPresent(Int.self, forKey: .maxBatchImages)
        }
    }

    public let config: Config
    private let egress: ContentEgressPolicy
    private let transport: HTTPTransport
    private let secrets: SecretResolving
    private let lock = NSLock()
    private var probed: ProviderCapabilities

    public init(config: Config, egress: ContentEgressPolicy, transport: HTTPTransport,
                secrets: SecretResolving = EnvironmentSecretResolver()) {
        self.config = config; self.egress = egress; self.transport = transport; self.secrets = secrets
        self.probed = ProviderCapabilities(embedText: true, embedImage: config.imageInput != .unsupported, model: config.model)
    }

    public var id: String { config.id }
    public var displayName: String { config.displayName }
    public var capabilities: ProviderCapabilities { lock.lock(); defer { lock.unlock() }; return probed }

    /// 探测 = 真发一次最小 embed（"ping"）验证连通/鉴权/格式并以实测维度更新能力；
    /// 声明了图片约定时再发一张 1×1 PNG——失败即把 embedImage 降为 false（能力以实测为准）。
    /// 声明了批量（maxBatchImages>1）时再发 2×1×1 PNG 批量——数量/维度不符即降回串行。
    public func probe() async -> ProviderProbe {
        let began = Date()
        do {
            let vector = try await embedText("ping")
            var imageOK = false
            if config.imageInput != .unsupported {
                if let image = try? await postImage(Self.probePNG, mime: "image/png"), image.count == vector.count {
                    imageOK = true
                }
            }
            var batchOK = false
            if imageOK, (config.maxBatchImages ?? 1) > 1 {
                batchOK = (try? await embedImagesData([(data: Self.probePNG, mime: "image/png"),
                                                        (data: Self.probePNG, mime: "image/png")]))
                    .map { $0.count == 2 && $0.allSatisfy { $0.count == vector.count } } ?? false
            }
            let latency = Int(Date().timeIntervalSince(began) * 1000)
            setProbed(dimensions: vector.count, embedImage: imageOK,
                      batchImages: batchOK ? (config.maxBatchImages ?? 1) : 0)
            return .available(latencyMs: latency, capabilities: capabilities)
        } catch {
            return .unavailable(ProviderError.classify(error))
        }
    }

    /// 锁操作收敛在同步方法内（async 上下文直接持锁在 Swift 6 是错误）。
    private func setProbed(dimensions: Int, embedImage: Bool, batchImages: Int = 0) {
        lock.lock(); probed.dimensions = dimensions; probed.embedImage = embedImage; probed.batchImages = batchImages; lock.unlock()
    }

    public func embedText(_ text: String) async throws -> [Float] {
        try await post(input: text)
    }

    public func embedImage(at url: URL) async throws -> [Float] {
        guard config.imageInput != .unsupported else { throw ProviderError.unsupported("embedImage") }
        let data = try Data(contentsOf: url)
        guard data.count <= config.maxImageBytes else {
            throw ProviderError.unsupported("image too large (\(data.count) > \(config.maxImageBytes) bytes)")
        }
        return try await postImage(data, mime: Self.mime(for: url))
    }

    private func postImage(_ data: Data, mime: String) async throws -> [Float] {
        let dataURL = "data:\(mime);base64," + data.base64EncodedString()
        switch config.imageInput {
        case .dataURL: return try await post(input: [["image": dataURL]])
        case .unsupported: throw ProviderError.unsupported("embedImage")
        }
    }
    public func embedImageData(_ data: Data, mime: String) async throws -> [Float] {
        guard config.imageInput != .unsupported else { throw ProviderError.unsupported("embedImage") }
        guard data.count <= config.maxImageBytes else {
            throw ProviderError.unsupported("image too large (\(data.count) > \(config.maxImageBytes) bytes)")
        }
        return try await postImage(data, mime: mime)
    }

    public func embedImagesData(_ batch: [(data: Data, mime: String)]) async throws -> [[Float]] {
        guard !batch.isEmpty else { return [] }
        guard config.imageInput != .unsupported else { throw ProviderError.unsupported("embedImage") }
        for image in batch where image.data.count > config.maxImageBytes {
            throw ProviderError.unsupported("image too large (\(image.data.count) > \(config.maxImageBytes) bytes)")
        }
        // 请求体 = N 张 data URL（WeMM 实测约定与单图一致，input 直接放列表元素）
        let input = try batch.map { image -> [String: Any] in
            ["image": "data:\(image.mime);base64," + image.data.base64EncodedString()]
        }
        let vectors = try await postRaw(input: input, extraTimeout: TimeInterval(batch.count) * 2)
        let parsed = try Self.parseEmbeddings(vectors)
        // 数量不符=服务端异常（截断/合并）——按环境类处理整批重试，不终态废图
        guard parsed.count == batch.count else { throw ProviderError.server(500) }
        return parsed
    }

    private func post(input: Any) async throws -> [Float] {
        let raw = try await postRaw(input: input)
        guard let first = try Self.parseEmbeddings(raw).first else {
            throw ProviderError.invalidResponse("no embedding in response")
        }
        return first
    }

    /// POST /v1/embeddings 原始返回（JSON body）。extraTimeout 为批量请求的追加预算（每图 +2s）。
    private func postRaw(input: Any, extraTimeout: TimeInterval = 0) async throws -> Data {
        guard egress.permits(config.endpoint) else { throw ProviderError.egressDenied }
        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = min(600, config.timeoutSeconds + extraTimeout)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let ref = config.apiKeyRef, let key = secrets.secret(named: ref) {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": config.model, "input": input])
        try Task.checkCancellation()
        let (data, response): (Data, HTTPURLResponse)
        do { (data, response) = try await transport.send(request) }
        catch { throw ProviderError.classify(error) }
        if let failure = ProviderError.classify(status: response.statusCode) { throw failure }
        return data
    }

    static func mime(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "heic": return "image/heic"
        case "tiff", "tif": return "image/tiff"
        case "bmp": return "image/bmp"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "image/png"
        }
    }

    /// 1×1 不透明 PNG（能力探测用；67 字节）
    static let probePNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==")!

    /// `{"data":[{"embedding":[...]}]}`（OpenAI 兼容）；兼容 Ollama 原生 `{"embedding":[...]}`。
    static func parseEmbedding(_ data: Data) throws -> [Float] {
        guard let first = try parseEmbeddings(data).first else {
            throw ProviderError.invalidResponse("no embedding in response")
        }
        return first
    }

    /// 批量解析：`{"data":[{"embedding":[…]},{"embedding":[…]},…]}`；兼容裸向量列表 `{"data":[[…],[…]]}`。
    /// 单向量形状（Ollama 原生）在批量语境下解析为空——数量校验由调用方做。
    static func parseEmbeddings(_ data: Data) throws -> [[Float]] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.invalidResponse("not a JSON object")
        }
        var rawVectors: [[Any]] = []
        if let list = json["data"] as? [[String: Any]] {
            rawVectors = list.compactMap { $0["embedding"] as? [Any] }
        } else if let list = json["data"] as? [[Any]] {
            rawVectors = list
        } else if let single = json["embedding"] as? [Any] {
            rawVectors = [single]   // Ollama 原生单向量形状（单图/文本请求）
        }
        guard !rawVectors.isEmpty else { throw ProviderError.invalidResponse("no embedding in response") }
        return try rawVectors.map { numbers in
            let vector = numbers.compactMap { ($0 as? NSNumber)?.floatValue }
            guard !vector.isEmpty, vector.count == numbers.count else {
                throw ProviderError.invalidResponse("non-numeric embedding")
            }
            return vector
        }
    }
}

// MARK: - 语义模型模式（关闭 / 远程 / 本地）

/// 用户对「语义模型从哪来」的显式选择。
///
/// 第一性原理：模式不是 UI 装饰，而是**发送边界**——
/// - `off`：语义通道整体关闭（不注册图片 Provider）；文件名/OCR/正文不受影响。
/// - `remote`：只允许非本机端点；即便如此仍需外发授权（`ContentEgressPolicy`）才发得出请求。
/// - `local`：只允许本机回环（127.0.0.1/localhost/::1），**永不外发**——比"外发授权"更强的承诺。
///
/// 旧配置没有该字段（`nil`）：沿用既有「第一个已配置 Provider」行为，绝不改变现有用户。
public enum SemanticMode: String, Codable, Sendable, CaseIterable {
    case off, remote, local

    public var displayName: String {
        switch self {
        case .off: return "关闭"
        case .remote: return "远程"
        case .local: return "本地"
        }
    }
}

// MARK: - Hub：配置持久化 + 探测结果 + 降级

/// 全部 Provider 的登记处。配置落 ASTFIND_HOME/providers.json（密钥只存引用名）。
/// 降级语义：取最近探测可用者；没有 → nil，调用方走无向量路径（搜索永不因 Provider 阻塞）。
public final class ProviderHub: @unchecked Sendable {
    public struct Configuration: Codable, Equatable, Sendable {
        public var httpEmbeddings: [HTTPEmbeddingProvider.Config] = []
        public var allowRemoteEgress: Bool = false
        /// 语义模型模式；`nil` = 旧配置未选择（按现有 Provider 推断，行为不变）
        public var semanticMode: SemanticMode?
        public init(httpEmbeddings: [HTTPEmbeddingProvider.Config] = [], allowRemoteEgress: Bool = false,
                    semanticMode: SemanticMode? = nil) {
            self.httpEmbeddings = httpEmbeddings; self.allowRemoteEgress = allowRemoteEgress
            self.semanticMode = semanticMode
        }
    }

    /// 语义模型的当前状态（只读缓存快照，**绝不触发探测**——设置页每次重绘都可安全调用）。
    public struct SemanticStatus: Equatable, Sendable {
        public let mode: SemanticMode
        /// true = 旧配置未显式选择模式（按现有 Provider 的性质推断）
        public let inferred: Bool
        public let providerId: String?
        public let displayName: String?
        public let endpoint: URL?
        public let model: String?
        public let isLoopback: Bool
        /// 外发授权当前是否开启（仅对 remote 有意义）
        public let egressAuthorized: Bool
        /// 最近一次探测结果（cached；nil = 本次进程还没探测过）
        public let probe: ProviderProbe?
        /// 当前模式下的候选 Provider 数（remote=远端端点，local=回环端点）
        public let candidateCount: Int
        public var isConfigured: Bool { providerId != nil }
    }

    public let fileURL: URL
    public let egress: ContentEgressPolicy
    private let transport: HTTPTransport
    private let secrets: SecretResolving
    private let lock = NSLock()
    private var configuration: Configuration
    private var embedders: [HTTPEmbeddingProvider] = []
    /// 进程内注入的 Provider（本地模型 / 测试假体）：不落盘、rebuild 不清除。
    private var extraEmbedders: [EmbeddingProvider] = []
    private var probes: [String: ProviderProbe] = [:]

    public init(fileURL: URL, transport: HTTPTransport = URLSessionTransport(),
                secrets: SecretResolving = EnvironmentSecretResolver()) {
        self.fileURL = fileURL; self.transport = transport; self.secrets = secrets
        let loaded = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode(Configuration.self, from: $0) }
        self.configuration = loaded ?? Configuration()
        self.egress = ContentEgressPolicy(allowRemote: configuration.allowRemoteEgress)
        rebuild()
    }

    public var current: Configuration { lock.lock(); defer { lock.unlock() }; return configuration }
    /// 全部已配置 Provider（高级列表/诊断用；不受语义模式影响）。
    public var embeddingProviders: [EmbeddingProvider] {
        lock.lock(); defer { lock.unlock() }
        return embedders + extraEmbedders
    }

    // MARK: 语义模型模式

    /// 当前生效模式：显式选择优先；旧配置按「第一个已配置 Provider 的端点性质」推断（无 → 关闭）。
    public func semanticMode() -> SemanticMode {
        lock.lock(); defer { lock.unlock() }
        return Self.effectiveMode(stored: configuration.semanticMode, embedders: embedders, extras: extraEmbedders)
    }

    /// 显式选择的模式（nil = 旧配置未选择）。
    public func storedSemanticMode() -> SemanticMode? {
        lock.lock(); defer { lock.unlock() }
        return configuration.semanticMode
    }

    /// 当前模式下允许参与语义检索的 Provider（按优先级）。
    /// 关闭 → 空；本地 → 只回环（进程内注入的 Provider 视为本地）；远程 → 只非回环。
    /// 旧配置 → 全部（与既有行为逐字一致）。这是「关闭不注册图片 Provider」的唯一开关。
    public func semanticEmbeddingProviders() -> [EmbeddingProvider] {
        lock.lock(); defer { lock.unlock() }
        return candidatesLocked()
    }

    /// 切换模式并持久化。**只写配置**：不探测、不启动入库（建向量是用户的显式动作）。
    public func setSemanticMode(_ mode: SemanticMode) throws {
        lock.lock(); configuration.semanticMode = mode; lock.unlock()
        try save()
    }

    /// 语义模型状态快照（缓存探测结果，不联网）。
    public func semanticStatus() -> SemanticStatus {
        lock.lock(); defer { lock.unlock() }
        let mode = Self.effectiveMode(stored: configuration.semanticMode, embedders: embedders, extras: extraEmbedders)
        let candidates = candidatesLocked()
        let first = candidates.first
        let config = (first as? HTTPEmbeddingProvider)?.config
        return SemanticStatus(
            mode: mode,
            inferred: configuration.semanticMode == nil,
            providerId: first?.id,
            displayName: first?.displayName,
            endpoint: config?.endpoint,
            model: config?.model ?? first?.capabilities.model,
            isLoopback: config.map { ContentEgressPolicy.isLoopback($0.endpoint) } ?? true,
            egressAuthorized: egress.allowsRemote,
            probe: first.flatMap { probes[$0.id] },
            candidateCount: candidates.count)
    }

    private func candidatesLocked() -> [EmbeddingProvider] {
        switch configuration.semanticMode {
        case .off:
            return []
        case .remote:
            return embedders.filter { !ContentEgressPolicy.isLoopback($0.config.endpoint) }
        case .local:
            return embedders.filter { ContentEgressPolicy.isLoopback($0.config.endpoint) } + extraEmbedders
        case nil:
            return embedders + extraEmbedders
        }
    }

    private static func effectiveMode(stored: SemanticMode?, embedders: [HTTPEmbeddingProvider],
                                      extras: [EmbeddingProvider]) -> SemanticMode {
        if let stored { return stored }
        if let first = embedders.first {
            return ContentEgressPolicy.isLoopback(first.config.endpoint) ? .local : .remote
        }
        return extras.isEmpty ? .off : .local
    }
    public func lastProbe(id: String) -> ProviderProbe? { lock.lock(); defer { lock.unlock() }; return probes[id] }
    /// 记录单个探测结果（引擎按需同步探测后回填）。
    public func record(probe: ProviderProbe, id: String) { lock.lock(); probes[id] = probe; lock.unlock() }
    /// 登记进程内 Provider（本地模型、测试假体）：仅本进程可见，不进 providers.json。
    public func addEmbeddingProvider(_ provider: EmbeddingProvider) {
        lock.lock(); extraEmbedders.append(provider); lock.unlock()
    }

    public func addHTTPEmbedding(_ config: HTTPEmbeddingProvider.Config) throws {
        lock.lock()
        configuration.httpEmbeddings.removeAll { $0.id == config.id }
        configuration.httpEmbeddings.append(config)
        probes[config.id] = nil   // 换了端点/模型：旧探测结论作废
        lock.unlock()
        rebuild(); try save()
    }
    /// 原地修改某个 HTTP Provider 配置（不存在则抛错）；重建实例并落盘。
    public func updateHTTPEmbedding(id: String, _ mutate: (inout HTTPEmbeddingProvider.Config) -> Void) throws {
        lock.lock()
        guard let index = configuration.httpEmbeddings.firstIndex(where: { $0.id == id }) else {
            lock.unlock(); throw ProviderError.invalidResponse("no provider \(id)")
        }
        mutate(&configuration.httpEmbeddings[index])
        probes[id] = nil   // 端点/维度可能已变：必须重新探测后才能再发内容
        lock.unlock()
        rebuild(); try save()
    }
    public func remove(id: String) throws {
        lock.lock()
        configuration.httpEmbeddings.removeAll { $0.id == id }
        probes[id] = nil
        lock.unlock()
        rebuild(); try save()
    }
    /// 外发授权开关（持久化）。关闭后远端 Provider 立即视为不可用（探测结果作废）。
    public func setAllowRemoteEgress(_ allowed: Bool) throws {
        lock.lock()
        configuration.allowRemoteEgress = allowed
        if !allowed { probes = probes.filter { id, _ in embedders.first { $0.id == id }.map { ContentEgressPolicy.isLoopback($0.config.endpoint) } ?? false } }
        lock.unlock()
        egress.allowsRemote = allowed
        try save()
    }

    /// 探测当前模式允许的 Provider（并发），记录结果供降级判断。
    ///
    /// **探测也是发送**（ping 文本 + 1×1 探针图）：因此只能探测 `semanticEmbeddingProviders()`
    /// 给出的候选。关闭模式一个请求都不发；本地模式摸不到远端，即便历史上开过外发授权。
    @discardableResult
    public func probeAll() async -> [String: ProviderProbe] {
        let targets = semanticEmbeddingProviders()
        var results: [String: ProviderProbe] = [:]
        await withTaskGroup(of: (String, ProviderProbe).self) { group in
            for provider in targets { group.addTask { (provider.id, await provider.probe()) } }
            for await (id, probe) in group { results[id] = probe }
        }
        recordProbes(results)
        return results
    }

    /// 锁操作收敛在同步方法内（async 上下文直接持锁在 Swift 6 是错误）。
    private func recordProbes(_ results: [String: ProviderProbe]) {
        lock.lock(); for (id, probe) in results { probes[id] = probe }; lock.unlock()
    }

    /// 降级入口：当前模式候选中最近探测可用且声明文本向量能力的第一个 Provider；无则 nil。
    /// 必须复用 `candidatesLocked()`——否则「关闭/本地」模式会从这条旁路拿到远端 Provider。
    public func availableTextEmbedder() -> EmbeddingProvider? {
        lock.lock(); defer { lock.unlock() }
        return candidatesLocked().first { provider in
            guard case .available(_, let caps)? = probes[provider.id] else { return false }
            let endpoint = (provider as? HTTPEmbeddingProvider)?.config.endpoint
            return caps.embedText && (endpoint.map { egress.permits($0) } ?? true)
        }
    }

    private func rebuild() {
        lock.lock(); defer { lock.unlock() }
        embedders = configuration.httpEmbeddings.map {
            HTTPEmbeddingProvider(config: $0, egress: egress, transport: transport, secrets: secrets)
        }
    }
    private func save() throws {
        let data = try JSONEncoder().encode(current)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try data.write(to: fileURL, options: .atomic)
        // 端点/模型名属本地配置：仅属主可读（与索引库同一隐私级别）
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
