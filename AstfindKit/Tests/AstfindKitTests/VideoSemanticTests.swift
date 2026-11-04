import XCTest
import AppKit
import AVFoundation
import OilFindCore
import AstfindPanel
@testable import AstfindKit

/// A2 纵切之二：视频画面语义——帧采样 → 批量向量 → 逐帧段落库 → 检索带时间码。
/// 合成视频：前 4 秒纯红、后 4 秒纯蓝；假 Provider 按帧平均色出向量（零网络）。
final class VideoSemanticTests: XCTestCase {
    private var home: URL!
    private var share: URL!
    private let profile = EmbeddingIndexer.Profile.image(providerId: "color", model: "color-v1", dimension: 3)

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("astfind-video-semantic-\(UUID().uuidString)")
        share = home.appendingPathComponent("视频库")
        try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    /// 「红色的画面」→ 命中视频且时间码落在红段；「蓝」→ 蓝段；同视频多帧命中面板按资产去重取最佳帧并带 @时间码。
    func testVideoFramesEmbeddedAndSearchableWithTimecode() throws {
        let video = share.appendingPathComponent("开场.mp4")
        try makeColorVideo(at: video, secondsColors: Array(repeating: NSColor.red, count: 4) + Array(repeating: NSColor.blue, count: 4))

        let engine = try AstfindEngine(home: home.appendingPathComponent("data"))
        engine.autoExtractContent = false
        let record = try engine.register(path: share.path, name: "视频库")
        let semantic = try XCTUnwrap(engine.semantic)
        semantic.videoSampleInterval = 1      // 测试用密采样（生产 10s）
        semantic.videoMaxFrames = 100
        try semantic.ensureProfile(profile)

        // 任务隔离：视频不进图片队列；视频入队一次，重复入队为 0（token 幂等）
        XCTAssertEqual(try semantic.enqueuePending(sourceId: record.sourceId, profile: profile), 0, "mp4 不是图片任务")
        XCTAssertEqual(try semantic.enqueuePendingVideos(sourceId: record.sourceId, profile: profile), 1)
        XCTAssertEqual(try semantic.enqueuePendingVideos(sourceId: record.sourceId, profile: profile), 0, "已有任务不重复入队")

        let provider = EmbeddingTests.ColorProvider()
        provider.capabilities.batchImages = 4   // 8 帧 → 2 批（批量路径）
        provider.nativeBatch = true
        let summary = try semantic.runPendingVideo(limit: 3, sourceId: record.sourceId, lanes: 1, provider: provider, profile: profile)
        XCTAssertEqual(summary.embedded, 1, "整视频作为一个任务完成：\(summary)")
        XCTAssertEqual(summary.failed, 0)
        XCTAssertEqual(provider.batchCalls.sorted(), [4, 4], "8 帧按批量 4 分两请求：\(provider.batchCalls)")
        XCTAssertEqual(try semantic.videoCounts().done, 1)
        XCTAssertEqual(semantic.embeddingCount(profile: profile), 8, "逐帧落库 8 个向量")

        // 红查询 → 红段帧（0–3s）；蓝查询 → 蓝段帧（4–7s）；命中类型为 video 且带时间码
        let redHits = try semantic.search(queryVector: [1, 0, 0], profile: profile, limit: 4)
        XCTAssertEqual(redHits.count, 4)
        for hit in redHits {
            XCTAssertEqual(hit.kind, "video")
            XCTAssertEqual(hit.relativePath, "开场.mp4")
            XCTAssertGreaterThan(hit.score, 0.9)
            XCTAssertLessThan(try XCTUnwrap(hit.startMs), 4000, "红段时间码：\(hit)")
        }
        let blueHits = try semantic.search(queryVector: [0, 0, 1], profile: profile, limit: 4)
        for hit in blueHits {
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(hit.startMs), 4000, "蓝段时间码：\(hit)")
        }

        // 再次入队：向量 token 未变 → 0（变更检测）
        XCTAssertEqual(try semantic.enqueuePendingVideos(sourceId: record.sourceId, profile: profile), 0)

        // 面板补充通道：同视频 4 帧命中按资产去重为 1 行，标签带 @时间码
        engine.providers.addEmbeddingProvider(provider)
        engine.providers.record(probe: .available(latencyMs: 1, capabilities: provider.capabilities), id: provider.id)
        engine.setSemanticSearch(enabled: true, persist: false)
        let supplementary = ContentSupplementaryProvider(engine: engine)
        let refreshed = expectation(description: "语义就绪回调")
        engine.onSupplementaryRefresh = { refreshed.fulfill() }
        _ = supplementary.prepareSearch(Query.parse("红色的画面"), options: SearchOptions(),
                                        sources: engine.sources(), isCancelled: { false })()
        wait(for: [refreshed], timeout: 15)
        let rows = supplementary.prepareSearch(Query.parse("红色的画面"), options: SearchOptions(),
                                               sources: engine.sources(), isCancelled: { false })()
        let semanticRows = rows.filter { $0.detail.contains("语义") }
        XCTAssertEqual(semanticRows.count, 1, "同视频多帧去重为一行：\(rows.map(\.detail))")
        let detail = try XCTUnwrap(semanticRows.first?.detail)
        XCTAssertTrue(detail.contains("@00:0"), "视频语义命中应带时间码：\(detail)")
        XCTAssertTrue(detail.hasSuffix("开场.mp4"), detail)
        engine.stop()
    }

    // MARK: 合成彩色视频装置（1 fps；每元素=该秒画面纯色）

    private func makeColorVideo(at url: URL, secondsColors: [NSColor]) throws {
        let width = 320, height = 180
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
        for (second, color) in secondsColors.enumerated() {
            let buffer = try makeFrame(color: color, width: width, height: height, pool: adaptor.pixelBufferPool)
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(seconds: Double(second), preferredTimescale: 600)))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 30), .success)
        XCTAssertEqual(writer.status, .completed, "\(writer.error.map { "\($0)" } ?? "")")
    }

    private func makeFrame(color: NSColor, width: Int, height: Int, pool: CVPixelBufferPool?) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) }
        if buffer == nil {
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32ARGB,
                                [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary, &buffer)
        }
        let pixel = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        let context = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel),
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setFillColor(color.usingColorSpace(.deviceRGB)!.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return pixel
    }
}
