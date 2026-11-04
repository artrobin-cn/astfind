import AstfindFaceCore
import CryptoKit
import Foundation

public extension FaceBenchmarkProfile {
    var fingerprint: String {
        let fields = [
            detector,
            alignment,
            preprocessing,
            model,
            String(dimension),
            normalization,
            quantization
        ]
        let canonical = fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public struct FaceBenchmarkIndexRecord: Codable, Equatable, Sendable {
    public let faceID: String
    public let assetID: String
    public let vector: [Float]
    public let videoID: String?
    public let startMs: Int?

    enum CodingKeys: String, CodingKey {
        case faceID = "face_id"
        case assetID = "asset_id"
        case vector
        case videoID = "video_id"
        case startMs = "start_ms"
    }

    public init(
        faceID: String,
        assetID: String,
        vector: [Float],
        videoID: String? = nil,
        startMs: Int? = nil
    ) {
        self.faceID = faceID
        self.assetID = assetID
        self.vector = vector
        self.videoID = videoID
        self.startMs = startMs
    }
}

public struct FaceBenchmarkIndexHit: Codable, Equatable, Sendable {
    public let faceID: String
    public let assetID: String
    public let score: Double
    public let videoID: String?
    public let startMs: Int?

    enum CodingKeys: String, CodingKey {
        case faceID = "face_id"
        case assetID = "asset_id"
        case score
        case videoID = "video_id"
        case startMs = "start_ms"
    }

    public init(
        faceID: String,
        assetID: String,
        score: Double,
        videoID: String?,
        startMs: Int?
    ) {
        self.faceID = faceID
        self.assetID = assetID
        self.score = score
        self.videoID = videoID
        self.startMs = startMs
    }
}

public enum FaceBenchmarkIndexError: Error, Equatable {
    case invalidDimension(expected: Int, actual: Int)
    case generationMismatch(expected: Int, actual: Int)
    case duplicateFaceID(String)
    case invalidVector(String)
    case invalidRecord(String)
    case invalidQuery(String)
}

public struct FaceBenchmarkIndex: Codable, Equatable, Sendable {
    public let profile: FaceBenchmarkProfile
    public let generation: Int
    public private(set) var records: [FaceBenchmarkIndexRecord]

    public init(
        profile: FaceBenchmarkProfile,
        generation: Int,
        records: [FaceBenchmarkIndexRecord] = []
    ) {
        self.profile = profile
        self.generation = generation
        self.records = records
    }

    public var vectorCount: Int { records.count }

    public var assetCount: Int {
        Set(records.map(\.assetID)).count
    }

    public mutating func append(_ record: FaceBenchmarkIndexRecord) throws {
        try append(contentsOf: [record])
    }

    public mutating func append(_ newRecords: [FaceBenchmarkIndexRecord]) throws {
        try append(contentsOf: newRecords)
    }

    public mutating func append(contentsOf newRecords: [FaceBenchmarkIndexRecord]) throws {
        var seen = Set(records.map(\.faceID))
        for record in newRecords {
            try validate(record: record, seen: &seen)
        }
        records.append(contentsOf: newRecords)
    }

    public func validated() throws {
        guard profile.dimension > 0 else {
            throw FaceBenchmarkIndexError.invalidDimension(expected: 1, actual: profile.dimension)
        }
        guard generation >= 0 else {
            throw FaceBenchmarkIndexError.invalidRecord("generation")
        }
        var seen = Set<String>()
        for record in records {
            try validate(record: record, seen: &seen)
        }
    }

    public func search(
        query: [Float],
        limit: Int,
        threshold: Double? = nil,
        generation: Int
    ) throws -> [FaceBenchmarkIndexHit] {
        guard generation == self.generation else {
            throw FaceBenchmarkIndexError.generationMismatch(
                expected: self.generation,
                actual: generation)
        }
        guard query.count == profile.dimension else {
            throw FaceBenchmarkIndexError.invalidDimension(
                expected: profile.dimension,
                actual: query.count)
        }
        guard query.allSatisfy(\.isFinite) else {
            throw FaceBenchmarkIndexError.invalidQuery("nonfinite")
        }
        guard limit > 0 else { return [] }

        var bestByAsset: [String: FaceBenchmarkIndexHit] = [:]
        for record in records {
            let score = FaceVectorSearch.cosine(query, record.vector)
            if let threshold, score < threshold { continue }
            let hit = FaceBenchmarkIndexHit(
                faceID: record.faceID,
                assetID: record.assetID,
                score: score,
                videoID: record.videoID,
                startMs: record.startMs)
            if let current = bestByAsset[hit.assetID] {
                if hit.score > current.score
                    || (hit.score == current.score && hit.faceID < current.faceID) {
                    bestByAsset[hit.assetID] = hit
                }
            } else {
                bestByAsset[hit.assetID] = hit
            }
        }
        return bestByAsset.values
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.assetID < $1.assetID
            }
            .prefix(limit)
            .map { $0 }
    }

    public func encodedData() throws -> Data {
        try validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public func write(to url: URL) throws {
        let data = try encodedData()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public static func load(from url: URL) throws -> FaceBenchmarkIndex {
        let data = try Data(contentsOf: url)
        let index = try JSONDecoder().decode(FaceBenchmarkIndex.self, from: data)
        try index.validated()
        return index
    }

    private func validate(
        record: FaceBenchmarkIndexRecord,
        seen: inout Set<String>
    ) throws {
        guard !record.faceID.isEmpty, !record.assetID.isEmpty else {
            throw FaceBenchmarkIndexError.invalidRecord(record.faceID)
        }
        guard seen.insert(record.faceID).inserted else {
            throw FaceBenchmarkIndexError.duplicateFaceID(record.faceID)
        }
        guard record.vector.count == profile.dimension else {
            throw FaceBenchmarkIndexError.invalidDimension(
                expected: profile.dimension,
                actual: record.vector.count)
        }
        guard record.vector.allSatisfy(\.isFinite) else {
            throw FaceBenchmarkIndexError.invalidVector(record.faceID)
        }
    }
}

public struct FaceBenchmarkQueryCacheKey: Codable, Hashable, Sendable {
    public let cropDigest: String
    public let profileFingerprint: String
    public let generation: Int
    public let mode: String
    public let threshold: Double?
    public let limit: Int

    public init(
        cropDigest: String,
        profileFingerprint: String,
        generation: Int,
        mode: String,
        threshold: Double?,
        limit: Int
    ) {
        self.cropDigest = cropDigest
        self.profileFingerprint = profileFingerprint
        self.generation = generation
        self.mode = mode
        self.threshold = threshold
        self.limit = limit
    }
}

public struct FaceBenchmarkQueryCache {
    private var entries: [FaceBenchmarkQueryCacheKey: [FaceBenchmarkIndexHit]] = [:]

    public init() {}

    public mutating func store(
        _ hits: [FaceBenchmarkIndexHit],
        for key: FaceBenchmarkQueryCacheKey
    ) {
        entries[key] = hits
    }

    public func hits(for key: FaceBenchmarkQueryCacheKey) -> [FaceBenchmarkIndexHit]? {
        entries[key]
    }

    public mutating func removeAll() {
        entries.removeAll()
    }
}
