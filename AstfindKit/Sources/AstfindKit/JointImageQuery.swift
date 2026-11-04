import Foundation
import AstfindPanel

/// M0.7b：图片 + 文字联合查询。
///
/// 融合公式（PRD US-008）：
/// `normalize(alpha * imageVec + (1 - alpha) * textVec)`，默认 alpha = 0.7（图片主导）。
/// 只有图片/文本向量同 Provider/profile、维度一致且非零时才走融合；
/// 否则由引擎降级为“图片召回 + 文本过滤/重排”，绝不返回空结果。
public struct JointImageQuery: Equatable, Sendable {
    public static let defaultAlpha: Float = 0.7

    public let image: ImageQuery
    public let text: String
    public let alpha: Float

    public init(image: ImageQuery, text: String, alpha: Float = JointImageQuery.defaultAlpha) {
        self.image = image
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.alpha = min(1, max(0, alpha))
    }
}

/// 联合查询诊断状态：fused = 向量融合；filtered = 图片召回 + 文本重排；imageOnly = 纯图兜底。
public struct JointQueryResult: Equatable, Sendable {
    public let hits: [EmbeddingIndexer.SemanticHit]
    public let mode: JointQueryMode
    public let fallback: JointQueryFallback?

    public init(hits: [EmbeddingIndexer.SemanticHit], mode: JointQueryMode, fallback: JointQueryFallback? = nil) {
        self.hits = hits
        self.mode = mode
        self.fallback = fallback
    }
}

public enum JointImageQueryOutcome: Equatable, Sendable {
    case hits(JointQueryResult)
    case analyzing
    case unavailable(String)
    case failed(String)
}

public enum JointVectorFusion {
    /// 维度不一致、空向量或融合后零向量 → nil（调用方据此降级）。
    public static func fuse(image: [Float], text: [Float], alpha: Float) -> [Float]? {
        guard !image.isEmpty, image.count == text.count else { return nil }
        let a = min(1, max(0, alpha))
        var fused = [Float](repeating: 0, count: image.count)
        var normSquared: Float = 0
        for i in image.indices {
            let value = a * image[i] + (1 - a) * text[i]
            fused[i] = value
            normSquared += value * value
        }
        guard normSquared > 1e-12 else { return nil }
        let inverse = 1 / normSquared.squareRoot()
        for i in fused.indices { fused[i] *= inverse }
        return fused
    }

    /// 同空间离线标定/诊断用：两向量余弦；维度不一致返回 nil。
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float? {
        guard !a.isEmpty, a.count == b.count else { return nil }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i]
        }
        guard na > 1e-12, nb > 1e-12 else { return nil }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    public static func isUsable(_ vector: [Float]?, dimension: Int) -> Bool {
        guard let vector, vector.count == dimension else { return false }
        return vector.contains { $0 != 0 }
    }
}
