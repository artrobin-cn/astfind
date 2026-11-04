import AppKit
import Darwin
import Foundation

/// M0.7a 视频命中跳时间点。
///
/// 决策（PRD US-004/005）：
/// - 默认播放器是 QuickTime Player → osascript 打开并 `set current time` + `play`；
/// - 不是 QuickTime / 拒绝自动化授权 / 脚本失败 → 普通打开，绝不让“跳转”阻塞面板；
/// - 同一会话记录一次授权拒绝，后续不再反复弹系统授权框。
struct VideoPlaybackOutcome: Equatable {
    enum Kind: Equatable { case sought, standard, fallback }
    enum Reason: Equatable {
        case noTimecode
        case notQuickTime
        case automationDenied
        case permissionDenied
        case timeout
        case scriptFailed(String)
        case unavailable(String)
    }
    let kind: Kind
    let playerBundleID: String?
    let reason: Reason?
}

enum VideoSeekFailure: Error, Equatable {
    case permissionDenied
    case timeout
    case scriptFailed(String)
}

final class VideoPlaybackCoordinator {
    static let quickTimeBundleID = "com.apple.QuickTimePlayerX"
    static let scriptTimeout: TimeInterval = 10

    /// 可注入：默认播放器解析 / 普通打开 / AppleScript 执行（测试不碰系统播放器与授权）。
    var playerBundleID: (URL) -> String? = VideoPlaybackCoordinator.defaultPlayerBundleID
    var openStandard: (URL) -> Void = { url in
        DispatchQueue.main.async {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open(url, configuration: configuration) { _, error in
                if error != nil { DispatchQueue.main.async { NSSound.beep() } }
            }
        }
    }
    var runAppleScript: (URL, Double, TimeInterval) -> Result<Void, VideoSeekFailure> =
        VideoPlaybackCoordinator.runQuickTimeScript

    private let lock = NSLock()
    private var denied = false
    /// 系统自动化授权被拒后，同一会话不再尝试（避免每次打开都弹一次）。
    var automationDenied: Bool {
        lock.lock(); defer { lock.unlock() }; return denied
    }

    func open(url: URL, startMs: Int?) -> VideoPlaybackOutcome {
        let bundleID = playerBundleID(url)
        guard let startMs else {
            openStandard(url)
            return VideoPlaybackOutcome(kind: .standard, playerBundleID: bundleID, reason: .noTimecode)
        }
        guard bundleID == Self.quickTimeBundleID else {
            openStandard(url)
            return VideoPlaybackOutcome(kind: .standard, playerBundleID: bundleID, reason: .notQuickTime)
        }
        if automationDenied {
            openStandard(url)
            return VideoPlaybackOutcome(kind: .standard, playerBundleID: bundleID, reason: .automationDenied)
        }
        switch runAppleScript(url, Double(startMs) / 1000, Self.scriptTimeout) {
        case .success:
            return VideoPlaybackOutcome(kind: .sought, playerBundleID: bundleID, reason: nil)
        case .failure(let failure):
            if failure == .permissionDenied {
                lock.lock(); denied = true; lock.unlock()
            }
            openStandard(url)
            let reason: VideoPlaybackOutcome.Reason
            switch failure {
            case .permissionDenied: reason = .permissionDenied
            case .timeout: reason = .timeout
            case .scriptFailed(let message): reason = .scriptFailed(message)
            }
            return VideoPlaybackOutcome(kind: .fallback, playerBundleID: bundleID, reason: reason)
        }
    }

    static func defaultPlayerBundleID(for url: URL) -> String? {
        guard let application = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
        return Bundle(url: application)?.bundleIdentifier
    }

    /// 参数经 argv 传入，绝不拼接进脚本字符串（路径含引号/反斜杠也不会注入）。
    static let quickTimeScript = """
    on run argv
      set filePath to item 1 of argv
      set t to (item 2 of argv) as real
      tell application "QuickTime Player"
        activate
        set doc to open POSIX file filePath
        tell doc
          set current time to t
          play
        end tell
      end tell
    end run
    """

    static func runQuickTimeScript(url: URL, seconds: Double, timeout: TimeInterval) -> Result<Void, VideoSeekFailure> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", quickTimeScript, url.path,
                             String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), seconds)]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        do {
            try process.run()
        } catch {
            return .failure(.scriptFailed(String(describing: error)))
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            let killDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            return .failure(.timeout)
        }
        let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            let lower = message.lowercased()
            if message.contains("-1743") || lower.contains("not authorized")
                || lower.contains("not allowed to send apple events") {
                return .failure(.permissionDenied)
            }
            return .failure(.scriptFailed(message.isEmpty ? "osascript exit \(process.terminationStatus)" : message))
        }
        return .success(())
    }
}
