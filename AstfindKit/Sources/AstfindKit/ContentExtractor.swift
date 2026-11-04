import Foundation
import PDFKit
import Vision
import AppKit
import AVFoundation

/// 内容提取器：把一个资产物化为文本观察（D6 三实现：纯文本 / PDFKit / Vision OCR；L2 视频帧 OCR）。
/// 全部本地执行，绝不上传（ADL-113）——这是与 A1 远程 Provider 的本质区别。
public protocol ContentExtracting {
    /// 记入 text_observations.extractor_profile 的版本标识。
    var profile: String { get }
    func canExtract(fileName: String) -> Bool
    /// 返回全文；文件不可读/格式坏抛错（调用方记 failed，不中断批处理）。
    func extract(at url: URL) throws -> String
    /// 带时间码的分段提取（视频等时间媒体）。默认 nil = 非时间媒体，调用方走 extract(at:)。
    func extractSegments(at url: URL) throws -> [TimedText]?
    /// 单文件看门狗时限（秒）。视频按帧 OCR 远慢于单图，需更长熔断窗口。
    var watchdogSeconds: TimeInterval { get }
}

public extension ContentExtracting {
    func extractSegments(at url: URL) throws -> [TimedText]? { nil }
    var watchdogSeconds: TimeInterval { 180 }
}

/// 时间媒体中的一段文字：[startMs, endMs) 内画面/音轨出现的同一段文本。
public struct TimedText: Equatable, Sendable {
    public let startMs: Int
    public let endMs: Int
    public let text: String
    public init(startMs: Int, endMs: Int, text: String) {
        self.startMs = startMs; self.endMs = endMs; self.text = text
    }
}

// MARK: - 纯文本

public struct PlainTextExtractor: ContentExtracting {
    public let profile = "plain-v1"
    /// 可提取扩展名（公开静态：范围选择器的成本预估与入队过滤共用同一事实源）
    public static let supportedExtensions: Set<String> = ["txt", "md", "csv", "json", "log"]
    let extensions: Set<String> = PlainTextExtractor.supportedExtensions
    public init() {}
    public func canExtract(fileName: String) -> Bool {
        extensions.contains((fileName as NSString).pathExtension.lowercased())
    }
    public func extract(at url: URL) throws -> String {
        if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        // 非 UTF-8（GBK 等）：按 latin1 逐字节保底，中文会乱码但 ASCII 关键词仍可搜
        let data = try Data(contentsOf: url)
        return String(data.map { Character(UnicodeScalar($0)) })
    }
}

// MARK: - PDF（系统 PDFKit，文本层）

