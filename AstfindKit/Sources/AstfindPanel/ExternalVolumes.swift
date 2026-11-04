import AppKit
import DiskArbitration
import Darwin

struct ExternalVolume: Equatable {
    var uuid: String
    var name: String
    var path: String
    var device: String = ""
    var local = true
    var startup = false
    var visible = true
    var writable = true
    var diskImage = false
    var timeMachine = false
    var optical = false
    var roles: [String] = []

    func eligible(allowDiskImages: Bool = false) -> Bool {
        guard UUID(uuidString: uuid) != nil, local, !startup, visible, !timeMachine, !(optical && !writable),
              !diskImage || allowDiskImages else { return false }
        let hidden = Set(["preboot", "recovery", "vm", "update", "xart", "hardware", "backup"])
        return !roles.contains { hidden.contains($0.lowercased()) }
            && path != "/" && !path.hasPrefix("/System/Volumes/")
    }
}

protocol ExternalDriveMonitoring: AnyObject {
    var onChange: (() -> Void)? { get set }
    var beforeEject: ((String) -> Void)? { get set }
    var beforeUnmount: ((String) -> Void)? { get set }
    func start()
    func stop()
}

/// Disk Arbitration approvals run off the main thread and never return a dissenter.
final class ExternalVolumeMonitor: ExternalDriveMonitoring {
    private let queue = DispatchQueue(label: "com.oiloil.find.external-volumes", qos: .utility)
    private var session: DASession?
    var onChange: (() -> Void)?
    var beforeEject: ((String) -> Void)?
    var beforeUnmount: ((String) -> Void)?

    func start() {
        guard session == nil, let session = DASessionCreate(kCFAllocatorDefault) else { return }
        self.session = session
        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, { _, context in
            guard let context else { return }
            Unmanaged<ExternalVolumeMonitor>.fromOpaque(context).takeUnretainedValue().onChange?()
        }, context)
        DARegisterDiskDisappearedCallback(session, nil, { _, context in
            guard let context else { return }
            Unmanaged<ExternalVolumeMonitor>.fromOpaque(context).takeUnretainedValue().onChange?()
        }, context)
        DARegisterDiskDescriptionChangedCallback(session, nil, nil, { _, _, context in
            guard let context else { return }
            Unmanaged<ExternalVolumeMonitor>.fromOpaque(context).takeUnretainedValue().onChange?()
        }, context)
        DARegisterDiskUnmountApprovalCallback(session, nil, { disk, context in
            guard let context else { return nil }
            Unmanaged<ExternalVolumeMonitor>.fromOpaque(context).takeUnretainedValue().approveUnmount(disk)
            return nil
        }, context)
        DARegisterDiskEjectApprovalCallback(session, nil, { disk, context in
            guard let context else { return nil }
            Unmanaged<ExternalVolumeMonitor>.fromOpaque(context).takeUnretainedValue().approve(disk)
            return nil
        }, context)
        DASessionSetDispatchQueue(session, queue)
    }
    private func approveUnmount(_ disk: DADisk) {
        guard let description = DADiskCopyDescription(disk) as? [String: Any],
              let uuid = Self.volumeUUID(in: description) else { return }
        beforeUnmount?(uuid)
    }
    static func volumeUUID(in description: [String: Any]) -> String? {
        guard let raw = description[kDADiskDescriptionVolumeUUIDKey as String],
              CFGetTypeID(raw as CFTypeRef) == CFUUIDGetTypeID() else { return nil }
        let uuid = raw as! CFUUID
        return (CFUUIDCreateString(kCFAllocatorDefault, uuid) as String).uppercased()
    }
    private func approve(_ disk: DADisk) {
        let whole = DADiskCopyWholeDisk(disk) ?? disk
        if let bsd = DADiskGetBSDName(whole) { beforeEject?(String(cString: bsd)) }
    }
    func stop() {
        guard let session else { return }
        DASessionSetDispatchQueue(session, nil)
        // Drain callbacks before their unretained context can be released.
        queue.sync { }
        self.session = nil
    }
    deinit { stop() }

    static func mounted() -> [ExternalVolume] {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return [] }
        let rolesByUUID = apfsRoles()
        let keys: Set<URLResourceKey> = [.volumeUUIDStringKey, .volumeNameKey, .volumeIsLocalKey,
                                        .volumeIsRootFileSystemKey, .volumeIsBrowsableKey, .volumeIsReadOnlyKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: []) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys), let uuid = values.volumeUUIDString,
                  let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
                  let raw = DADiskCopyDescription(disk) as? [String: Any] else { return nil }
            let whole = DADiskCopyWholeDisk(disk) ?? disk
            let wholeDescription = (DADiskCopyDescription(whole) as? [String: Any]) ?? raw
            let device = DADiskGetBSDName(whole).map { String(cString: $0) } ?? ""
            let bus = (wholeDescription[kDADiskDescriptionDeviceProtocolKey as String] as? String ?? "").lowercased()
            let model = (wholeDescription[kDADiskDescriptionDeviceModelKey as String] as? String ?? "").lowercased()
            var roles = (raw["DAVolumeRole"] as? [String]) ?? []
            if let role = raw["DAVolumeRole"] as? String { roles.append(role) }
            roles += rolesByUUID[uuid.uppercased()] ?? []
            let userVolume = values.volumeIsLocal == true && values.volumeIsRootFileSystem != true
                && values.volumeIsBrowsable == true && !url.path.hasPrefix("/System/Volumes/")
            let backup = roles.contains { $0.lowercased() == "backup" }
                || (userVolume && ["Backups.backupdb", ".com.apple.timemachine.supported", "com.apple.TimeMachine.MachineID.plist"].contains {
                    FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path)
                })
            return ExternalVolume(uuid: uuid.uppercased(), name: values.volumeName ?? url.lastPathComponent,
                                  path: url.path, device: device, local: values.volumeIsLocal == true,
                                  startup: values.volumeIsRootFileSystem == true,
                                  visible: values.volumeIsBrowsable == true,
                                  writable: values.volumeIsReadOnly != true,
                                  diskImage: bus.contains("disk image") || model.contains("disk image"),
                                  timeMachine: backup, optical: bus.contains("cd") || bus.contains("dvd") || model.contains("dvd") || model.contains("cd-rom"), roles: roles)
        }
    }
    private static func apfsRoles() -> [String: [String]] {
        // A single metadata query supplies roles, including Time Machine's Backup role.
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["apfs", "list", "-plist"]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard let metadata = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let containers = metadata["Containers"] as? [[String: Any]] else { return [:] }
        var result: [String: [String]] = [:]
        for container in containers {
            for volume in container["Volumes"] as? [[String: Any]] ?? [] {
                guard let uuid = volume["APFSVolumeUUID"] as? String else { continue }
                result[uuid.uppercased()] = volume["Roles"] as? [String] ?? []
            }
        }
        return result
    }

}
