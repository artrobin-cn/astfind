import Foundation
import OilFindCore

/// 联合查询诊断状态：fused = 向量融合；filtered = 图片召回 + 文本重排；imageOnly = 纯图兜底。
public enum JointQueryMode: String, Equatable, Sendable {
    case fused
    case filtered
    case imageOnly
}

public enum JointQueryFallback: String, Equatable, Sendable {
    case textVectorUnavailable
    case fusionUnavailable
    case searchFailed
    case textNoMatch
}

public enum JointImageQueryPhase: Equatable {
    case idle
    case analyzing
    case ready(count: Int, mode: JointQueryMode, fallback: JointQueryFallback?)
    case unavailable(String)
    case failed(String)

    public var isBusy: Bool { self == .analyzing }
}

/// 图文联合查询的面板侧协议：参考图已在图片 Provider 中，继续输入文字即联合。
public protocol JointImageSearchProvider: ImageQuerySearchProvider {
    var jointQueryPhase: JointImageQueryPhase { get }
    func jointImageHits(for text: String, sources: [SearchSource], kind: UInt8?,
                        isCancelled: @escaping () -> Bool) -> (hits: [SupplementaryHit], phase: JointImageQueryPhase)
}