public struct PDFTextExtractor: ContentExtracting {
    /// v2：文本层缺失/无效时逐页渲染 + Vision OCR 兜底（扫描版合同/发票是常态而非例外）。
    public let profile = "pdf-pdfkit+ocr-v2"
    /// 扫描版逐页 OCR 的页数上限——控制单文件成本；金额等关键字段几乎都在前几页
    public var ocrPageLimit = 20
    /// 文本层低于该字符数视为扫描件（防"水印数十字 + 全页扫描图"被误判为有文本层）
    public var minTextLayerChars = 20
    public init() {}
    public func canExtract(fileName: String) -> Bool {
        (fileName as NSString).pathExtension.lowercased() == "pdf"
    }
    public func extract(at url: URL) throws -> String {
        guard let document = PDFDocument(url: url) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        let textLayer = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
        guard textLayer.trimmingCharacters(in: .whitespacesAndNewlines).count < minTextLayerChars else {
            return textLayer   // 有效文本层，零额外成本
        }
        // 扫描版：逐页渲染（~150 DPI）→ Vision OCR（本地推理）
        var pieces: [String] = []
        for index in 0..<min(document.pageCount, ocrPageLimit) {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let scale: CGFloat = 150.0 / 72.0
            let size = NSSize(width: max(bounds.width * scale, 200), height: max(bounds.height * scale, 200))
            let image = page.thumbnail(of: size, for: .mediaBox)
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let recognized = try Self.recognize(cgImage)
            if !recognized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { pieces.append(recognized) }
        }
        // OCR 一无所获（纯图形页等）则如实返回文本层（可能为空，由上层跳过观测）
        return pieces.isEmpty ? textLayer : pieces.joined(separator: "\n")
    }
    static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

// MARK: - 图片 OCR（Apple Vision，本地，中+英）

public struct VisionOCRExtractor: ContentExtracting {
    public let profile = "ocr-vision-v1"
    /// 可提取扩展名（公开静态：范围选择器的成本预估共用）
    public static let supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "bmp"]
    let extensions: Set<String> = VisionOCRExtractor.supportedExtensions
    public init() {}
    public func canExtract(fileName: String) -> Bool {
        extensions.contains((fileName as NSString).pathExtension.lowercased())
    }
    public func extract(at url: URL) throws -> String {
        let request = Self.makeRequest()
        let handler = VNImageRequestHandler(url: url, options: [:])
        try handler.perform([request])
        return Self.join(request)
    }
    /// 对内存图像做同配置 OCR（视频帧共用；解码失败由调用方处理）。
    public static func recognize(_ image: CGImage) throws -> String {
        let request = makeRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return join(request)
    }
    private static func makeRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        return request
    }
    private static func join(_ request: VNRecognizeTextRequest) -> String {
        (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

// MARK: - 视频帧 OCR（L2：AVFoundation 抽帧 → Vision OCR → 相邻同文合并为时间段）

/// 第一性原理：视频=时间序列画面，画面文字有持续性（标题/幻灯片 ≥5s，字幕 ≥2s）。
/// 按固定间隔抽帧，相邻帧文本相同即合并为一个 [start, end) 时间段；成本比单图高两个数量级
/// → 每视频封顶帧数（超长视频自动放宽间隔），且默认关闭、用户显式开启（PRD：视频走质量门禁）。
/// 全部本地解码与识别，零上传。
public struct VideoFrameOCRExtractor: ContentExtracting {
    public let profile = "video-frame-ocr-v1"
    /// AVFoundation 原生可解码的容器；mkv/avi 等不在列（解码失败会被记 failed，不如不排）
    public static let supportedExtensions: Set<String> = ["mp4", "mov", "m4v"]
    /// 抽帧间隔（秒）。3s 兼顾字幕召回与成本；测试可调密。
    public var sampleInterval: TimeInterval = 3
    /// 每视频最多 OCR 帧数——成本上限（~120 帧 ≈ 1–2 分钟/视频 @1 路）；更长视频按时长放宽间隔。
    public var maxFrames = 120
    /// 抽帧最长边（OCR 够用，控解码成本）
    public var maxDimension: CGFloat = 1280
    public var watchdogSeconds: TimeInterval { 900 }
    public init() {}
    public func canExtract(fileName: String) -> Bool {
        Self.supportedExtensions.contains((fileName as NSString).pathExtension.lowercased())
    }
    public func extract(at url: URL) throws -> String {
        (try extractSegments(at: url) ?? []).map(\.text).joined(separator: "\n")
    }
    public func extractSegments(at url: URL) throws -> [TimedText]? {
        let asset = AVURLAsset(url: url)
        let duration = CMTimeGetSeconds(asset.duration)
        guard duration.isFinite, duration > 0 else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        let interval = max(sampleInterval, duration / Double(maxFrames))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero   // 精确到采样时刻：时间码可信
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        var segments: [TimedText] = []
        var time: TimeInterval = 0
        var frames = 0
        while time < duration, frames < maxFrames {
            frames += 1
            var text = ""
            if let image = try? generator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil) {
                text = (try? VisionOCRExtractor.recognize(image)) ?? ""   // 单帧失败不中断整段
            }
            let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let startMs = Int(time * 1000)
            let endMs = Int(min(duration, time + interval) * 1000)
            if !normalized.isEmpty {
                if let last = segments.last, last.text == normalized {
                    segments[segments.count - 1] = TimedText(startMs: last.startMs, endMs: endMs, text: normalized)
                } else {
                    segments.append(TimedText(startMs: startMs, endMs: endMs, text: normalized))
                }
            }
            time += interval
        }
        return segments
    }
}

// MARK: - 注册表

/// 按扩展名选第一个能处理的提取器；均不处理返回 nil（该资产无内容索引）。
public struct ContentExtractorRegistry {
    public let extractors: [ContentExtracting]
    public init(extractors: [ContentExtracting] = [PlainTextExtractor(), PDFTextExtractor(), VisionOCRExtractor()]) {
        self.extractors = extractors
    }
    /// 标准组合；视频帧 OCR 按开关加入（默认关：成本高，需用户显式开启）。
    public static func standard(videoOCR: Bool) -> ContentExtractorRegistry {
        var list: [ContentExtracting] = [PlainTextExtractor(), PDFTextExtractor(), VisionOCRExtractor()]
        if videoOCR { list.append(VideoFrameOCRExtractor()) }
        return ContentExtractorRegistry(extractors: list)
    }
    public func extractor(for fileName: String) -> ContentExtracting? {
        extractors.first { $0.canExtract(fileName: fileName) }
    }
}
