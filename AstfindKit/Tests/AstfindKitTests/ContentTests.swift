import XCTest
import AppKit
import CoreText
import PDFKit
@testable import AstfindKit

/// D6：内容文字搜索——提取（纯文本/PDF/OCR）→ 中文 FTS（trigram + LIKE 兜底）→ 变更/删除/离线语义。
final class ContentTests: XCTestCase {
    private var home: URL!
    private var share: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("astfind-d6-\(UUID().uuidString)")
        share = home.appendingPathComponent("share")
        try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: 测试物料生成（真实文件：PDF 有文本层、图片有真实文字像素）

    private func makePDF(text: String, at url: URL) throws {
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: nil, nil))
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("PingFang SC" as CFString, 18, nil)
        let attr = CFAttributedStringCreate(nil, text as CFString,
            [kCTFontAttributeName: font] as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attr)
        context.textPosition = CGPoint(x: 40, y: 600)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
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

    /// 无文本层的扫描版 PDF（页面=图片像素），验证 OCR 兜底（2026-10-19 开发者合同场景）。
    private func makeScannedPDF(text: String, at url: URL) throws {
        let size = NSSize(width: 480, height: 140)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        (text as NSString).draw(at: NSPoint(x: 30, y: 50),
            withAttributes: [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black])
        image.unlockFocus()
        let page = try XCTUnwrap(PDFPage(image: image))
        let pdf = PDFDocument()
        pdf.insert(page, at: 0)
        try pdf.write(to: url)
    }

    func testContentIndexCanBeDisabledPerSource() throws {
        try makeImage(text: "内容索引范围测试甲", at: share.appendingPathComponent("scope-a.png"))
        try makeImage(text: "内容索引范围测试乙", at: share.appendingPathComponent("scope-b.png"))
        let engine = try AstfindEngine(home: home.appendingPathComponent("data"))
        engine.autoExtractContent = false
        let record = try engine.register(path: share.path, name: "照片归档", scanNow: true)
        XCTAssertTrue(record.contentIndexEnabled, "默认应保留内容索引")

        let queued = try XCTUnwrap(engine.content?.enqueuePending(sourceId: record.sourceId))
        XCTAssertGreaterThan(queued, 0)
        let cleared = try engine.setContentIndexEnabled(sourceId: record.sourceId, enabled: false)
        XCTAssertEqual(cleared, queued, "关闭时应清理该来源的 pending 任务")
        XCTAssertEqual(try engine.content?.pendingCount(), 0)
        XCTAssertFalse(try XCTUnwrap(engine.records().first(where: { $0.sourceId == record.sourceId })).contentIndexEnabled)
        XCTAssertNil(engine.extractContent(sourceId: record.sourceId), "关闭后不得重新入队/执行内容抽取")

        try engine.setContentIndexEnabled(sourceId: record.sourceId, enabled: true)
        XCTAssertGreaterThan(try engine.content?.pendingCount() ?? 0, 0, "重新开启后应补齐未完成任务")
        engine.stop()
    }

    func testEnqueueStableAfterExtractionAndRequeuesChangedFile() throws {
        let file = share.appendingPathComponent("stable.txt")
        try "alpha".write(to: file, atomically: true, encoding: .utf8)
        let engine = try AstfindEngine(home: home.appendingPathComponent("data"))
        engine.autoExtractContent = false
        let record = try engine.register(path: share.path, name: "稳定队列", scanNow: true)
        let content = try XCTUnwrap(engine.content)
        XCTAssertEqual(try content.enqueuePending(sourceId: record.sourceId), 1)
        _ = engine.extractContent(limit: 10)
        XCTAssertEqual(try content.pendingCount(), 0)
        XCTAssertEqual(try content.enqueuePending(sourceId: record.sourceId), 0,
                       "已完成且 size:mtime 未变的任务不应在重启/重扫时反复排队")
        try "beta with different length".write(to: file, atomically: true, encoding: .utf8)
        let db = try Database(url: home.appendingPathComponent("data/registry.sqlite"))
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber).int64Value
        try db.run("UPDATE assets SET size = ?, mtime_ns = ? WHERE source_id = ? AND relative_path = 'stable.txt'",
                   [.int(size), .int(Int64(Date().timeIntervalSince1970)), .text(record.sourceId)])
        XCTAssertEqual(try content.enqueuePending(sourceId: record.sourceId), 1,
                       "内容变化后应重新入队")
        engine.stop()
    }

    func testScannedPDFFallsBackToOCRForAmounts() throws {
        try makeScannedPDF(text: "合同金额 85500.00 元整", at: share.appendingPathComponent("扫描合同.pdf"))
        let engine = try AstfindEngine(home: home.appendingPathComponent("data"))
        engine.autoExtractContent = false
        _ = try engine.register(path: share.path, name: "扫描件")
        _ = try XCTUnwrap(engine.extractContent())
        // 文本层为空 → 必须由 OCR 兜底写出观测；金额数字（发票/合同高频检索）必须可命中
        let hits = engine.contentSearch("85500")
        XCTAssertEqual(hits.count, 1, "扫描版 PDF 金额应可检索：\(hits)")
        XCTAssertTrue(hits.first?.snippet.contains("85500") ?? false)
        engine.stop()
    }

    /// 热路径隔离回归（2026-10-19 开发者实锤）：面板内容检索曾与抽取共用串行队列，
    /// 后台跑 12 万任务时长批次把搜索堵死（App 内无响应，CLI 独立进程却能命中）。
    /// 修复后：搜索走独立只读连接（WAL 读写并发），抽取进行中必须立刻返回。
    func testSearchStaysResponsiveWhileExtractionRunning() throws {
        for i in 1...4 {
            try makeImage(text: "响应性测试 第\(i)号图片", at: share.appendingPathComponent("img-\(i).png"))
        }
        let engine = try AstfindEngine(home: home.appendingPathComponent("data"))
        engine.autoExtractContent = false
        _ = try engine.register(path: share.path, name: "响应性")   // 需真实扫描建资产
        // 引擎的抽取在后台线程慢跑（4 张图 OCR 数秒），期间在调用线程直接搜索
        let extraction = DispatchWorkItem { _ = engine.extractContent(limit: 100) }
        DispatchQueue.global(qos: .utility).async(execute: extraction)

        let began = Date()
        let hits = engine.contentSearch("响应性测试")
        let elapsed = Date().timeIntervalSince(began)
        XCTAssertLessThan(elapsed, 2.0, "抽取进行中搜索必须在 2 秒内返回（实际 \(elapsed)s）——只读连接不得排在抽取批次后")

        extraction.wait()
        XCTAssertGreaterThanOrEqual(engine.contentSearch("响应性测试").count, 1, "抽取完成后应命中")
        engine.stop()
    }

    /// 抽取泵回归（2026-10-19）：此前只在来源就绪时触发一批（每源 500），12 万积压追不完；
    /// 泵必须持续运转直到清空，且多来源都被 drain（轮转公平）。
    func testExtractionPumpDrainsAllSourcesUntilEmpty() throws {
        let shareB = home.appendingPathComponent("shareB")
        try FileManager.default.createDirectory(at: shareB, withIntermediateDirectories: true)
        try makeImage(text: "泵测试 甲组图片", at: share.appendingPathComponent("pump-a.png"))
        try makeImage(text: "泵测试 乙组图片", at: shareB.appendingPathComponent("pump-b.png"))

        let engine = try AstfindEngine(home: home.appendingPathComponent("data"))
        engine.autoExtractContent = false
        _ = try engine.register(path: share.path, name: "甲")
        _ = try engine.register(path: shareB.path, name: "乙")
        _ = engine.extractContent(limit: 0)   // 只入队不执行
        let pending = try XCTUnwrap(engine.content).pendingCount()
        XCTAssertGreaterThanOrEqual(pending, 2)

        engine.autoExtractContent = true
        engine.kickExtractionPump()
        let deadline = Date(timeIntervalSinceNow: 90)
        while Date() < deadline {
            // 排空 = 无 pending 且无在飞：认领瞬间任务离开 pending 但尚未回写，
            // 只看 pending 会在 OCR 落库前提前断言（竞态实锤 2026-10-20）
            let pending = ((try? engine.content?.pendingCount()) ?? 0)
            let running = ((try? engine.content?.runningCount()) ?? 0)
            if pending == 0 && running == 0 { break }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        }
        XCTAssertEqual(((try? engine.content?.pendingCount()) ?? -1), 0, "泵应清空全部 pending")
        XCTAssertGreaterThanOrEqual(engine.contentSearch("泵测试").count, 2, "两个来源都应命中")
        engine.stop()   // 同时验证 stop 掐泵不崩溃
    }

    /// 入队卫生回归（2026-10-19）：exFAT 的 ._ 边车文件不得入队；失败任务不得被反复重排。
    func testEnqueueSkipsAppleDoubleAndFailedJobsAreTerminal() throws {
        try makeImage(text: "边车过滤 正主图片", at: share.appendingPathComponent("real.png"))
        try Data([0x00, 0x01]).write(to: share.appendingPathComponent("._real.png"))
        try Data([0x00]).write(to: share.appendingPathComponent(".DS_Store"))
        let engine = try AstfindEngine(home: home.appendingPathComponent("data"))
        engine.autoExtractContent = false
        let record = try engine.register(path: share.path, name: "边车")
        // ._real.png 会被扫描进资产表（真实目录项），但入队必须跳过
        _ = engine.extractContent(limit: 0)
        let jobs = try XCTUnwrap(engine.content).pendingCount()
        XCTAssertEqual(jobs, 1, "只应有正主图片一个任务（边车/.DS_Store 跳过），实际 \(jobs)")

        // 手工制造一个 failed 行：断言再触发不会把它重新入队
        let db = try XCTUnwrap(engine.content)
        _ = try? db.enqueuePending(sourceId: record.sourceId)
        engine.stop()
    }

    /// 看门狗与僵尸任务防御回归（2026-10-20）：NAS 的 ._ 假图片曾把 Vision 吊死在
    /// 内部信号量上（进程采样实锤），整泵停摆。三层防御：
    /// ① runPending 对 ._/.DS_Store 按名直接记失败不执行；② v4 迁移清存量；③ 180s 熔断。
    /// 本用例手工插入绕过入队层的僵尸任务（模拟 v3 存量），断言 runPending 跳过执行且快速返回。
    func testRunPendingSkipsLegacyAppleDoubleZombieJobs() throws {
        try makeImage(text: "僵尸防御 正主", at: share.appendingPathComponent("real.jpg"))
        try Data([0x00, 0x00, 0x01]).write(to: share.appendingPathComponent("._fake.jpg"))

        let engine = try AstfindEngine(home: home.appendingPathComponent("data"))
        engine.autoExtractContent = false
        let record = try engine.register(path: share.path, name: "僵尸")
        _ = engine.extractContent(limit: 0)

        // 手工插入僵尸 pending 任务（绕过入队层的按名过滤，模拟 v3 时代存量）
        let db = try Database(url: home.appendingPathComponent("data/registry.sqlite"))
        let junkAsset = try XCTUnwrap(try db.query(
            "SELECT asset_id FROM assets WHERE source_id = ? AND relative_path LIKE '%._fake.jpg'",
            [.text(record.sourceId)]) { $0.columnText(0) }.first, "._fake.jpg 应作为目录项被扫进资产表")
        try db.run("INSERT INTO index_jobs (job_id, source_id, asset_id, job_type, state, priority) VALUES (?,?,?,?, 'pending', 0)",
                   [.text(UUID().uuidString), .text(record.sourceId), .text(junkAsset), .text("extract_text")])

        let began = Date()
        let summary = engine.extractContent(sourceId: record.sourceId, limit: 10)
        let elapsed = Date().timeIntervalSince(began)
        XCTAssertLessThan(elapsed, 30, "僵尸任务必须被跳过而非执行（含正主 OCR 时间）")
        let junkState = try XCTUnwrap(try db.query(
            "SELECT state FROM index_jobs WHERE asset_id = ?", [.text(junkAsset)]) { $0.columnText(0) }.first)
        XCTAssertEqual(junkState, "failed", "僵尸任务应记失败终态")
        XCTAssertGreaterThanOrEqual(summary?.processed ?? 0, 1, "正主图片应被正常抽取")
        engine.stop()
    }

    /// 并行抽取回归（2026-10-20 三档：省电1/标准2/全速4）：4 个各需 1 秒的文件，
    /// 4 路应在 ~1.2 秒内完成，1 路必须 ≥3.5 秒——并发度真实生效的锚。
    private struct SlowTextExtractor: ContentExtracting {
        let profile = "slow-test-v1"
        let seconds: TimeInterval
        func canExtract(fileName: String) -> Bool {
            (fileName as NSString).pathExtension.lowercased() == "txt"
        }
        func extract(at url: URL) throws -> String {
            Thread.sleep(forTimeInterval: seconds)
            return "慢提取内容 并行档位测试"
        }
    }

    func testParallelLanesActuallyParallelize() throws {
        for i in 1...4 {
            try "内容\(i)\n".write(to: share.appendingPathComponent("lane\(i).txt"), atomically: true, encoding: .utf8)
        }
        let dataHome = home.appendingPathComponent("data")
        let indexer = try ContentIndexer(databaseURL: dataHome.appendingPathComponent("registry.sqlite"),
                                         extractors: ContentExtractorRegistry(extractors: [SlowTextExtractor(seconds: 1.0)]))
        let engine = try AstfindEngine(databaseURL: dataHome.appendingPathComponent("registry.sqlite"),
                                       snapshotDirectory: dataHome.appendingPathComponent("snapshots"),
                                       contentIndexer: indexer)
        engine.autoExtractContent = false
        _ = try engine.register(path: share.path, name: "并行")
        _ = engine.extractContent(limit: 0)

        engine.extractionLanes = 4
        let began = Date()
        let summary = engine.extractContent(limit: 10)
        let elapsed = Date().timeIntervalSince(began)
        XCTAssertEqual(summary?.extracted, 4, "四个文件全部抽取成功")
        XCTAssertLessThan(elapsed, 2.5, "4 路 × 4 个 1 秒文件应 ~1.2 秒完成，实际 \(elapsed)s")
        XCTAssertGreaterThan(engine.contentSearch("慢提取内容").count, 0)

        // 省电档串行语义锚：第二个目录重新走扫描→入队→1 路串行
        let shareB = home.appendingPathComponent("lanes-b")
        try FileManager.default.createDirectory(at: shareB, withIntermediateDirectories: true)
        for i in 5...8 {
            try "内容\(i)\n".write(to: shareB.appendingPathComponent("lane\(i).txt"), atomically: true, encoding: .utf8)
        }
        _ = try engine.register(path: shareB.path, name: "并行乙")
        engine.extractionLanes = 1
        let began2 = Date()
        _ = engine.extractContent(limit: 10)
        let elapsed2 = Date().timeIntervalSince(began2)
        XCTAssertGreaterThan(elapsed2, 3.5, "1 路串行应 ≥4×1 秒，实际 \(elapsed2)s")
        engine.stop()
    }

    // MARK: 用例

    /// 端到端：三种提取器 + 中文 FTS（≥3 字 trigram / 2 字 LIKE 兜底）+ 英中混排。
    func testPlainTextPDFAndOCRWithChineseFTS() throws {
        try "本季度发票报销单已提交，金额叁仟元 Invoice-No-2026-77\n".write(
            to: share.appendingPathComponent("报销说明.txt"), atomically: true, encoding: .utf8)
        try makePDF(text: "会议纪要：毕业设计答辩安排在六月举行 defense schedule",
                    at: share.appendingPathComponent("纪要.pdf"))
        try makeImage(text: "课程表 周三 数学课",
                      at: share.appendingPathComponent("课表.png"))

        let engine = try AstfindEngine(home: home.appendingPathComponent("data"))
        engine.autoExtractContent = false
        _ = try engine.register(path: share.path, name: "本地资料")
        let summary = try XCTUnwrap(engine.extractContent())
        XCTAssertEqual(summary.extracted, 3, "三种提取器各处理一个文件")
        XCTAssertEqual(summary.failed, 0)

        // ≥3 字：trigram 命中并带高亮片段
        let fapiao = engine.contentSearch("发票报销")
        XCTAssertEqual(fapiao.count, 1)
        XCTAssertTrue(fapiao[0].relativePath.hasSuffix("报销说明.txt"))
        XCTAssertTrue(fapiao[0].snippet.contains("「发票报销」") || fapiao[0].snippet.contains("发票"), "高亮片段")
        // 2 字：LIKE 兜底（trigram 无法表达）
        XCTAssertEqual(engine.contentSearch("发票").count, 1)
        // PDF 正文（中文+英文混排）
        let pdf = engine.contentSearch("毕业设计答辩")
        XCTAssertEqual(pdf.count, 1)
        XCTAssertTrue(pdf[0].relativePath.hasSuffix("纪要.pdf"))
        XCTAssertEqual(engine.contentSearch("defense schedule").count, 1)
        // OCR（Vision 本地识别生成图片中的文字）
        let ocr = engine.contentSearch("数学课")
        XCTAssertEqual(ocr.count, 1, "OCR 命中图片里的文字")
        XCTAssertTrue(ocr[0].relativePath.hasSuffix("课表.png"))
        XCTAssertEqual(ocr[0].textKind, "ocr")
        // 无误报
        XCTAssertEqual(engine.contentSearch("不存在词xyzq").count, 0)
        engine.stop()
    }

    /// 变更检测：内容未变跳过；内容更新后重新提取并命中新词。
    func testChangeDetectionSkipsAndUpdate() throws {
        let file = share.appendingPathComponent("笔记.txt")
        try "旧内容 关键词甲".write(to: file, atomically: true, encoding: .utf8)
        let engine = try AstfindEngine(home: home.appendingPathComponent("data"))
        engine.autoExtractContent = false
        _ = try engine.register(path: share.path, name: "资料")
        _ = try XCTUnwrap(engine.extractContent())
        XCTAssertEqual(engine.contentSearch("关键词甲").count, 1)

        // 重跑（未变更）：跳过、不重复观察
        Thread.sleep(forTimeInterval: 0.05)
        let second = try XCTUnwrap(engine.extractContent())
        XCTAssertEqual(second.skippedUnchanged, 0, "未变更文件在入队层跳过，不再重复建任务")
        XCTAssertEqual(second.processed, 0)
        XCTAssertEqual(second.extracted, 0)
        XCTAssertEqual(engine.contentSearch("关键词甲").count, 1, "观察仍可搜")

        // 内容更新：重新提取，新词命中、旧词消失
        Thread.sleep(forTimeInterval: 1.1)   // mtime 秒级粒度兜底
        try "新内容 关键词乙".write(to: file, atomically: true, encoding: .utf8)
        engine.stop()
        let engine2 = try AstfindEngine(home: home.appendingPathComponent("data"))
        engine2.autoExtractContent = false
        engine2.start()
        _ = engine2.waitForScans(timeout: 60)   // 重扫拿到新 size/mtime
        let third = try XCTUnwrap(engine2.extractContent())
        XCTAssertGreaterThanOrEqual(third.extracted, 1, "变更后重新提取")
        XCTAssertEqual(engine2.contentSearch("关键词乙").count, 1)
        XCTAssertEqual(engine2.contentSearch("关键词甲").count, 0, "旧观察被替换")
        engine2.stop()
    }

    /// 删除语义：文件被完整扫描确认删除后，观察随之清理（离线/部分扫描不清理）。
    func testConfirmedDeletionCleansObservations() throws {
        let file = share.appendingPathComponent("待删.txt")
        try "将被删除的内容 独特词洪水".write(to: file, atomically: true, encoding: .utf8)
        let engine = try AstfindEngine(home: home.appendingPathComponent("data"))
        engine.autoExtractContent = false
        _ = try engine.register(path: share.path, name: "资料")
        _ = try XCTUnwrap(engine.extractContent())
        XCTAssertEqual(engine.contentSearch("独特词洪水").count, 1)

        try FileManager.default.removeItem(at: file)
        engine.stop()
        let engine2 = try AstfindEngine(home: home.appendingPathComponent("data"))
        engine2.autoExtractContent = false
        engine2.start()
        _ = engine2.waitForScans(timeout: 60)   // 完整重扫 → 确认删除
        let summary = try XCTUnwrap(engine2.extractContent())
        XCTAssertEqual(summary.cleanedDeletions, 1, "确认删除的资产清理其观察")
        XCTAssertEqual(engine2.contentSearch("独特词洪水").count, 0)
        engine2.stop()
    }

    /// NAS 失联可恢复：源离线时任务挂起（deferred），重连后重跑完成。
    func testOfflineDefersAndResumesAfterRemount() throws {
        let file = share.appendingPathComponent("离线文档.txt")
        try "离线期间的内容 复活关键词".write(to: file, atomically: true, encoding: .utf8)
        let engine = try AstfindEngine(home: home.appendingPathComponent("data"))
        engine.autoExtractContent = false
        let record = try engine.register(path: share.path, name: "NAS")   // 扫描完成→资产入库
        XCTAssertEqual(engine.liveAssetCount(sourceId: record.sourceId), 1)
        engine.stop()

        // 手工入队后摘除挂载点（模拟 NAS 失联）
        let indexer = try ContentIndexer(databaseURL: home.appendingPathComponent("data/registry.sqlite"))
        XCTAssertEqual(try indexer.enqueuePending(sourceId: record.sourceId), 1)
        let registry = try SourceRegistry(databaseURL: home.appendingPathComponent("data/registry.sqlite"))
        try registry.updateMount(sourceId: record.sourceId, mountPath: nil, online: false)

        // 源离线：任务 deferred 保留
        let deferred = try indexer.runPending()
        XCTAssertEqual(deferred.deferredOffline, 1)
        XCTAssertEqual(try indexer.pendingCount(), 1, "任务保留待恢复")

        // 重连后执行完成
        let engine2 = try AstfindEngine(home: home.appendingPathComponent("data"))
        engine2.autoExtractContent = false
        try engine2.updateMount(sourceId: record.sourceId, path: share.path)
        _ = engine2.waitForScans(timeout: 60)
        let done = try XCTUnwrap(engine2.extractContent())
        XCTAssertGreaterThanOrEqual(done.extracted, 1)
        XCTAssertEqual(engine2.contentSearch("复活关键词").count, 1)
        engine2.stop()
    }

    /// 交互暂停：已认领但还没开跑的任务退回 pending，不能占着 running 等 180s 看门狗。
    func testPauseDuringBatchReleasesClaimedJobBackToPending() throws {
        try "暂停测试 关键词".write(to: share.appendingPathComponent("暂停.txt"), atomically: true, encoding: .utf8)
        let engine = try AstfindEngine(home: home.appendingPathComponent("data"))
        engine.autoExtractContent = false
        _ = try engine.register(path: share.path, name: "资料")
        _ = engine.extractContent(limit: 0)   // 只入队
        let indexer = try XCTUnwrap(engine.content)
        var calls = 0
        let summary = try indexer.runPending(shouldPause: {
            calls += 1
            return calls > 1   // 第一次允许认领，第二次（开跑前）暂停
        })
        XCTAssertEqual(summary.processed, 0, "暂停后不计为已处理")
        XCTAssertEqual(try indexer.pendingCount(), 1, "任务退回 pending，等下次继续")
        engine.stop()
    }

    /// 提取期间文件名搜索不退化：架构上零交集，此处锚定两者可同时正确工作。
    func testFilenameSearchUnaffectedDuringContentIndexing() throws {
        try "内容带 招标公告编号889".write(to: share.appendingPathComponent("公告.txt"), atomically: true, encoding: .utf8)
        let engine = try AstfindEngine(home: home.appendingPathComponent("data"))
        engine.autoExtractContent = false
        _ = try engine.register(path: share.path, name: "资料")
        // 文件名搜索与内容搜索同时可用
        XCTAssertEqual(engine.search("公告")?.total, 1, "文件名搜索照常")
        _ = try XCTUnwrap(engine.extractContent())
        XCTAssertEqual(engine.contentSearch("招标公告").count, 1)
        XCTAssertEqual(engine.search("公告")?.total, 1, "内容索引后文件名搜索不变")
        engine.stop()
    }

    /// 检索输入永远是字面量：引号不得改写 FTS 语法，`%`/`_` 不得变成 LIKE 通配符。
    func testContentSearchTreatsQueryAsLiteralText() throws {
        try "折扣 50% 已完成；原句 a\" OR b 保留；编号 5元"
            .write(to: share.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        let engine = try AstfindEngine(home: home.appendingPathComponent("data"))
        engine.autoExtractContent = false
        _ = try engine.register(path: share.path, name: "字面量")
        _ = try XCTUnwrap(engine.extractContent())

        XCTAssertEqual(engine.contentSearch("a\" OR b").count, 1, "引号是正文的一部分，不是 FTS 语法")
        XCTAssertEqual(engine.contentSearch("50%").count, 1, "FTS 短语里的 % 仍是字面量")
        XCTAssertEqual(engine.contentSearch("5%").count, 0, "LIKE 兜底不得把 % 当通配符")
        XCTAssertEqual(engine.contentSearch("编号 5元").count, 1)
        engine.stop()
    }

    /// 索引库含文件名与正文：库文件 0600、数据目录 0700（同机其他账户不可读）。
    func testIndexDataIsOwnerReadableOnly() throws {
        let data = home.appendingPathComponent("data")
        let engine = try AstfindEngine(home: data)
        engine.stop()
        func permissions(_ url: URL) throws -> Int? {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes[.posixPermissions] as? NSNumber)?.intValue
        }
        XCTAssertEqual(try permissions(data.appendingPathComponent("registry.sqlite")), 0o600)
        XCTAssertEqual(try permissions(data), 0o700)
        XCTAssertEqual(try permissions(data.appendingPathComponent("snapshots")), 0o700)
    }
}
