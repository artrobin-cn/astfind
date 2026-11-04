import Foundation

// MARK: - SMB 共享身份（R1/L2）

/// SMB 共享挂载解析（注入式：测试模拟挂载点漂移，真机解析 mount 表）。
///
/// 第一性原理：SMB 无稳定卷 UUID（实测挂载点 `volumeUUIDString = nil`），挂载点名会漂移
/// （碰撞时 macOS 自动加 `-1` 后缀，如 teamshare → teamshare-1）。稳定身份是
/// 共享本身：`smb://host/share`——由系统挂载表记录，与挂载点无关。语义对齐 D3 的
/// 「卷 UUID 优先」：refreshMounts 按身份匹配任意挂载点自动重绑。
public protocol SMBShareResolving: AnyObject {
    /// 当前全部 SMB 挂载（共享身份 → 挂载点）。
    func smbShareMounts() -> [SMBShareMount]
}

/// 一处 SMB 共享挂载：身份（smb://host/share）与当前挂载点的对应。
public struct SMBShareMount: Equatable, Sendable {
    /// 无凭据、无尾斜杠的共享身份（host 用挂载时系统记录的稳定名）。
    public let shareURL: String
    /// 当前挂载点（运行态，会漂移；绝不做永久身份）。
    public let mountPath: String
    public init(shareURL: String, mountPath: String) {
        self.shareURL = shareURL; self.mountPath = mountPath
    }
}

/// 真机实现：解析 `/sbin/mount` 输出的 smbfs 行。
/// 实测格式：`//user@nas.local._smb._tcp.local/teamshare on /Volumes/teamshare (smbfs, nodev, nosuid, quarantine, mounted by user)`
public final class DefaultSMBShareResolver: SMBShareResolving {
    public init() {}
    public func smbShareMounts() -> [SMBShareMount] {
        guard let output = Self.runMount() else { return [] }
        return Self.parse(output)
    }
    static func runMount() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/mount")
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
    /// 纯函数解析（可单测）：只认 smbfs 行，剥凭据产出 smb://host/share。
    static func parse(_ output: String) -> [SMBShareMount] {
        var result: [SMBShareMount] = []
        for rawLine in output.split(separator: "\n") {
            let line = String(rawLine)
            guard line.contains("(smbfs") else { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            // [source, "on", mountPath, "(smbfs,", …]；source 形如 //user@host/share 或 //DOMAIN;user@host/share
            guard parts.count >= 3, parts[1] == "on",
                  let shareURL = SMBShareIdentity.shareURL(fromMountSource: String(parts[0])) else { continue }
            result.append(SMBShareMount(shareURL: shareURL, mountPath: String(parts[2])))
        }
        return result
    }
}

/// smb:// 身份纯工具：拆解、反查、匹配（无 I/O，全部可单测）。
public enum SMBShareIdentity {
    /// `//user@host/share`（或 `smb://user@host/share`）→ `smb://host/share`；
    /// 剥 `DOMAIN;user:pass@` 凭据（密码绝入库）与尾斜杠。非 SMB 形式返回 nil。
    public static func shareURL(fromMountSource source: String) -> String? {
        var s = source
        if s.hasPrefix("smb://") { s.removeFirst("smb://".count) }
        else if s.hasPrefix("//") { s.removeFirst(2) }
        else { return nil }
        if let at = s.firstIndex(of: "@") { s = String(s[s.index(after: at)...]) }
        while s.count > 1, s.hasSuffix("/") { s.removeLast() }
        guard s.contains("/") else { return nil }   // 必须 host/share 完整
        return "smb://" + s
    }

    /// locator 是否已是 smb:// 身份形式（否则为存量路径型，待迁移）。
    public static func isIdentity(_ locator: String) -> Bool { locator.hasPrefix("smb://") }

    /// `smb://host/share[/子路径]` → host（用于 SMB 服务端存活探测）。
    /// 非身份 locator（file:// / 旧路径型）返回 nil。
    public static func host(ofIdentity locator: String) -> String? {
        guard let parts = parts(ofIdentity: locator),
              let url = URL(string: parts.shareURL)
        else { return nil }
        return url.host
    }

    /// 拆解 `smb://host/share[/子路径]` → (shareURL, subpath)。shareURL 恒为 `smb://host/share`。
    public static func parts(ofIdentity locator: String) -> (shareURL: String, subpath: String)? {
        guard isIdentity(locator) else { return nil }
        let body = String(locator.dropFirst("smb://".count))
        guard let hostEnd = body.firstIndex(of: "/") else { return nil }
        let host = String(body[..<hostEnd])
        let remainder = String(body[body.index(after: hostEnd)...])
        guard let shareEnd = remainder.firstIndex(of: "/") else {
            return (shareURL: "smb://" + host + "/" + remainder, subpath: "")
        }
        return (shareURL: "smb://" + host + "/" + String(remainder[..<shareEnd]),
                subpath: String(remainder[remainder.index(after: shareEnd)...]))
    }

    /// path 是否位于挂载点下（按路径组件，防 /a-b 误配 /a 前缀）；恰为挂载点返回 ""。
    public static func subpath(ofPath path: String, underMount mountPath: String) -> String? {
        if path == mountPath { return "" }
        guard path.hasPrefix(mountPath + "/") else { return nil }
        return String(path.dropFirst(mountPath.count + 1))
    }

    /// 身份匹配：host/share 大小写不敏感（DNS 名与 SMB 共享名均如此；同一 NAS 重复挂载时字面恒定）。
    public static func matches(shareURL: String, locatorShareURL: String) -> Bool {
        shareURL.caseInsensitiveCompare(locatorShareURL) == .orderedSame
    }
}
