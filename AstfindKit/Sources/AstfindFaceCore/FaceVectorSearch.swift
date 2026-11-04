import Foundation

public struct FaceVectorCandidate: Equatable, Sendable {
    public let assetID: String
    public let vector: [Float]

    public init(assetID: String, vector: [Float]) {
        self.assetID = assetID
        self.vector = vector
    }
}

public struct FaceVectorHit: Equatable, Sendable {
    public let assetID: String
    public let score: Double

    public init(assetID: String, score: Double) {
        self.assetID = assetID
        self.score = score
    }
}

public enum FaceVectorSearch {
    public static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot = 0.0
        var lhsNorm = 0.0
        var rhsNorm = 0.0
        for (left, right) in zip(lhs, rhs) {
            guard left.isFinite, right.isFinite else { return 0 }
            dot += Double(left) * Double(right)
            lhsNorm += Double(left) * Double(left)
            rhsNorm += Double(right) * Double(right)
        }
        let denominator = (lhsNorm * rhsNorm).squareRoot()
        guard denominator > 0, denominator.isFinite else { return 0 }
        return dot / denominator
    }

    public static func search(
        query: [Float],
        candidates: [FaceVectorCandidate],
        limit: Int
    ) -> [FaceVectorHit] {
        guard limit > 0 else { return [] }
        var bestByAsset: [String: Double] = [:]
        for candidate in candidates {
            let score = cosine(query, candidate.vector)
            if let current = bestByAsset[candidate.assetID] {
                bestByAsset[candidate.assetID] = max(current, score)
            } else {
                bestByAsset[candidate.assetID] = score
            }
        }
        return bestByAsset
            .map { FaceVectorHit(assetID: $0.key, score: $0.value) }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.assetID < $1.assetID
            }
            .prefix(limit)
            .map { $0 }
    }
}
