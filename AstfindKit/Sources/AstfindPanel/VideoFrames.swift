import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// M0.7a “视频帧找相似”抽帧器。
///
/// 与 `IconProvider.videoFrame` 的区别：
/// - 这里抽的是**查询图**（长边 1024、JPEG 0.85），必须与 `ImageQuery` 的入库预处理一致；
/// - 失败要可分类（超时 / 读不了 / 没有帧），面板据此提示；绝不回退视频海报，
///   否则用户会误以为“找相似”的是海报而不是命中时间点的画面。
enum VideoFrameExtractor {
    enum Failure: Error, Equatable {
        case timeout
        case unreadable
        case frameUnavailable(String)
    }

    static let maxLongSide: CGFloat = 1024
    static let jpegQuality: CGFloat = 0.85
    /// 抽帧看门狗：SMB 大文件可能长时间随机读，超时即放弃，不进入半成品查询。
    static let defaultTimeout: TimeInterval = 8
    /// 命中时间码定位容差（±0.1s）：换取抽帧速度。
    static let toleranceSeconds = 0.1

    static func jpegData(path: String, atMs ms: Int,
                         timeout: TimeInterval = defaultTimeout) -> Result<Data, Failure> {
        let url = URL(fileURLWithPath: path)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxLongSide, height: maxLongSide)
        let tolerance = CMTime(seconds: toleranceSeconds, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let time = CMTime(value: CMTimeValue(max(0, ms)), timescale: 1000)
        let semaphore = DispatchSemaphore(value: 0)
        let box = FrameBox()
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, result, error in
            box.result = image.map(Result<CGImage, Failure>.success)
                ?? .failure(error.map { .frameUnavailable(String(describing: $0)) }
                            ?? .frameUnavailable("generator result \(result.rawValue)"))
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            generator.cancelAllCGImageGeneration()
            return .failure(.timeout)
        }
        switch box.result {
        case .success(let image):
            guard let data = jpegData(from: image) else {
                return .failure(.frameUnavailable("JPEG encode failed"))
            }
            return .success(data)
        case .failure(let failure):
            return .failure(failure)
        case nil:
            return .failure(.unreadable)
        }
    }

    private static func jpegData(from image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private final class FrameBox: @unchecked Sendable {
        var result: Result<CGImage, Failure>?
    }
}
