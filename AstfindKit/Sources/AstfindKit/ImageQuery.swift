import Foundation
import CryptoKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 以图搜图的查询图：与入库缩略图走同一套本地下采样（长边 ≤1024 JPEG），
/// 内容摘要做查询缓存键——同一张图重复查询不重复向量化。
public struct ImageQuery: Equatable, Sendable {
    public let digest: String
    public let jpeg: Data
    public let pixelWidth: Int
    public let pixelHeight: Int

    /// 与 `EmbeddingIndexer.maxLongSide` / `jpegQuality` 对齐：查询图与入库图必须同预处理，
    /// 否则相似度分布会漂移（入库发缩略图，查询发原图 = 两条不同的输入通道）。
    public static let maxLongSide: CGFloat = 1024
    public static let jpegQuality: CGFloat = 0.85

    public static func make(from data: Data) -> ImageQuery? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return make(source: source)
    }

    /// 文件读取带看门狗：NAS/SMB 的坏文件可能卡在不可中断 I/O（与入场泵同一纪律），
    /// 超时弃线程返回 nil，绝不吊死调用方。
    public static func make(fromFile url: URL, timeout: TimeInterval = 15) -> ImageQuery? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ImageQueryBox()
        DispatchQueue.global(qos: .userInitiated).async {
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)
            box.value = source.flatMap { make(source: $0) }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.value
    }

    private final class ImageQueryBox: @unchecked Sendable { var value: ImageQuery? }

    private static func make(source: CGImageSource) -> ImageQuery? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxLongSide),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let jpeg = output as Data
        let digest = SHA256.hash(data: jpeg).map { String(format: "%02x", $0) }.joined()
        return ImageQuery(digest: digest, jpeg: jpeg, pixelWidth: image.width, pixelHeight: image.height)
    }
}

/// 图片查询能力（只读缓存，绝不探测——可在 UI 热路径调用）。
public enum ImageQueryAvailability: Equatable, Sendable {
    case available
    /// 还没探测过：可以先放行入口，真正查询时后台探测。
    case unknown
    case unavailable(String)
}

/// 图片查询结果。`.analyzing` 表示后台正在向量化/检索，完成后经 `onImageQueryComplete` 回调。
public enum ImageQueryOutcome: Equatable, Sendable {
    case hits([EmbeddingIndexer.SemanticHit])
    case analyzing
    case unavailable(String)
    case failed(String)
}
