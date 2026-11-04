import Foundation

/// 卷身份解析（注入式：测试模拟拔插，真机读 /Volumes）。
///
/// 第一性原理：名字与路径都不是身份（D1 同名卷实验）；APFS/HFS+ 的**卷 UUID**
/// 改名不变、跨挂载点稳定，是外置卷的稳定标识。SMB 无稳定卷 UUID——
/// 其身份由 registry 的 `kind + locator` 承担，不走本协议。
public protocol VolumeIdentityResolving: AnyObject {
    /// 指定挂载点所在卷的 UUID（非卷根也可能返回其所属卷的 UUID；无法解析返回 nil）。
    func volumeUUID(atMount path: String) -> String?
    /// 当前全部候选挂载点（按 path 排序，保证消歧确定）。
    func mounts() -> [VolumeMount]
}

public struct VolumeMount: Equatable, Sendable {
    public let path: String
    public let volumeUUID: String?
    public let volumeName: String?
    public init(path: String, volumeUUID: String?, volumeName: String?) {
        self.path = path; self.volumeUUID = volumeUUID; self.volumeName = volumeName
    }
}

/// 真机实现：枚举 `/Volumes`，读系统卷信息。
public final class DefaultVolumeResolver: VolumeIdentityResolving {
    public init() {}
    public func volumeUUID(atMount path: String) -> String? {
        try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
    }
    public func mounts() -> [VolumeMount] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted().map { name in
            let path = "/Volumes/" + name
            let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeUUIDStringKey, .volumeNameKey])
            return VolumeMount(path: path, volumeUUID: values?.volumeUUIDString, volumeName: values?.volumeName)
        }
    }
}

extension VolumeIdentityResolving {
    /// 在全部挂载点中按卷 UUID 找到唯一归属（同名卷靠 UUID 消歧；多个匹配=歧义，返回 nil 交上层人工绑定）。
    public func findMount(volumeUUID: String) -> String? {
        let matches = mounts().filter { $0.volumeUUID?.caseInsensitiveCompare(volumeUUID) == .orderedSame }
        return matches.count == 1 ? matches[0].path : nil
    }
}
