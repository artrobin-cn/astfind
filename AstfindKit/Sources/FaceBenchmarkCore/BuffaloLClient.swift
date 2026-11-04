import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum BuffaloLFailureKind: String, Codable, Equatable, Sendable {
    case invalidConfiguration
    case insecureTransport
    case invalidInput
    case authentication
    case rateLimited
    case transient
    case timeout
    case permanent
    case malformedResponse
    case responseMismatch
    case dimensionMismatch
    case invalidVector
    case healthCheckFailed
}

public struct BuffaloLClientError: Error, Equatable, Sendable, CustomStringConvertible {
    public let kind: BuffaloLFailureKind
    public let statusCode: Int?

    public init(kind: BuffaloLFailureKind, statusCode: Int? = nil) {
        self.kind = kind
        self.statusCode = statusCode
    }

    public var description: String {
        if let statusCode {
            return "buffalo_l \(kind.rawValue) (HTTP \(statusCode))"
        }
        return "buffalo_l \(kind.rawValue)"
    }
}

public struct BuffaloLHealth: Codable, Equatable, Sendable {
    public let model: String
    public let dimension: Int

    public init(model: String, dimension: Int) {
        self.model = model
        self.dimension = dimension
    }
}

public struct BuffaloLRemoteConfiguration: Equatable, Sendable {
    public let endpoint: URL
    public let embedPath: String
    public let healthPath: String
    public let bearerToken: String?
    public let timeout: TimeInterval
    public let batchSize: Int
    public let maxAttempts: Int
    public let initialBackoff: TimeInterval
    public let expectedModel: String
    public let dimension: Int
    public let allowLoopbackHTTP: Bool

    public init(
        endpoint: URL,
        embedPath: String = "/v1/face/embed",
        healthPath: String = "/health",
        bearerToken: String? = nil,
        timeout: TimeInterval = 20,
        batchSize: Int = 8,
        maxAttempts: Int = 3,
        initialBackoff: TimeInterval = 0.25,
        expectedModel: String = "buffalo_l",
        dimension: Int = 512,
        allowLoopbackHTTP: Bool = false
    ) throws {
        let scheme = endpoint.scheme?.lowercased()
        guard let host = endpoint.host, !host.isEmpty else {
            throw BuffaloLClientError(kind: .invalidConfiguration)
        }
        if scheme == "http" {
            let loopback = host == "localhost" || host == "::1" || host.hasPrefix("127.")
            guard allowLoopbackHTTP, loopback else {
                throw BuffaloLClientError(kind: .insecureTransport)
            }
        } else if scheme != "https" {
            throw BuffaloLClientError(kind: .invalidConfiguration)
        }
        guard embedPath.hasPrefix("/"), healthPath.hasPrefix("/") else {
            throw BuffaloLClientError(kind: .invalidConfiguration)
        }
        guard timeout > 0, timeout.isFinite else {
            throw BuffaloLClientError(kind: .invalidConfiguration)
        }
        guard (1...64).contains(batchSize) else {
            throw BuffaloLClientError(kind: .invalidConfiguration)
        }
        guard (1...10).contains(maxAttempts) else {
            throw BuffaloLClientError(kind: .invalidConfiguration)
        }
        guard initialBackoff >= 0, initialBackoff.isFinite else {
            throw BuffaloLClientError(kind: .invalidConfiguration)
        }
        guard !expectedModel.isEmpty, dimension > 0 else {
            throw BuffaloLClientError(kind: .invalidConfiguration)
        }

        self.endpoint = endpoint
        self.embedPath = embedPath
        self.healthPath = healthPath
        self.bearerToken = bearerToken?.isEmpty == true ? nil : bearerToken
        self.timeout = timeout
        self.batchSize = batchSize
        self.maxAttempts = maxAttempts
        self.initialBackoff = initialBackoff
        self.expectedModel = expectedModel
        self.dimension = dimension
        self.allowLoopbackHTTP = allowLoopbackHTTP
    }

    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> BuffaloLRemoteConfiguration {
        guard let rawURL = environment["ASTFIND_FACE_BENCHMARK_REMOTE_URL"],
              !rawURL.isEmpty,
              let endpoint = URL(string: rawURL)
        else {
            throw BuffaloLClientError(kind: .invalidConfiguration)
        }
        func value(_ key: String) -> String? {
            guard let raw = environment[key], !raw.isEmpty else { return nil }
            return raw
        }
        func positiveInt(_ key: String, default fallback: Int) throws -> Int {
            guard let raw = value(key) else { return fallback }
            guard let parsed = Int(raw), parsed > 0 else {
                throw BuffaloLClientError(kind: .invalidConfiguration)
            }
            return parsed
        }
        func positiveDouble(_ key: String, default fallback: Double) throws -> Double {
            guard let raw = value(key) else { return fallback }
            guard let parsed = Double(raw), parsed > 0, parsed.isFinite else {
                throw BuffaloLClientError(kind: .invalidConfiguration)
            }
            return parsed
        }
        return try BuffaloLRemoteConfiguration(
            endpoint: endpoint,
            embedPath: value("ASTFIND_FACE_BENCHMARK_REMOTE_EMBED_PATH") ?? "/v1/face/embed",
            healthPath: value("ASTFIND_FACE_BENCHMARK_REMOTE_HEALTH_PATH") ?? "/health",
            bearerToken: value("ASTFIND_FACE_BENCHMARK_REMOTE_TOKEN"),
            timeout: try positiveDouble("ASTFIND_FACE_BENCHMARK_REMOTE_TIMEOUT_SECONDS", default: 20),
            batchSize: try positiveInt("ASTFIND_FACE_BENCHMARK_REMOTE_BATCH_SIZE", default: 8),
            maxAttempts: try positiveInt("ASTFIND_FACE_BENCHMARK_REMOTE_MAX_ATTEMPTS", default: 3),
            initialBackoff: try positiveDouble(
                "ASTFIND_FACE_BENCHMARK_REMOTE_BACKOFF_SECONDS",
                default: 0.25),
            expectedModel: value("ASTFIND_FACE_BENCHMARK_REMOTE_MODEL") ?? "buffalo_l",
            dimension: try positiveInt("ASTFIND_FACE_BENCHMARK_REMOTE_DIMENSION", default: 512),
            allowLoopbackHTTP: ["1", "true", "yes"].contains(
                (value("ASTFIND_FACE_BENCHMARK_REMOTE_ALLOW_LOOPBACK_HTTP") ?? "").lowercased()))
    }
}

