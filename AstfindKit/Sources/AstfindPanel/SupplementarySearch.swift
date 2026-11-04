import AppKit
import OilFindCore

/// Additional matches refer to entries in the captured source snapshot.
public struct SupplementaryHit {
    public let sourceID: String
    public let entryID: UInt32
    public let sourceVersion: UInt64?
    private let decoration: () -> (text: String, highlights: [NSRange])
    public var presentation: (text: String, highlights: [NSRange]) { decoration() }
    public var detail: String { decoration().text }
    public var highlights: [NSRange] { decoration().highlights }
    public let thumbnail: Bool
    /// 视频命中帧的时间码（毫秒）：仅表示“是否值得抽帧缩略图”；图片命中/SMB 视频为 nil。
    public let thumbnailTimeMs: Int?
    /// 视频命中帧的跳转时间码（毫秒）：与缩略图抽帧解耦。
    /// SMB 视频可以 `thumbnailTimeMs=nil`（不抽帧），但 `mediaStartMs` 必须保留，打开时才能定位。
    public let mediaStartMs: Int?
    public init(sourceID: String, entryID: UInt32, detail: String, highlights: [NSRange] = [], thumbnail: Bool = false, thumbnailTimeMs: Int? = nil, mediaStartMs: Int? = nil, sourceVersion: UInt64? = nil) {
        self.sourceVersion = sourceVersion
        self.sourceID = sourceID; self.entryID = entryID; self.decoration = { (detail, highlights) }; self.thumbnail = thumbnail
        self.thumbnailTimeMs = thumbnailTimeMs
        self.mediaStartMs = mediaStartMs
    }
    public init(sourceID: String, entryID: UInt32, thumbnail: Bool = false, thumbnailTimeMs: Int? = nil, mediaStartMs: Int? = nil, sourceVersion: UInt64? = nil, presentation: @escaping () -> (text: String, highlights: [NSRange])) {
        self.sourceVersion = sourceVersion
        self.sourceID = sourceID; self.entryID = entryID; self.thumbnail = thumbnail; self.thumbnailTimeMs = thumbnailTimeMs; self.mediaStartMs = mediaStartMs; decoration = presentation
    }
}
/// 调试快照用：同步预热文本语义缓存，让随后的 prepareSearch 能直接并入语义命中。
public protocol SemanticWarmupProvider: AnyObject {
    func warmSemanticQuery(_ term: String, timeout: TimeInterval)
}

public protocol SupplementarySearchProvider: AnyObject {
    var isEnabled: Bool { get }
    /// Called on the main thread; returned work runs concurrently with the name search.
    func prepareSearch(_ query: Query, options: SearchOptions, sources: [SearchSource], isCancelled: @escaping () -> Bool) -> () -> [SupplementaryHit]
    func sourcesDidChange(_ sources: [SearchSource])
    func userActivity(visible: Bool, typing: Bool)
    /// Background work should yield while the primary index is loading or rebuilding.
    func backgroundIndexingChanged(_ busy: Bool)
}
public extension SupplementarySearchProvider {
    func backgroundIndexingChanged(_ busy: Bool) { }
}
