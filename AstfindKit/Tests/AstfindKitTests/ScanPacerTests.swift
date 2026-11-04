import XCTest
import OilFindCore
@testable import AstfindKit

/// M0.6：ScanPacer 直通、单在飞、保底上限、取消唤醒与来源隔离。
final class ScanPacerTests: XCTestCase {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool
        init(_ value: Bool) { self.value = value }
        var current: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
    }

    private func makePacer(throttled: Flag,
                           suspended: Flag? = nil,
                           batchInterval: TimeInterval = 0,
                           maximumWait: TimeInterval = 0.25) -> ScanPacer {
        ScanPacer(.init(batchInterval: batchInterval, maximumWait: maximumWait,
                        isThrottled: { throttled.current },
                        isSuspended: { suspended?.current ?? false }))
    }

    func testNonInteractiveIsPassthrough() {
        let flag = Flag(false)
        let pacer = makePacer(throttled: flag, batchInterval: 0.2, maximumWait: 0.2)
        let began = ProcessInfo.processInfo.systemUptime
        for _ in 0..<20 { XCTAssertTrue(pacer.beginIO()); pacer.endIO() }
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        let metrics = pacer.metrics
        XCTAssertLessThan(elapsed, 0.1)
        XCTAssertEqual(metrics.permits, 20)
        XCTAssertEqual(metrics.throttledCalls, 0)
        XCTAssertEqual(metrics.artificialWait, 0, accuracy: 0.001)
    }

    func testSuspensionBlocksUntilResume() {
        let throttled = Flag(false)
        let suspended = Flag(true)
        let pacer = makePacer(throttled: throttled, suspended: suspended)
        let finished = DispatchSemaphore(value: 0)
        let result = Flag(false)
        DispatchQueue.global(qos: .utility).async {
            result.set(pacer.beginIO())
            finished.signal()
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 0.15), .timedOut,
                       "交互暂停时不得发放新 I/O")
        suspended.set(false)
        pacer.wake()
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(result.current)
        XCTAssertGreaterThanOrEqual(pacer.metrics.suspendCount, 1)
        pacer.endIO()
    }

    func testCancelWakesSuspension() {
        let throttled = Flag(false)
        let suspended = Flag(true)
        let pacer = makePacer(throttled: throttled, suspended: suspended)
        let finished = DispatchSemaphore(value: 0)
        let result = Flag(true)
        DispatchQueue.global(qos: .utility).async {
            result.set(pacer.beginIO())
            finished.signal()
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 0.1), .timedOut)
        pacer.cancel()
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(result.current, "取消应拒绝许可并唤醒等待者")
    }

    func testSingleInFlightWhileThrottled() {
        let flag = Flag(true)
        let pacer = makePacer(throttled: flag)
        XCTAssertTrue(pacer.beginIO())
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let result = Flag(false)
        DispatchQueue.global(qos: .utility).async {
            started.signal()
            result.set(pacer.beginIO())
            finished.signal()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(finished.wait(timeout: .now() + 0.1), .timedOut,
                       "有在飞 I/O 时第二个许可必须等待")
        pacer.endIO()
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(result.current)
        XCTAssertEqual(pacer.metrics.maxInFlight, 1)
        pacer.endIO()
    }

    func testCancelWakesWaiterAndDeniesPermit() {
        let flag = Flag(true)
        let pacer = makePacer(throttled: flag)
        XCTAssertTrue(pacer.beginIO())
        let finished = DispatchSemaphore(value: 0)
        let result = Flag(true)
        DispatchQueue.global(qos: .utility).async {
            result.set(pacer.beginIO())
            finished.signal()
        }
        pacer.cancel()
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(result.current)
        pacer.endIO()
    }

    func testWakeReevaluatesDisabledPolicy() {
        let flag = Flag(true)
        let pacer = makePacer(throttled: flag)
        XCTAssertTrue(pacer.beginIO())
        let finished = DispatchSemaphore(value: 0)
        let result = Flag(false)
        DispatchQueue.global(qos: .utility).async {
            result.set(pacer.beginIO())
            finished.signal()
        }
        flag.set(false)
        pacer.wake()
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(result.current, "开关关闭后不再等待在飞 I/O")
        pacer.endIO()
        XCTAssertEqual(pacer.metrics.throttleExitCount, 1)
    }

    func testBatchIntervalIsBoundedByMaximumWait() {
        let flag = Flag(false)
        let pacer = makePacer(throttled: flag, batchInterval: 1.0, maximumWait: 0.05)
        // 先在非交互状态放行一次，写入 lastPermit，但不留下在飞 I/O。
        XCTAssertTrue(pacer.beginIO())
        pacer.endIO()
        flag.set(true)
        let began = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(pacer.beginIO())
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        XCTAssertGreaterThanOrEqual(elapsed, 0.03)
        XCTAssertLessThan(elapsed, 0.5, "单次等待不得超过 maximumWait（含调度余量）")
        pacer.endIO()
    }

    func testTwoScannersDoNotSharePermits() {
        let flag = Flag(true)
        let first = makePacer(throttled: flag)
        let second = makePacer(throttled: flag)
        XCTAssertTrue(first.beginIO())
        XCTAssertTrue(second.beginIO(), "不同来源/Scanner 的 Pacer 不共享在飞许可")
        let finished = DispatchSemaphore(value: 0)
        let result = Flag(false)
        DispatchQueue.global(qos: .utility).async {
            result.set(first.beginIO())
            finished.signal()
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 0.1), .timedOut)
        first.endIO()
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(result.current)
        first.endIO(); second.endIO()
    }

    func testConfiguredTwoInFlightAllowsTwoAndWaitsForThird() {
        let flag = Flag(true)
        let pacer = ScanPacer(.init(batchInterval: 0, maximumWait: 0.01,
                                    maxConcurrentIO: 2,
                                    isThrottled: { flag.current }))
        XCTAssertTrue(pacer.beginIO())
        XCTAssertTrue(pacer.beginIO())
        XCTAssertEqual(pacer.metrics.maxInFlight, 2)

        let finished = DispatchSemaphore(value: 0)
        let result = Flag(false)
        DispatchQueue.global(qos: .utility).async {
            result.set(pacer.beginIO())
            finished.signal()
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 0.1), .timedOut,
                       "第三个许可应等待两个在飞 I/O 之一结束")
        pacer.endIO()
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(result.current)
        pacer.endIO(); pacer.endIO()
    }

    func testDirectoryBatchScopeDoesNotDelayDirectoryOpen() {
        let flag = Flag(true)
        let pacer = ScanPacer(.init(batchInterval: 0.08, maximumWait: 0.2,
                                    intervalScope: .perDirectoryBatch,
                                    isThrottled: { flag.current }))

        let first = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(pacer.beginIO())
        pacer.endIO()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - first, 0.04,
                          "没有上一个目录批次时，open 不应等待")

        let second = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(pacer.beginIO())
        pacer.endIO()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - second, 0.04,
                          "未完成目录批次时，下一次 open 不应等待")

        pacer.noteDirectoryBatch()
        let third = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(pacer.beginIO())
        let elapsed = ProcessInfo.processInfo.systemUptime - third
        pacer.endIO()
        XCTAssertGreaterThanOrEqual(elapsed, 0.04,
                                    "目录批次之后的下一次读取必须等待批次间隔")
    }

    func testControllerClearsStatusWhenPreferenceTurnsOff() {
        let flag = Flag(true)
        let coordinator = ForegroundActivityCoordinator()
        coordinator.setPanel(visible: true)
        let center = NotificationCenter()
        let controller = ScanPacingController(coordinator: coordinator,
                                              enabledProvider: { flag.current },
                                              suspendedProvider: { false },
                                              notificationCenter: center)
        let pacer = controller.makePacer(for: .smb, sourceId: "test-source")
        XCTAssertNotNil(pacer)
        XCTAssertTrue(pacer!.beginIO())
        XCTAssertTrue(controller.isThrottled)
        flag.set(false)
        center.post(name: ScanPacingPreferences.changed, object: nil)
        XCTAssertFalse(controller.isThrottled, "关闭开关应立即清除降速状态")
        XCTAssertFalse(ScanPacingStatus.isThrottled)
        pacer?.endIO()

        flag.set(true)
        center.post(name: ScanPacingPreferences.changed, object: nil)
        XCTAssertTrue(pacer!.beginIO(), "重新开启后再次进入降速")
        XCTAssertTrue(controller.isThrottled)
        pacer?.endIO()
        pacer?.cancel()
        XCTAssertFalse(ScanPacingStatus.isThrottled)
    }

    func testPreferenceDefaultsToEnabledAndPersists() {
        let suite = "astfind-scan-pacing-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(ScanPacingPreferences.isEnabled(in: defaults), "无既有偏好时默认开启")
        ScanPacingPreferences.setEnabled(false, in: defaults)
        XCTAssertFalse(ScanPacingPreferences.isEnabled(in: defaults))
        ScanPacingPreferences.setEnabled(true, in: defaults)
        XCTAssertTrue(ScanPacingPreferences.isEnabled(in: defaults))
    }

    func testIODurationAndMetricAggregation() {
        let flag = Flag(true)
        let pacer = makePacer(throttled: flag, batchInterval: 0)
        XCTAssertTrue(pacer.beginIO())
        pacer.noteOpenDuration(0.12)
        pacer.endIO()
        XCTAssertTrue(pacer.beginIO())
        pacer.noteReadDuration(0.30)
        pacer.endIO()
        pacer.noteIODuration(0.6)
        pacer.noteIODuration(1.2)
        pacer.noteReadDuration(2.5)

        let first = pacer.metrics
        XCTAssertEqual(first.ioDuration, 4.72, accuracy: 0.001)
        XCTAssertEqual(first.maxIODuration, 2.5, accuracy: 0.001)
        XCTAssertEqual(first.permits, 2)
        XCTAssertEqual(first.openDuration, 0.12, accuracy: 0.001)
        XCTAssertEqual(first.maxOpenDuration, 0.12, accuracy: 0.001)
        XCTAssertEqual(first.readDuration, 2.80, accuracy: 0.001)
        XCTAssertEqual(first.maxReadDuration, 2.5, accuracy: 0.001)
        XCTAssertEqual(first.openCount, 1)
        XCTAssertEqual(first.readCount, 2)
        XCTAssertEqual(first.slowOpen2s, 0)
        XCTAssertEqual(first.slowRead2s, 1)
        XCTAssertEqual(first.slowIO500Count, 3)
        XCTAssertEqual(first.slowIO1000Count, 2)
        XCTAssertEqual(first.slowIO2000Count, 1)

        var second = ScanPacerMetrics()
        second.permits = 3
        second.ioDuration = 0.08
        second.maxIODuration = 0.05
        second.openDuration = 0.03
        second.readDuration = 0.05
        second.openCount = 1
        second.readCount = 2
        second.slowIO500Count = 1
        second.slowIO1000Count = 1
        second.maxInFlight = 1
        second.directoryBatches = 2
        let merged = ScanPacerMetrics.aggregate([first, second])
        XCTAssertEqual(merged.permits, 5)
        XCTAssertEqual(merged.ioDuration, 4.80, accuracy: 0.001)
        XCTAssertEqual(merged.maxIODuration, 2.5, accuracy: 0.001)
        XCTAssertEqual(merged.openDuration, 0.15, accuracy: 0.001)
        XCTAssertEqual(merged.readDuration, 2.85, accuracy: 0.001)
        XCTAssertEqual(merged.openCount, 2)
        XCTAssertEqual(merged.readCount, 4)
        XCTAssertEqual(merged.slowIO500Count, 4)
        XCTAssertEqual(merged.slowIO1000Count, 3)
        XCTAssertEqual(merged.slowIO2000Count, 1)
        XCTAssertEqual(merged.directoryBatches, 2)
        XCTAssertEqual(merged.maxInFlight, max(first.maxInFlight, second.maxInFlight))
    }
}