public protocol FaceHTTPTransport {
    func send(_ request: URLRequest) throws -> (HTTPURLResponse, Data)
}

public final class URLSessionFaceHTTPTransport: FaceHTTPTransport {
    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    private let timeout: TimeInterval
    private let session: URLSession
    private let delegate: NoRedirectDelegate

    public init(timeout: TimeInterval) {
        self.timeout = timeout
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let delegate = NoRedirectDelegate()
        self.delegate = delegate
        self.session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil)
    }

    public func send(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<(HTTPURLResponse, Data), Error>?
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse {
                result = .success((http, data ?? Data()))
            } else {
                result = .failure(BuffaloLClientError(kind: .malformedResponse))
            }
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout + 5) == .timedOut {
            task.cancel()
            throw URLError(.timedOut)
        }
        guard let result else { throw BuffaloLClientError(kind: .malformedResponse) }
        return try result.get()
    }
}

private struct BuffaloLRequestEnvelope: Codable {
    let model: String
    let images: [BuffaloLRequestImage]
}

private struct BuffaloLRequestImage: Codable {
    let requestID: String
    let imageBase64: String

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case imageBase64 = "image_base64"
    }
}

private struct BuffaloLResponseEnvelope: Codable {
    let model: String
    let dimension: Int
    let embeddings: [BuffaloLResponseEmbedding]
}

private struct BuffaloLResponseEmbedding: Codable {
    let requestID: String
    let vector: [Double]

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case vector
    }
}

public final class BuffaloLClient {
    private let configuration: BuffaloLRemoteConfiguration
    private let transport: FaceHTTPTransport
    private let sleep: (TimeInterval) -> Void

    public init(
        configuration: BuffaloLRemoteConfiguration,
        transport: FaceHTTPTransport? = nil,
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.configuration = configuration
        self.transport = transport ?? URLSessionFaceHTTPTransport(timeout: configuration.timeout + 5)
        self.sleep = sleep
    }

    public var modelIdentifier: String { configuration.expectedModel }
    public var dimension: Int { configuration.dimension }

    public func health() throws -> BuffaloLHealth {
        let request = try makeRequest(method: "GET", path: configuration.healthPath, body: nil)
        let (response, data) = try perform(request)
        guard response.statusCode == 200 else {
            throw classify(statusCode: response.statusCode)
        }
        let health: BuffaloLHealth
        do {
            health = try JSONDecoder().decode(BuffaloLHealth.self, from: data)
        } catch {
            throw BuffaloLClientError(kind: .malformedResponse)
        }
        guard health.model == configuration.expectedModel,
              health.dimension == configuration.dimension
        else {
            throw BuffaloLClientError(kind: .healthCheckFailed)
        }
        return health
    }

    public func embed(images: [CGImage]) throws -> [[Float]] {
        guard !images.isEmpty else { return [] }
        guard images.allSatisfy({ $0.width == 112 && $0.height == 112 }) else {
            throw BuffaloLClientError(kind: .invalidInput)
        }
        var output: [[Float]] = []
        output.reserveCapacity(images.count)
        var start = 0
        while start < images.count {
            let end = min(start + configuration.batchSize, images.count)
            let batch = Array(images[start..<end])
            output.append(contentsOf: try embedBatch(batch))
            start = end
        }
        return output
    }

