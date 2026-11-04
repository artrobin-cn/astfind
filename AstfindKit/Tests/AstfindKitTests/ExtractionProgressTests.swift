import XCTest
import AppKit
@testable import AstfindKit

/// 动刀清单 3 号：抽取进度可视化——引擎在干活必须看得见（2026-10-20 晚痛点实锤）。
/// 真相=index_jobs 各态计数（只读连接）；速率/预计=引擎滚动窗口。
final class ExtractionProgressTests: XCTestCase {
    private var home: URL!
    private var shareA: URL!
    private var shareB: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("astfind-progress-\(UUID().uuidString)")
        shareA = home.appendingPathComponent("甲")
        shareB = home.appendingPathComponent("乙")
        try FileManager.default.createDirectory(at: shareA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shareB, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func makeImage(text: String, at url: URL) throws {
        let size = NSSize(width: 480, height: 140)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        (text as NSString).draw(at: NSPoint(x: 30, y: 50),
            withAttributes: [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black])
        image.unlockFocus()
        let data = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?
            .representation(using: .png, properties: [:]))
        try data.write(to: url)
    }

    /// 入队后可见 pending/剩余；处理后 done 增长、剩余归零、速率有值、预计消失；按剩余量降序。
    func testProgressReflectsJobStatesAndThroughput() throws {
        try makeImage(text: "进度甲", at: shareA.appendingPathComponent("a.png"))
        try makeImage(text: "进度乙一", at: shareB.appendingPathComponent("b1.png"))
        try makeImage(text: "进度乙二", at: shareB.appendingPathComponent("b2.png"))
        let engine = try AstfindEngine(home: home.appendingPathComponent("data"))
        engine.autoExtractContent = false
        let a = try engine.register(path: shareA.path, name: "甲")
        let b = try engine.register(path: shareB.path, name: "乙")
        _ = engine.extractContent(limit: 0)   // 只入队

        var progress = engine.extractionProgress()
        XCTAssertEqual(progress.map(\.displayName), ["乙", "甲"], "剩余多的排前")
        let queuedA = try XCTUnwrap(progress.first { $0.sourceId == a.sourceId })
        XCTAssertEqual(queuedA.pending, 1); XCTAssertEqual(queuedA.remaining, 1); XCTAssertEqual(queuedA.done, 0)
        XCTAssertNil(queuedA.ratePerMinute, "尚未处理：无速率")
        XCTAssertNil(queuedA.etaSeconds, "无速率则不给预计（不猜）")
        XCTAssertEqual(progress.first { $0.sourceId == b.sourceId }?.pending, 2)

        _ = engine.extractContent(sourceId: a.sourceId)   // 只处理甲
        progress = engine.extractionProgress()
        let doneA = try XCTUnwrap(progress.first { $0.sourceId == a.sourceId })
        XCTAssertEqual(doneA.done, 1); XCTAssertEqual(doneA.remaining, 0)
        XCTAssertNotNil(doneA.ratePerMinute, "处理过即有窗口速率")
        XCTAssertNil(doneA.etaSeconds, "无剩余则无预计")
        let waitingB = try XCTUnwrap(progress.first { $0.sourceId == b.sourceId })
        XCTAssertEqual(waitingB.remaining, 2)
        XCTAssertEqual(waitingB.done, 0)
        XCTAssertEqual(progress.first?.sourceId, b.sourceId, "乙仍有剩余，排首位")
        engine.stop()
    }

    /// 失败抽查：损坏图片进 failed 终态，样本接口给出相对路径（辨别 ._ 垃圾 vs 真失败）。
    func testFailedSamplesExposeRelativePaths() throws {
        try makeImage(text: "正常图片", at: shareA.appendingPathComponent("good.png"))
        try Data((0..<256).map { _ in UInt8.random(in: 0...255) }).write(to: shareA.appendingPathComponent("bad.png"))
        let engine = try AstfindEngine(home: home.appendingPathComponent("data"))
        engine.autoExtractContent = false
        let a = try engine.register(path: shareA.path, name: "甲")
        let summary = try XCTUnwrap(engine.extractContent(sourceId: a.sourceId))
        XCTAssertEqual(summary.failed, 1)
        let progress = try XCTUnwrap(engine.extractionProgress().first { $0.sourceId == a.sourceId })
        XCTAssertEqual(progress.failed, 1)
        XCTAssertEqual(progress.done, 1)
        XCTAssertEqual(engine.failedExtractionSamples(sourceId: a.sourceId), ["bad.png"])
        engine.stop()
    }
}
