import XCTest
@testable import AstfindKit

/// M0.6：前台活动协调器的确定性边界（不真实等待 8 秒）。
final class ForegroundActivityTests: XCTestCase {
    private final class Clock {
        var now: TimeInterval = 1_000
        func advance(_ seconds: TimeInterval) { now += seconds }
    }

    private func makeCoordinator(_ clock: Clock,
                                 panelGrace: TimeInterval = 8) -> ForegroundActivityCoordinator {
        ForegroundActivityCoordinator(
            configuration: .init(panelHideGrace: panelGrace,
                                 quickLookGrace: panelGrace,
                                 activityGrace: panelGrace),
            now: { clock.now })
    }

    func testPanelShowIsImmediateAndHideUsesGrace() {
        let clock = Clock()
        let coordinator = makeCoordinator(clock)
        XCTAssertFalse(coordinator.isInteractive)

        coordinator.setPanel(visible: true)
        XCTAssertTrue(coordinator.isInteractive)
        XCTAssertTrue(coordinator.activeSources.contains(.panel))

        coordinator.setPanel(visible: false)
        XCTAssertTrue(coordinator.isInteractive, "隐藏后 8 秒宽限内仍交互")
        clock.advance(7.9)
        XCTAssertTrue(coordinator.isInteractive)
        clock.advance(0.2)
        XCTAssertFalse(coordinator.isInteractive)
        XCTAssertFalse(coordinator.activeSources.contains(.panel))
    }

    func testOpenAndRevealExtendButNeverShortenDeadline() {
        let clock = Clock()
        let coordinator = makeCoordinator(clock)

        coordinator.note(.open)
        clock.advance(3)
        coordinator.note(.reveal)   // 较晚截止时间必须保留
        clock.advance(4)
        XCTAssertTrue(coordinator.isInteractive, "open 的 8 秒尚未结束")
        XCTAssertTrue(coordinator.activeSources.contains(.open))
        XCTAssertTrue(coordinator.activeSources.contains(.reveal))

        clock.advance(3.9)
        XCTAssertTrue(coordinator.isInteractive, "reveal 的 8 秒截止时间更晚")
        clock.advance(0.2)
        XCTAssertFalse(coordinator.isInteractive)
    }

    func testSearchAndPanelAreIndependentSignals() {
        let clock = Clock()
        let coordinator = makeCoordinator(clock)
        coordinator.setPanel(visible: true)
        coordinator.setTyping(true)
        XCTAssertTrue(coordinator.activeSources.contains(.panel))
        XCTAssertTrue(coordinator.activeSources.contains(.search))

        clock.advance(30)   // 面板持续可见不依赖截止时间
        XCTAssertTrue(coordinator.isInteractive)
        coordinator.setPanel(visible: false)
        XCTAssertFalse(coordinator.activeSources.contains(.search), "隐藏时清除搜索信号")
        XCTAssertTrue(coordinator.isInteractive, "隐藏宽限仍有效")
    }

    func testQuickLookStaysInteractiveUntilGraceExpires() {
        let clock = Clock()
        let coordinator = makeCoordinator(clock)

        coordinator.setQuickLook(visible: true)
        clock.advance(60)
        XCTAssertTrue(coordinator.isInteractive)
        XCTAssertTrue(coordinator.activeSources.contains(.quickLook))

        coordinator.setQuickLook(visible: false)
        clock.advance(7.9)
        XCTAssertTrue(coordinator.isInteractive)
        clock.advance(0.2)
        XCTAssertFalse(coordinator.isInteractive)
    }

    func testContinuousPanelHidesExtendLaterDeadline() {
        let clock = Clock()
        let coordinator = makeCoordinator(clock)
        coordinator.setPanel(visible: true)
        coordinator.setPanel(visible: false)
        clock.advance(4)
        coordinator.setPanel(visible: true)   // 重新显示
        coordinator.setPanel(visible: false)  // 再次隐藏 → 新的 8 秒
        clock.advance(7.9)
        XCTAssertTrue(coordinator.isInteractive)
        clock.advance(0.2)
        XCTAssertFalse(coordinator.isInteractive)
    }

    func testExternalPreviewHoldsSuspensionAndGrace() {
        let clock = Clock()
        let coordinator = makeCoordinator(clock)
        coordinator.setExternalAppActive(true)
        XCTAssertTrue(coordinator.isInteractive)
        XCTAssertTrue(coordinator.activeSources.contains(.externalApp))
        clock.advance(30)
        XCTAssertTrue(coordinator.isInteractive, "Preview 保持前台时持续暂停")
        coordinator.setExternalAppActive(false)
        clock.advance(7.9)
        XCTAssertTrue(coordinator.isInteractive, "切走后保留宽限")
        clock.advance(0.2)
        XCTAssertFalse(coordinator.isInteractive)
    }

    func testAllActivitySourcesAreExpressible() {
        let clock = Clock()
        let coordinator = makeCoordinator(clock)
        coordinator.setPanel(visible: true)
        coordinator.setTyping(true)
        coordinator.note(.open)
        coordinator.note(.reveal)
        coordinator.note(.quickLook)
        coordinator.note(.mcp)
        coordinator.setExternalAppActive(true)
        XCTAssertEqual(coordinator.activeSources,
                       Set([.panel, .search, .open, .reveal, .quickLook, .mcp, .externalApp]))
    }
}