    private func embedBatch(_ images: [CGImage]) throws -> [[Float]] {
        var requestIDs: [String] = []
        var requestImages: [BuffaloLRequestImage] = []
        requestIDs.reserveCapacity(images.count)
        for image in images {
            let requestID = UUID().uuidString
            requestIDs.append(requestID)
            requestImages.append(BuffaloLRequestImage(
                requestID: requestID,
                imageBase64: try pngBase64(image)))
        }
        let envelope = BuffaloLRequestEnvelope(
            model: configuration.expectedModel,
            images: requestImages)
        let body: Data
        do {
            body = try JSONEncoder().encode(envelope)
        } catch {
            throw BuffaloLClientError(kind: .invalidInput)
        }
        let request = try makeRequest(method: "POST", path: configuration.embedPath, body: body)
        let (response, data) = try perform(request)
        guard response.statusCode == 200 else {
            throw classify(statusCode: response.statusCode)
        }
        let decoded: BuffaloLResponseEnvelope
        do {
            decoded = try JSONDecoder().decode(BuffaloLResponseEnvelope.self, from: data)
        } catch {
            throw BuffaloLClientError(kind: .malformedResponse)
        }
        guard decoded.model == configuration.expectedModel else {
            throw BuffaloLClientError(kind: .responseMismatch)
        }
        guard decoded.dimension == configuration.dimension else {
            throw BuffaloLClientError(kind: .dimensionMismatch)
        }
        guard decoded.embeddings.count == requestIDs.count else {
            throw BuffaloLClientError(kind: .responseMismatch)
        }

        var byID: [String: [Float]] = [:]
        for embedding in decoded.embeddings {
            guard byID[embedding.requestID] == nil else {
                throw BuffaloLClientError(kind: .responseMismatch)
            }
            guard embedding.vector.count == configuration.dimension,
                  embedding.vector.allSatisfy(\.isFinite)
            else {
                throw BuffaloLClientError(kind: .dimensionMismatch)
            }
            let norm = embedding.vector.reduce(0.0) {
                $0 + Double($1) * Double($1)
            }.squareRoot()
            guard norm > 0, norm.isFinite else {
                throw BuffaloLClientError(kind: .invalidVector)
            }
            byID[embedding.requestID] = embedding.vector.map(Float.init)
        }
        guard Set(byID.keys) == Set(requestIDs) else {
            throw BuffaloLClientError(kind: .responseMismatch)
        }
        return try requestIDs.map {
            guard let vector = byID[$0] else {
                throw BuffaloLClientError(kind: .responseMismatch)
            }
            return vector
        }
    }

    private func perform(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        var attempt = 1
        while true {
            do {
                let (response, data) = try transport.send(request)
                if (200...299).contains(response.statusCode) {
                    return (response, data)
                }
                let error = classify(statusCode: response.statusCode)
                if try retryIfNeeded(error, attempt: &attempt) { continue }
                throw error
            } catch let error as BuffaloLClientError {
                throw error
            } catch let error as URLError {
                let classified = BuffaloLClientError(
                    kind: error.code == .timedOut ? .timeout : .transient)
                if try retryIfNeeded(classified, attempt: &attempt) { continue }
                throw classified
            } catch {
                let classified = BuffaloLClientError(kind: .transient)
                if try retryIfNeeded(classified, attempt: &attempt) { continue }
                throw classified
            }
        }
    }

    private func retryIfNeeded(
        _ error: BuffaloLClientError,
        attempt: inout Int
    ) throws -> Bool {
        guard isRetryable(error.kind), attempt < configuration.maxAttempts else {
            return false
        }
        let delay = configuration.initialBackoff * pow(2.0, Double(attempt - 1))
        attempt += 1
        sleep(delay)
        return true
    }

    private func isRetryable(_ kind: BuffaloLFailureKind) -> Bool {
        switch kind {
        case .rateLimited, .transient, .timeout:
            return true
        default:
            return false
        }
    }

    private func classify(statusCode: Int) -> BuffaloLClientError {
        switch statusCode {
        case 401, 403:
            return BuffaloLClientError(kind: .authentication, statusCode: statusCode)
        case 408:
            return BuffaloLClientError(kind: .timeout, statusCode: statusCode)
        case 425, 429:
            return BuffaloLClientError(kind: .rateLimited, statusCode: statusCode)
        case 500...599:
            return BuffaloLClientError(kind: .transient, statusCode: statusCode)
        default:
            return BuffaloLClientError(kind: .permanent, statusCode: statusCode)
        }
    }

    private func makeRequest(method: String, path: String, body: Data?) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: configuration.endpoint)?.absoluteURL else {
            throw BuffaloLClientError(kind: .invalidConfiguration)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = configuration.timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token = configuration.bearerToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func pngBase64(_ image: CGImage) throws -> String {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil)
        else {
            throw BuffaloLClientError(kind: .invalidInput)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw BuffaloLClientError(kind: .invalidInput)
        }
        return (data as Data).base64EncodedString()
    }
}
