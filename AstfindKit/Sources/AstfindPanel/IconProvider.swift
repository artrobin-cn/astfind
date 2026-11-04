import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import OilFindCore

final class IconProvider {
    private let paths = NSCache<NSString, NSImage>()
    private var extensions: [String: NSImage] = [:]
    private var pending: [String: [(NSImage) -> Void]] = [:]
    /// 缩略图读取会碰 NAS/SMB 的坏文件（不可中断 I/O）：并发 3 路 + 每项超时，
    /// 一个坏文件只能拖住一个槽位，绝不堵死整列缩略图（0.2.7 的串行队列会全堵）。
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.oiloil.find.icons"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 3
        return queue
    }()
    var isIdle: Bool { pending.isEmpty }
    /// 仅用于 DEBUG 截图：对图片/视频也尝试生成缩略图，不要求补充命中自带 thumbnail 标记。
    var forceThumbnails = false
    init() { paths.countLimit = 500 }

    /// frameMs 非空时按视频时间码抽帧（命中帧缩略图）；抽帧失败回退文件缩略图。
    func thumbnail(path: String, modified: Date, frameMs: Int? = nil, completion: @escaping (NSImage) -> Void) {
        let key = "thumbnail:" + path + String(modified.timeIntervalSince1970) + (frameMs.map { "#\($0)" } ?? "")
        if let cached = paths.object(forKey: key as NSString) { completion(cached); return }
        if pending[key] != nil { pending[key]!.append(completion); return }
        pending[key] = [completion]
        queue.addOperation { [weak self] in
            let cg: CGImage?
            if let frameMs {
                cg = Self.withTimeout(6) { Self.videoFrame(path: path, ms: frameMs, maxPixel: 64) }
                    ?? Self.withTimeout(5) { Self.fileThumbnail(path: path, maxPixel: 64) }
            } else {
                cg = Self.withTimeout(5) { Self.fileThumbnail(path: path, maxPixel: 64) }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                let callbacks = self.pending.removeValue(forKey: key) ?? []
                guard let cg else { return }
                let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                self.paths.setObject(image, forKey: key as NSString); callbacks.forEach { $0(image) }
            }
        }
    }
    private static func fileThumbnail(path: String, maxPixel: Int) -> CGImage? {
        let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        return source.flatMap {
            CGImageSourceCreateThumbnailAtIndex($0, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                       kCGImageSourceCreateThumbnailWithTransform: true,
                                                       kCGImageSourceThumbnailMaxPixelSize: maxPixel] as CFDictionary)
        }
    }
    /// 有观看超时（坏视频不吊死缩略图队列）；误差 ±0.1s 换取抽帧速度。
    private static func videoFrame(path: String, ms: Int, maxPixel: Int) -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        let semaphore = DispatchSemaphore(value: 0)
        let box = FrameBox()
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: CMTime(value: CMTimeValue(ms), timescale: 1000))]) { _, image, _, _, _ in
            box.value = image
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 5) == .success else {
            generator.cancelAllCGImageGeneration()
            return nil
        }
        return box.value
    }
    private final class FrameBox: @unchecked Sendable { var value: CGImage? }

    /// 文件系统/网络读取看门狗：超时弃线程返回 nil，操作队列的槽位随后释放。
    private static func withTimeout<T>(_ seconds: TimeInterval, _ work: @escaping () -> T?) -> T? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ValueBox<T>()
        DispatchQueue.global(qos: .utility).async {
            box.value = work()
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + seconds) == .success else { return nil }
        return box.value
    }
    private final class ValueBox<T>: @unchecked Sendable { var value: T? }

    func icon(name: String, path: String, flags: UInt8, kind: UInt8, resolveFileIcon: Bool = true, completion: @escaping (NSImage) -> Void) -> NSImage {
        precondition(Thread.isMainThread)
        let directory = flags & SiftFlag.dir != 0, package = flags & SiftFlag.package != 0
        let key: String
        let type: UTType
        if kind == 2 { key = "/application"; type = .application }
        else if package { key = "/package"; type = .package }
        else if directory { key = "/folder"; type = .folder }
        else {
            key = (name as NSString).pathExtension.lowercased()
            type = UTType(filenameExtension: key) ?? .data
        }
        let generic: NSImage
        if let cached = extensions[key] { generic = cached }
        else { generic = NSWorkspace.shared.icon(for: type); extensions[key] = generic }
        guard resolveFileIcon, directory || package || kind == 2 else { return generic }
        if let image = paths.object(forKey: path as NSString) { return image }
        if pending[path] != nil { pending[path]!.append(completion); return generic }
        pending[path] = [completion]
        queue.addOperation { [weak self] in
            let image = Self.withTimeout(3) { NSWorkspace.shared.icon(forFile: path) }
            DispatchQueue.main.async {
                guard let self else { return }
                let callbacks = self.pending.removeValue(forKey: path) ?? []
                guard let image else { return }
                self.paths.setObject(image, forKey: path as NSString)
                callbacks.forEach { $0(image) }
            }
        }
        return generic
    }
}