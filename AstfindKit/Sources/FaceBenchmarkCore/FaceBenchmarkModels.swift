import Foundation

public struct FaceBenchmarkProfile: Codable, Equatable, Sendable {
    public var detector: String
    public var alignment: String
    public var preprocessing: String
    public var model: String
    public var dimension: Int
    public var normalization: String
    public var quantization: String

    public init(detector: String, alignment: String, preprocessing: String, model: String,
                dimension: Int, normalization: String, quantization: String) {
        self.detector = detector
        self.alignment = alignment
        self.preprocessing = preprocessing
        self.model = model
        self.dimension = dimension
        self.normalization = normalization
        self.quantization = quantization
    }
}

public enum FaceBenchmarkAssetKind: String, Codable, Sendable {
    case image
    case videoFrame = "video_frame"
}

public enum FaceBenchmarkCondition: String, Codable, Sendable, CaseIterable {
    case frontal
    case profile
    case smallFace = "small_face"
    case lowLight = "low_light"
    case groupPhoto = "group_photo"
    case videoFrame = "video_frame"
}

public struct FaceBenchmarkAsset: Codable, Equatable, Sendable {
    public var assetID: String
    public var path: String
    public var kind: FaceBenchmarkAssetKind
    public var personIDs: [String]
    public var condition: FaceBenchmarkCondition
    public var startMs: Int?
    public var videoID: String?

    enum CodingKeys: String, CodingKey {
        case assetID = "asset_id"
        case path, kind
        case personIDs = "person_ids"
        case condition
        case startMs = "start_ms"
        case videoID = "video_id"
    }

    public init(assetID: String, path: String, kind: FaceBenchmarkAssetKind,
                personIDs: [String], condition: FaceBenchmarkCondition, startMs: Int?,
                videoID: String? = nil) {
        self.assetID = assetID
        self.path = path
        self.kind = kind
        self.personIDs = personIDs
        self.condition = condition
        self.startMs = startMs
        self.videoID = videoID
    }
}

public struct FaceBenchmarkQuery: Codable, Equatable, Sendable {
    public var queryID: String
    public var personID: String?
    public var imagePath: String
    public var sourceAssetID: String?
    public var selectedFaceIndex: Int
    public var excludedAssetIDs: [String]
    public var conditions: [FaceBenchmarkCondition]

    enum CodingKeys: String, CodingKey {
        case queryID = "query_id"
        case personID = "person_id"
        case imagePath = "image_path"
        case sourceAssetID = "source_asset_id"
        case selectedFaceIndex = "selected_face_index"
        case excludedAssetIDs = "excluded_asset_ids"
        case conditions
    }

    public init(queryID: String, personID: String?, imagePath: String, sourceAssetID: String?,
                selectedFaceIndex: Int, excludedAssetIDs: [String], conditions: [FaceBenchmarkCondition]) {
        self.queryID = queryID
        self.personID = personID
        self.imagePath = imagePath
        self.sourceAssetID = sourceAssetID
        self.selectedFaceIndex = selectedFaceIndex
        self.excludedAssetIDs = excludedAssetIDs
        self.conditions = conditions
    }
}

public struct FaceBenchmarkManifest: Codable, Equatable, Sendable {
    public var profile: FaceBenchmarkProfile
    public var assets: [FaceBenchmarkAsset]
    public var queries: [FaceBenchmarkQuery]

    public init(profile: FaceBenchmarkProfile, assets: [FaceBenchmarkAsset], queries: [FaceBenchmarkQuery]) {
        self.profile = profile
        self.assets = assets
        self.queries = queries
    }

    public func validationIssues() -> [String] {
        var issues: [String] = []
        if assets.isEmpty { issues.append("manifest must contain assets") }
        if queries.isEmpty { issues.append("manifest must contain queries") }
        if profile.dimension <= 0 { issues.append("profile dimension must be positive") }

        let galleryAssetIDs = Set(assets.map(\.assetID))
        let galleryPersonIDs = Set(assets.flatMap(\.personIDs))
        issues.append(contentsOf: duplicateValues(assets.map(\.assetID)).map { "duplicate asset id \($0)" })
        issues.append(contentsOf: duplicateValues(queries.map(\.queryID)).map { "duplicate query id \($0)" })

        for query in queries {
            if query.selectedFaceIndex < 0 {
                issues.append("query \(query.queryID) selected face index must be nonnegative")
            }
            if query.conditions.isEmpty {
                issues.append("query \(query.queryID) must have at least one condition")
            }
            if let personID = query.personID, !galleryPersonIDs.contains(personID) {
                issues.append("query \(query.queryID) person \(personID) is absent from gallery")
            }
            if let sourceAssetID = query.sourceAssetID, galleryAssetIDs.contains(sourceAssetID) {
                issues.append("query \(query.queryID) leaks source asset \(sourceAssetID)")
            }
            for assetID in query.excludedAssetIDs where galleryAssetIDs.contains(assetID) {
                issues.append("query \(query.queryID) excluded asset \(assetID) remains in gallery")
            }
        }
        return issues
    }

    private func duplicateValues(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var duplicates = Set<String>()
        var ordered: [String] = []
        for value in values {
            if !seen.insert(value).inserted, duplicates.insert(value).inserted {
                ordered.append(value)
            }
        }
        return ordered
    }
}

public struct FaceBenchmarkHit: Codable, Equatable, Sendable {
    public var assetID: String
    public var score: Double

    enum CodingKeys: String, CodingKey {
        case assetID = "asset_id"
        case score
    }

    public init(assetID: String, score: Double) {
        self.assetID = assetID
        self.score = score
    }
}

public struct FaceBenchmarkQueryResult: Codable, Equatable, Sendable {
    public var queryID: String
    public var hits: [FaceBenchmarkHit]
    public var elapsedMs: Double

    enum CodingKeys: String, CodingKey {
        case queryID = "query_id"
        case hits
        case elapsedMs = "elapsed_ms"
    }

    public init(queryID: String, hits: [FaceBenchmarkHit], elapsedMs: Double) {
        self.queryID = queryID
        self.hits = hits
        self.elapsedMs = elapsedMs
    }
}
