import CoreGraphics
import Foundation
import XCTest
@testable import FaceBenchmarkCore

private final class RecordingHTTPTransport: FaceHTTPTransport {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)
    private let handler: Handler
    private(set) var requests: [URLRequest] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func send(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        requests.append(request)
        return try handler(request)
    }
}

final class BuffaloLClientTests: XCTestCase {
    private let endpoint = URL(string: "https://face.example.test")!
    private let image = FaceTestImages.solid(width: 112, height: 112, red: 10, green: 20, blue: 30)

    private func configuration(
        dimension: Int = 2,
        batchSize: Int = 8,
        maxAttempts: Int = 3,
        token: String? = nil,
        allowLoopbackHTTP: Bool = false
    ) throws -> BuffaloLRemoteConfiguration {
        try BuffaloLRemoteConfiguration(
            endpoint: endpoint,
            bearerToken: token,
            batchSize: batchSize,
            maxAttempts: maxAttempts,
            initialBackoff: 0.25,
            expectedModel: "buffalo_l",
            dimension: dimension,
            allowLoopbackHTTP: allowLoopbackHTTP)
    }

    private func response(_ status: Int, data: Data = Data()) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: endpoint,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!,
            data
        )
    }

    private func requestIDs(from request: URLRequest) throws -> [String] {
        let json = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: json) as? [String: Any])
        let images = try XCTUnwrap(object["images"] as? [[String: Any]])
        return try images.map { try XCTUnwrap($0["request_id"] as? String) }
    }

    private func embeddingResponse(
        request: URLRequest,
        model: String = "buffalo_l",
        dimension: Int = 2,
        vectors: (([String]) -> [(String, [Double])])? = nil
    ) throws -> Data {
        let ids = try requestIDs(from: request)
        let values = vectors?(ids) ?? ids.enumerated().map {
            ($0.element, [Double($0.offset + 1), 1])
        }
        let object: [String: Any] = [
            "model": model,
            "dimension": dimension,
            "embeddings": values.map {
                ["request_id": $0.0, "vector": $0.1]
            }
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testRejectsInsecureEndpointAndMissingEnvironmentConfiguration() throws {
        XCTAssertThrowsError(try BuffaloLRemoteConfiguration(
            endpoint: URL(string: "http://face.example.test")!,
            dimension: 2)) {
            XCTAssertEqual($0 as? BuffaloLClientError, .init(kind: .insecureTransport))
        }
        XCTAssertThrowsError(try BuffaloLRemoteConfiguration.load(environment: [:])) {
            XCTAssertEqual($0 as? BuffaloLClientError, .init(kind: .invalidConfiguration))
        }
        let loaded = try BuffaloLRemoteConfiguration.load(environment: [
            "ASTFIND_FACE_BENCHMARK_REMOTE_URL": "https://face.example.test",
            "ASTFIND_FACE_BENCHMARK_REMOTE_TOKEN": "secret-token",
            "ASTFIND_FACE_BENCHMARK_REMOTE_MODEL": "buffalo_l",
            "ASTFIND_FACE_BENCHMARK_REMOTE_DIMENSION": "512"
        ])
        XCTAssertEqual(loaded.expectedModel, "buffalo_l")
        XCTAssertEqual(loaded.dimension, 512)
        XCTAssertEqual(loaded.bearerToken, "secret-token")
        XCTAssertEqual(loaded.endpoint.scheme, "https")
    }

    func testHealthChecksModelAndDimensionWithoutLeakingEndpoint() throws {
        let transport = RecordingHTTPTransport { _ in
            self.response(200, data: Data(#"{"model":"buffalo_l","dimension":512}"#.utf8))
        }
        let client = BuffaloLClient(
            configuration: try configuration(dimension: 512),
            transport: transport,
            sleep: { _ in })
        let health = try client.health()
        XCTAssertEqual(health, BuffaloLHealth(model: "buffalo_l", dimension: 512))
        XCTAssertEqual(transport.requests.first?.url?.path, "/health")

        let wrong = BuffaloLClient(
            configuration: try configuration(dimension: 512),
            transport: RecordingHTTPTransport { _ in
                self.response(200, data: Data(#"{"model":"other","dimension":512}"#.utf8))
            },
            sleep: { _ in })
        XCTAssertThrowsError(try wrong.health()) {
            XCTAssertEqual($0 as? BuffaloLClientError, .init(kind: .healthCheckFailed))
        }
    }

    func testBatchesAndAlignsOutOfOrderResponsesByRequestID() throws {
        let transport = RecordingHTTPTransport { request in
            self.response(200, data: try self.embeddingResponse(
                request: request,
                vectors: { ids in
                    ids.reversed().enumerated().map {
                        ($0.element, [Double($0.offset), 1])
                    }
                }))
        }
        let client = BuffaloLClient(
            configuration: try configuration(batchSize: 2),
            transport: transport,
            sleep: { _ in })
        let vectors = try client.embed(images: [image, image, image])
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(try requestIDs(from: transport.requests[0]).count, 2)
        XCTAssertEqual(try requestIDs(from: transport.requests[1]).count, 1)
        XCTAssertEqual(vectors, [[1, 1], [0, 1], [0, 1]])

        let ids = Set(try transport.requests.flatMap { try requestIDs(from: $0) })
        XCTAssertEqual(ids.count, 3)
    }

    func testRequestContainsOnlyModelRandomIDsAndImageBytesWithBearerAuth() throws {
        let transport = RecordingHTTPTransport { request in
            self.response(200, data: try self.embeddingResponse(request: request))
        }
        let client = BuffaloLClient(
            configuration: try configuration(token: "secret-token"),
            transport: transport,
            sleep: { _ in })
        _ = try client.embed(images: [image])

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "buffalo_l")
        XCTAssertNil(object["path"])
        XCTAssertNil(object["person_id"])
        let images = try XCTUnwrap(object["images"] as? [[String: Any]])
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(Set(images[0].keys), Set(["request_id", "image_base64"]))
    }

    func testRejectsMissingDuplicateAndUnexpectedResponseIDs() throws {
        let cases: [(([String]) -> [(String, [Double])])] = [
            { ids in Array(ids.dropLast()).enumerated().map { ($0.element, [1, 1]) } },
            { ids in
                ids.enumerated().map { offset, id in
                    (offset == 1 ? ids[0] : id, [1, 1])
                }
            },
            { ids in ids.enumerated().map { ($0.element, [1, 1]) } + [("unexpected", [1, 1])] }
        ]
        for transform in cases {
            let transport = RecordingHTTPTransport { request in
                self.response(200, data: try self.embeddingResponse(
                    request: request, vectors: transform))
            }
            let client = BuffaloLClient(
                configuration: try configuration(),
                transport: transport,
                sleep: { _ in })
            XCTAssertThrowsError(try client.embed(images: [image, image])) {
                XCTAssertEqual($0 as? BuffaloLClientError, .init(kind: .responseMismatch))
            }
        }
    }

    func testRejectsResponseCountDimensionAndZeroNormVectors() throws {
        let countTransport = RecordingHTTPTransport { request in
            let object: [String: Any] = [
                "model": "buffalo_l",
                "dimension": 2,
                "embeddings": [["request_id": "not-matching", "vector": [1, 1]]]
            ]
            return self.response(200, data: try JSONSerialization.data(withJSONObject: object))
        }
        let countClient = BuffaloLClient(
            configuration: try configuration(),
            transport: countTransport,
            sleep: { _ in })
        XCTAssertThrowsError(try countClient.embed(images: [image, image])) {
            XCTAssertEqual($0 as? BuffaloLClientError, .init(kind: .responseMismatch))
        }

        let dimensionTransport = RecordingHTTPTransport { request in
            self.response(200, data: try self.embeddingResponse(
                request: request, dimension: 3))
        }
        let dimensionClient = BuffaloLClient(
            configuration: try configuration(),
            transport: dimensionTransport,
            sleep: { _ in })
        XCTAssertThrowsError(try dimensionClient.embed(images: [image])) {
            XCTAssertEqual($0 as? BuffaloLClientError, .init(kind: .dimensionMismatch))
        }

        let zeroTransport = RecordingHTTPTransport { request in
            self.response(200, data: try self.embeddingResponse(
                request: request,
                vectors: { ids in ids.map { ($0, [0, 0]) } }))
        }
        let zeroClient = BuffaloLClient(
            configuration: try configuration(),
            transport: zeroTransport,
            sleep: { _ in })
        XCTAssertThrowsError(try zeroClient.embed(images: [image])) {
            XCTAssertEqual($0 as? BuffaloLClientError, .init(kind: .invalidVector))
        }
    }

    func testAuthenticationAndPermanentFailuresAreNotRetried() throws {
        let authTransport = RecordingHTTPTransport { _ in self.response(401) }
        let authClient = BuffaloLClient(
            configuration: try configuration(),
            transport: authTransport,
            sleep: { _ in })
        XCTAssertThrowsError(try authClient.embed(images: [image])) {
            XCTAssertEqual($0 as? BuffaloLClientError, .init(kind: .authentication, statusCode: 401))
        }
        XCTAssertEqual(authTransport.requests.count, 1)

        let permanentTransport = RecordingHTTPTransport { _ in self.response(400) }
        let permanentClient = BuffaloLClient(
            configuration: try configuration(),
            transport: permanentTransport,
            sleep: { _ in })
        XCTAssertThrowsError(try permanentClient.embed(images: [image])) {
            XCTAssertEqual($0 as? BuffaloLClientError, .init(kind: .permanent, statusCode: 400))
        }
        XCTAssertEqual(permanentTransport.requests.count, 1)
    }

    func testTransientFailuresRetryWithExponentialBackoff() throws {
        var calls = 0
        var sleeps: [TimeInterval] = []
        let transport = RecordingHTTPTransport { request in
            calls += 1
            if calls < 3 { return self.response(503) }
            return self.response(200, data: try self.embeddingResponse(request: request))
        }
        let client = BuffaloLClient(
            configuration: try configuration(maxAttempts: 3),
            transport: transport,
            sleep: { sleeps.append($0) })
        let vectors = try client.embed(images: [image])
        XCTAssertEqual(vectors.count, 1)
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(sleeps, [0.25, 0.5])
    }

    func testRateLimitAndTimeoutExhaustionAreClassified() throws {
        var rateLimitSleeps: [TimeInterval] = []
        let rateLimited = BuffaloLClient(
            configuration: try configuration(maxAttempts: 2),
            transport: RecordingHTTPTransport { _ in self.response(429) },
            sleep: { rateLimitSleeps.append($0) })
        XCTAssertThrowsError(try rateLimited.embed(images: [image])) {
            XCTAssertEqual($0 as? BuffaloLClientError, .init(kind: .rateLimited, statusCode: 429))
        }
        XCTAssertEqual(rateLimitSleeps, [0.25])

        var timeoutCalls = 0
        let timeout = BuffaloLClient(
            configuration: try configuration(maxAttempts: 2),
            transport: RecordingHTTPTransport { _ in
                timeoutCalls += 1
                throw URLError(.timedOut)
            },
            sleep: { _ in })
        XCTAssertThrowsError(try timeout.embed(images: [image])) {
            XCTAssertEqual($0 as? BuffaloLClientError, .init(kind: .timeout))
        }
        XCTAssertEqual(timeoutCalls, 2)
    }

    func testLaterBatchFailureReturnsNoPartialVectors() throws {
        var calls = 0
        let transport = RecordingHTTPTransport { request in
            calls += 1
            if calls > 1 { return self.response(500) }
            return self.response(200, data: try self.embeddingResponse(request: request))
        }
        let client = BuffaloLClient(
            configuration: try configuration(batchSize: 2, maxAttempts: 2),
            transport: transport,
            sleep: { _ in })
        XCTAssertThrowsError(try client.embed(images: [image, image, image])) {
            XCTAssertEqual($0 as? BuffaloLClientError, .init(kind: .transient, statusCode: 500))
        }
        XCTAssertEqual(calls, 3)
    }

    func testRejectsNon112ImageBeforeNetworkAndHidesSecretsInErrors() throws {
        let imageTransport = RecordingHTTPTransport { request in
            self.response(200, data: try self.embeddingResponse(request: request))
        }
        let imageClient = BuffaloLClient(
            configuration: try configuration(),
            transport: imageTransport,
            sleep: { _ in })
        XCTAssertThrowsError(try imageClient.embed(images: [
            FaceTestImages.solid(width: 100, height: 112, red: 0, green: 0, blue: 0)
        ])) {
            XCTAssertEqual($0 as? BuffaloLClientError, .init(kind: .invalidInput))
        }
        XCTAssertEqual(imageTransport.requests.count, 0)

        let secretClient = BuffaloLClient(
            configuration: try configuration(token: "super-secret-token"),
            transport: RecordingHTTPTransport { _ in self.response(401) },
            sleep: { _ in })
        XCTAssertThrowsError(try secretClient.embed(images: [image])) { error in
            let description = String(describing: error)
            XCTAssertFalse(description.contains("face.example.test"))
            XCTAssertFalse(description.contains("super-secret-token"))
        }
    }
    func testHTTPIsOnlyAllowedForExplicitLoopbackTunnel() throws {
        let loopback = URL(string: "http://127.0.0.1:28124")!
        XCTAssertThrowsError(try BuffaloLRemoteConfiguration(
            endpoint: loopback,
            dimension: 2)) {
            XCTAssertEqual($0 as? BuffaloLClientError, .init(kind: .insecureTransport))
        }
        let allowed = try BuffaloLRemoteConfiguration(
            endpoint: loopback,
            dimension: 2,
            allowLoopbackHTTP: true)
        XCTAssertTrue(allowed.allowLoopbackHTTP)
        XCTAssertEqual(allowed.endpoint.scheme, "http")

        XCTAssertThrowsError(try BuffaloLRemoteConfiguration(
            endpoint: URL(string: "http://face.example.test")!,
            dimension: 2,
            allowLoopbackHTTP: true)) {
            XCTAssertEqual($0 as? BuffaloLClientError, .init(kind: .insecureTransport))
        }
    }

    func testEnvironmentCanEnableLoopbackTunnel() throws {
        let loaded = try BuffaloLRemoteConfiguration.load(environment: [
            "ASTFIND_FACE_BENCHMARK_REMOTE_URL": "http://127.0.0.1:28124",
            "ASTFIND_FACE_BENCHMARK_REMOTE_DIMENSION": "512",
            "ASTFIND_FACE_BENCHMARK_REMOTE_ALLOW_LOOPBACK_HTTP": "1"
        ])
        XCTAssertTrue(loaded.allowLoopbackHTTP)
    }

}
