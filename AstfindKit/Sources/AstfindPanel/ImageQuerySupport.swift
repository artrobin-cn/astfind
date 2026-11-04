import AppKit
import OilFindCore

/// 图片查询入口能力（面板只读缓存，不触发联网探测）。
public enum ImageEntryAvailability: Equatable {
    case available
    /// 尚未探测：入口先放行，真正查询时后台探测。
    case unknown
    case unavailable(String)
}

public enum ImageQueryPhase: Equatable {
    case idle
    case analyzing
    /// 已完成；关联值为命中条数（0 = 没有相似素材）。
    case ready(Int)
    case unavailable(String)
    case failed(String)

    public var isBusy: Bool { self == .analyzing }
}

/// 以图搜图的面板侧协议：入口、预览、异步结果与状态。
/// 实现在 AstfindKit 的 ContentSupplementaryProvider（它同时是文本补充通道的 Provider）。
public protocol ImageQuerySearchProvider: AnyObject {
    var onImageQueryChange: (() -> Void)? { get set }
    var imagePreview: NSImage? { get }
    var imageQueryPhase: ImageQueryPhase { get }
    var imageEntryAvailability: ImageEntryAvailability { get }

    /// 接受一张参考图（任意系统可解码格式）。false = 无法解码。
    func acceptImageQuery(_ data: Data) -> Bool
    /// 接受一张人物参考照片（M0.8b）；false = 无法解码。
    func acceptPersonQuery(_ data: Data) -> Bool
    func clearImageQuery()
    /// 当前参考图是否处于“找人”模式（结果标签/占位文案用）。
    var isPersonQueryActive: Bool { get }
    /// 人物入口可用性（全局开关 + 模型就绪）。
    var personEntryAvailability: ImageEntryAvailability { get }
    /// 参考图候选脸缩略图（按面积降序）；单脸时通常 1 张。
    var personFacePreviews: [NSImage] { get }
    var selectedPersonFaceIndex: Int { get }
    /// 切换候选主脸；实现方负责触发重新查询。
    func selectPersonFace(_ index: Int)

    /// 当前 sources 下的图片命中；未就绪时内部调度后台计算并返回 .analyzing。
    func imageQueryHits(for sources: [SearchSource], kind: UInt8?,
                        isCancelled: @escaping () -> Bool) -> (hits: [SupplementaryHit], phase: ImageQueryPhase)
}
