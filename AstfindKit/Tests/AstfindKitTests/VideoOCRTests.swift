import XCTest
import AppKit
import AVFoundation
@testable import AstfindKit

/// L2 视频帧 OCR（动刀清单 2 号）。D0 式装置：合成视频按秒写入已知文字画面（1 fps，H.264），
/// 时间码/去重/封顶/门禁全部可确定性验证；顺带测单帧 OCR 耗时定参。
final class VideoOCRTests: XCTestCase {
    private var home: URL!
    private var share: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("astfind-video-\(UUID().uuidString)")
        share = home.appendingPathComponent("视频库")
        try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: 合成视频装置

    /// 每个元素=该秒画面上的文字（nil=空白帧）；1 fps，时长=元素数（秒）。
    private func makeVideo(at url: URL, secondsText: [String?]) throws {
        let width = 640, height = 360
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        XCTAssertTrue(writer.canAdd(input)); writer.add(input)
        XCTAssertTrue(writer.startWriting(), "\(writer.error.map { "\($0)" } ?? "")")
        writer.startSession(atSourceTime: .zero)
        for (second, text) in secondsText.enumerated() {
            let buffer = try makeFrame(text: text, width: width, height: height, pool: adaptor.pixelBufferPool)
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(seconds: Double(second), preferredTimescale: 600)))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 30), .success)
        XCTAssertEqual(writer.status, .completed, "\(writer.error.map { "\($0)" } ?? "")")
    }

    private func makeFrame(text: String?, width: Int, height: Int, pool: CVPixelBufferPool?) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) }
        if buffer == nil {
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32ARGB,
                                [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary, &buffer)
        }
        let pixel = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        let context = try XCTUnwrap(CGContext(
            data: CVPixelBufferGetBaseAddress(pixel), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setFillColor(CGColor.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let text {
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            (text as NSString).draw(at: NSPoint(x: 40, y: 150),
                withAttributes: [.font: NSFont.systemFont(ofSize: 48, weight: .medium), .foregroundColor: NSColor.black])
            NSGraphicsContext.restoreGraphicsState()
        }
        return pixel
    }

    // MARK: 提取器（D0 定参）

    /// 时间码与去重：相邻同文帧合并为一段，段起止贴合画面切换；顺带报告单帧 OCR 耗时。
    func testSegmentsMergeConsecutiveFramesWithTimecodes() throws {
        let url = share.appendingPathComponent("讲座.mp4")
        try makeVideo(at: url, secondsText: Array(repeating: "第一章 绪论", count: 6) + Array(repeating: "第二章 研究方法", count: 6))
        var extractor = VideoFrameOCRExtractor()
        extractor.sampleInterval = 1
        let began = Date()
        let segments = try XCTUnwrap(try extractor.extractSegments(at: url))
        let elapsed = Date().timeIntervalSince(began)
        print("METRIC video-ocr frames=12 total=\(String(format: "%.2f", elapsed))s per-frame=\(String(format: "%.0f", elapsed / 12 * 1000))ms")

        XCTAssertEqual(segments.count, 2, "两段文字 → 两个时间段（相邻同文 6 帧各合并为 1 段）：\(segments)")
        let first = try XCTUnwrap(segments.first), second = try XCTUnwrap(segments.last)
        XCTAssertTrue(first.text.contains("第一章"), first.text)
        XCTAssertTrue(second.text.contains("第二章"), second.text)
        XCTAssertEqual(first.startMs, 0)
        XCTAssertLessThanOrEqual(abs(first.endMs - 6000), 1000, "第一段覆盖到画面切换处：\(first)")
        XCTAssertLessThanOrEqual(abs(second.startMs - 6000), 1000, "第二段从切换处开始：\(second)")
        XCTAssertLessThanOrEqual(abs(second.endMs - 12000), 1000, "\(second)")
    }

    /// 空白帧不产段；封顶：30s 视频 maxFrames=10 → 间隔自动放宽到 3s（成本上限成立），仍抓到两段文字。
    func testBlankFramesDroppedAndFrameCapWidensInterval() throws {
        let url = share.appendingPathComponent("长片.mp4")
        var frames = [String?](repeating: nil, count: 30)
        for i in 0..<3 { frames[i] = "开场 标题卡" }
        for i in 21..<24 { frames[i] = "片尾 鸣谢名单" }
        try makeVideo(at: url, secondsText: frames)
        var extractor = VideoFrameOCRExtractor()
        extractor.sampleInterval = 1
        extractor.maxFrames = 10
        let segments = try XCTUnwrap(try extractor.extractSegments(at: url))
        XCTAssertEqual(segments.count, 2, "空白帧不产段：\(segments)")
        XCTAssertTrue(segments.allSatisfy { $0.startMs % 3000 == 0 }, "采样点落在 3s 网格 = 间隔已按封顶放宽：\(segments)")
        XCTAssertEqual(segments[0].startMs, 0)
        XCTAssertEqual(segments[1].startMs, 21000)
    }

    // MARK: 端到端 + 门禁

    /// 开启后：视频入队→抽取→内容搜索命中带时间码（面板标签【视频帧 @00:06】）。
    func testVideoHitCarriesTimecodeEndToEnd() throws {
        try makeVideo(at: share.appendingPathComponent("讲座.mp4"),
                      secondsText: Array(repeating: "第一章 绪论", count: 6) + Array(repeating: "第二章 研究方法", count: 6))
        let engine = try AstfindEngine(home: home.appendingPathComponent("data"))
        engine.autoExtractContent = false
        engine.setVideoOCR(enabled: true, persist: false)
        let record = try engine.register(path: share.path, name: "视频库")
        let summary = try XCTUnwrap(engine.extractContent(sourceId: record.sourceId))
        XCTAssertEqual(summary.extracted, 1, "视频被当作内容资产抽取")
        let hits = engine.contentSearch("研究方法")
        let hit = try XCTUnwrap(hits.first { $0.textKind == "video" }, "命中类型应为 video：\(hits)")
        XCTAssertEqual(hit.relativePath, "讲座.mp4")
        XCTAssertLessThanOrEqual(abs(try XCTUnwrap(hit.startMs) - 6000), 3000, "命中带该段起始时间码：\(hit)")
        XCTAssertEqual(ContentSupplementaryProvider.timecode(6000), "00:06")
        XCTAssertEqual(ContentSupplementaryProvider.timecode(3_725_000), "1:02:05")
        XCTAssertGreaterThanOrEqual(engine.contentSearch("第一章").count, 1, "另一段也可搜")
        engine.stop()
    }

    /// 质量门禁：默认关——视频不入队；开启即入队；关闭清掉未处理视频任务（图片任务不受影响）。
    func testVideoOCRGateDefaultOffAndToggleClearsPending() throws {
        try makeVideo(at: share.appendingPathComponent("讲座.mp4"), secondsText: Array(repeating: "门禁测试", count: 4))
        try "正文".write(to: share.appendingPathComponent("说明.txt"), atomically: true, encoding: .utf8)
        let engine = try AstfindEngine(home: home.appendingPathComponent("data"))
        engine.autoExtractContent = false
        XCTAssertFalse(engine.videoOCREnabled, "默认关（成本高，需用户显式开启）")
        let record = try engine.register(path: share.path, name: "视频库")
        _ = engine.extractContent(sourceId: record.sourceId, limit: 0)
        XCTAssertEqual(try XCTUnwrap(engine.content).pendingCount(), 1, "只有 txt 入队，视频不排")

        engine.setVideoOCR(enabled: true, persist: false)
        _ = engine.extractContent(sourceId: record.sourceId, limit: 0)
        XCTAssertEqual(try XCTUnwrap(engine.content).pendingCount(), 2, "开启后视频入队")

        engine.setVideoOCR(enabled: false, persist: false)
        XCTAssertEqual(try XCTUnwrap(engine.content).pendingCount(), 1, "关闭清掉未处理视频任务，txt 任务保留")
        XCTAssertFalse(engine.videoOCREnabled)
        engine.stop()
    }
}
