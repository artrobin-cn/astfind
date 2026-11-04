import Foundation
import Network

/// SMB 服务端存活探测（TCP 445，短超时）。
///
/// 为什么不能只看挂载点：NAS 掉线/休眠后，macOS 的 smbfs 挂载点仍然存在，
/// `FileManager.fileExists` 会返回 true；真正的 `read`/`getattrlist` 却会卡在
/// 已失效的 TCP 连接上直到内核重传超时（实测 44KB 文件 >15s 甚至数分钟）。
/// 以图搜图打开结果时，`NSWorkspace.open` 正是被这一层拖住的。
///
/// TCP 连接是廉价且真实的信号：服务端不可达时 connect 立即失败/超时，
/// 不会进入 smbfs 的不可中断 I/O。探测使用 0.8s 上限，结果由引擎缓存。
public enum SMBServerProbe {
    public static func isReachable(host: String, port: UInt16 = 445,
                                   timeout: TimeInterval = 0.6) -> Bool {
        for candidate in candidates(for: host) where !candidate.isEmpty {
            if probe(host: candidate, port: port, timeout: timeout) { return true }
        }
        return false
    }

    /// 挂载表里的 host 常是 Bonjour 服务实例名（`nas.local._smb._tcp.local`），
    /// Network.framework 不能把它当主机名解析；补一个真实主机名 `nas.local.local`。
    /// 同时也覆盖 `nas.local` → `nas.local.local` 这种简写。
    static func candidates(for host: String) -> [String] {
        let normalized = normalize(host)
        guard !normalized.isEmpty else { return [] }
        var result: [String] = []
        // Bonjour 服务实例名几乎必然解析失败；先试真实主机名，避免每次白等一个 timeout。
        if let range = normalized.range(of: "._smb._tcp.local", options: [.caseInsensitive, .backwards]) {
            result.append(String(normalized[..<range.lowerBound]) + ".local")
        }
        result.append(normalized)
        if !normalized.hasSuffix(".") && !normalized.contains(".") {
            result.append(normalized + ".local")
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.lowercased()).inserted }
    }

    private static func probe(host: String, port: UInt16, timeout: TimeInterval) -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                box.finish(true, semaphore: semaphore)
                connection.cancel()
            case .failed, .cancelled:
                box.finish(false, semaphore: semaphore)
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue.global(qos: .utility))
        let completed = semaphore.wait(timeout: .now() + timeout) == .success
        if !completed { connection.cancel() }
        return completed && box.value
    }

    /// `smb://` 身份里可能带尾部点、IPv6 方括号；Network.framework 需要裸主机名。
    static func normalize(_ host: String) -> String {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("["), value.hasSuffix("]") {
            value.removeFirst(); value.removeLast()
        }
        while value.hasSuffix(".") { value.removeLast() }
        return value
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Bool?
        var value: Bool { lock.lock(); defer { lock.unlock() }; return stored ?? false }
        func finish(_ result: Bool, semaphore: DispatchSemaphore) {
            lock.lock()
            let first = stored == nil
            if first { stored = result }
            lock.unlock()
            if first { semaphore.signal() }
        }
    }
}
