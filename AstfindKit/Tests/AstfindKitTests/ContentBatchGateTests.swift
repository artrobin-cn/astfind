import XCTest
@testable import AstfindKit

/// M0.6：同来源内容执行批次去重（入队不受限、limit=0 不受影响）。
final class ContentBatchGateTests: XCTestCase {
    private var home: URL!
    private var share: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("astfind-m06-gate-\(UUID().uuidString)")
        share = home.appendingPathComponent("share")
        try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private struct SlowTextExtractor: ContentExtracting {
        let profile = "slow-test-v1"
        let delay: TimeInterval
        func canExtract(fileName: String) -> Bool { (fileName as NSString).pathExtension.lowercased() == "txt" }
        func extract(at url: URL) throws -> String {
            Thread.sleep(forTimeInterval: delay)
            return "slow batch text"
        }
    }

    func testGateAllowsIndependentSourcesButRejectsSameSource() {
        let gate = ContentBatchGate()
        XCTAssertTrue(gate.tryAcquire("a"))
        XCTAssertFalse(gate.tryAcquire("a"))
        XCTAssertTrue(gate.tryAcquire("b"))
        gate.release("a")
        XCTAssertTrue(gate.tryAcquire("a"))
        gate.release("a"); gate.release("b")
        XCTAssertEqual(gate.activeCount, 0)
    }

    func testGlobalBatchConflictsWithEverySource() {
        let gate = ContentBatchGate()
        XCTAssertTrue(gate.tryAcquire("a"))
        XCTAssertFalse(gate.tryAcquire(nil))
        gate.release("a")
        XCTAssertTrue(gate.tryAcquire(nil))
        XCTAssertFalse(gate.tryAcquire("a"))
        gate.release(nil)
        XCTAssertTrue(gate.tryAcquire("a"))
        gate.release("a")
    }

    func testConcurrentRunPendingMergesLaterTriggerAndKeepsLimitZeroUntouched() throws {
        for index in 0..<3 {
            try "text \(index)".write(to: share.appendingPathComponent("file\(index).txt"),
                                     atomically: true, encoding: .utf8)
        }
        let databaseURL = home.appendingPathComponent("data/registry.sqlite")
        let extractors = ContentExtractorRegistry(extractors: [SlowTextExtractor(delay: 0.15)])
        let indexer = try ContentIndexer(databaseURL: databaseURL, extractors: extractors)
        let engine = try AstfindEngine(
            databaseURL: databaseURL,
            snapshotDirectory: home.appendingPathComponent("data/snapshots"),
            contentIndexer: indexer)
        engine.autoExtractContent = false
        let record = try engine.register(path: share.path, name: "Local", kind: .local)
        XCTAssertTrue(engine.waitForScans(timeout: 60))
        _ = engine.extractContent(limit: 0)   // 只入队
        XCTAssertEqual(try indexer.pendingCount(), 3)

        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var summaries: [ContentIndexer.Summary] = []
        for _ in 0..<2 {
            DispatchQueue.global(qos: .utility).async {
                started.signal()
                let summary = try? indexer.runPending(limit: 10, sourceId: record.sourceId, lanes: 1)
                lock.lock(); summaries.append(summary ?? ContentIndexer.Summary()); lock.unlock()
                finished.signal()
            }
        }
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        // 等一小会儿确保第二个批次已经尝试进入执行门。
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(indexer.activeBatchCountForTesting, 1, "同一来源同时最多一个实际批次")

        // limit=0 只做入队/空批次，不占执行门。
        let began = ProcessInfo.processInfo.systemUptime
        _ = try indexer.runPending(limit: 0, sourceId: record.sourceId)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 0.1)

        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(summaries.map(\.processed).reduce(0, +), 3, "任务只执行一次，不重复")
        XCTAssertEqual(summaries.filter { $0.processed > 0 }.count, 1, "后到触发快速返回")
        XCTAssertEqual(try indexer.pendingCount(), 0)
        XCTAssertEqual(indexer.activeBatchCountForTesting, 0)
        engine.stop()
    }
}
