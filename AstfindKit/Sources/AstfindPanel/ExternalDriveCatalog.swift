import AppKit
import Combine
import OilFindCore

struct ExternalDriveRecord: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var path: String
    var lastConnected: Date
    var enabled = true
}

struct ExternalDrivePreferences: Codable {
    var enabled = true
    var drives: [ExternalDriveRecord] = []
}

/// Only validated UUIDs are used as file names; the catalog survives volume renames.
struct ExternalDrivePersistence {
    var directory: URL
    var metadataURL: URL { directory.appendingPathComponent("drives.json") }
    func indexURL(_ uuid: String) -> URL {
        precondition(UUID(uuidString: uuid) != nil)
        return directory.appendingPathComponent(uuid.uppercased() + ".oilfind")
    }
    func load() -> ExternalDrivePreferences {
        guard let data = try? Data(contentsOf: metadataURL),
              var preferences = try? JSONDecoder().decode(ExternalDrivePreferences.self, from: data) else { return .init() }
        var seen = Set<String>()
        preferences.drives = preferences.drives.compactMap { record in
            guard UUID(uuidString: record.id) != nil, record.path.hasPrefix("/"), !record.name.isEmpty else { return nil }
            var record = record; record.id = record.id.uppercased()
            return seen.insert(record.id).inserted ? record : nil
        }
        return preferences
    }
    func save(_ preferences: ExternalDrivePreferences) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(preferences).write(to: metadataURL, options: .atomic)
        } catch { }
    }
    func remove(_ uuid: String) { try? FileManager.default.removeItem(at: indexURL(uuid)) }
}

protocol ExternalDriveIndex: AnyObject {
    var store: IndexStore? { get }
    var state: IndexManager.State { get }
    var scannedCount: Int { get }
    var onStateChange: ((IndexManager.State) -> Void)? { get set }
    var onIndexChange: (() -> Void)? { get set }
    func start()
    func startOffline()
    func stop()
}
extension IndexManager: ExternalDriveIndex { }

final class ExternalDriveCatalog: ObservableObject, ExternalDriveCatalogReading {
    struct Row: Identifiable {
        enum Status { case connected, indexing, offline, disabled }
        var record: ExternalDriveRecord
        var status: Status
        var count: Int
        var id: String { record.id }
    }
    private struct SourceSignature: Equatable {
        var id: String
        var name: String
        var online: Bool
        var store: ObjectIdentifier
        var version: UInt64
    }
    private var lastSourceSignature: [SourceSignature] = []
    private struct Session {
        var index: ExternalDriveIndex
        var path: String
        var device: String
        var online: Bool
    }
    @Published private(set) var enabled = true
    @Published private(set) var ready = false
    @Published private(set) var rows: [Row] = []
    private var discovered = false
    private var preferences = ExternalDrivePreferences()
    private var volumes: [String: ExternalVolume] = [:]
    private var removedUntilDisconnect = Set<String>()
    private var sessions: [String: Session] = [:]
    private let sessionLock = NSLock()
    private var ejectingDevices = Set<String>()
    private var unmountingVolumes = Set<String>()
    private var approvalsInProgress = Set<String>()
    private let discoveryQueue = DispatchQueue(label: "com.oiloil.find.external-discovery", qos: .utility)
    private let ioQueue = DispatchQueue(label: "com.oiloil.find.external-catalog", qos: .utility)
    private let persistence: ExternalDrivePersistence
    private let catalogChanges = PassthroughSubject<Void, Never>()
    private var lastKnownDrives: [ExternalDriveInfo] = []
    private let monitor: ExternalDriveMonitoring
    private let discover: () -> [ExternalVolume]
    private let makeIndex: (IndexConfig, URL, String) -> ExternalDriveIndex
    private var started = false, stopped = false, monitoring = false, discovering = false, discoveryPending = false
    private var discoveryGeneration = 0
    private var progressTimer: Timer?
    var onSourcesChange: (() -> Void)?
    #if DEBUG
    private(set) var snapshot = false
    var allowDiskImages = false
    #endif

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Astfind/external-drives", isDirectory: true),
         monitor: ExternalDriveMonitoring = ExternalVolumeMonitor(),
         initialPreferences: ExternalDrivePreferences? = nil,
         discover: @escaping () -> [ExternalVolume] = ExternalVolumeMonitor.mounted,
         makeIndex: @escaping (IndexConfig, URL, String) -> ExternalDriveIndex = { IndexManager(config: $0, dbURL: $1, volumeUUID: $2) }) {
        persistence = ExternalDrivePersistence(directory: directory)
        self.monitor = monitor; self.discover = discover; self.makeIndex = makeIndex
        if let initialPreferences {
            preferences = initialPreferences; enabled = initialPreferences.enabled; ready = true
        }
        monitor.onChange = { [weak self] in DispatchQueue.main.async { self?.discoverVolumes() } }
        monitor.beforeEject = { [weak self] device in self?.prepareToEject(device: device) }
        monitor.beforeUnmount = { [weak self] uuid in self?.prepareToUnmount(uuid: uuid) }
    }
    private func withSessions<T>(_ body: () -> T) -> T {
        sessionLock.lock(); defer { sessionLock.unlock() }; return body()
    }
    var changes: AnyPublisher<Void, Never> { catalogChanges.eraseToAnyPublisher() }
    var knownDrives: [ExternalDriveInfo] {
        guard usable, discovered else { return [] }
        return preferences.drives.map { record in
            let volume = volumes[record.id]
            let connected = withSessions {
                approvalsInProgress.contains(record.id) || (volume.map {
                    !unmountingVolumes.contains(record.id) && !ejectingDevices.contains($0.device)
                } ?? false)
            }
            return ExternalDriveInfo(id: record.id, name: record.name, path: record.path,
                                     enabled: record.enabled, isConnected: connected, catalogURL: persistence.indexURL(record.id))
        }
    }
    var usable: Bool { enabled && ready && !stopped }
    func start() {
        guard !started else { return }; started = true
        #if DEBUG
        if snapshot { publish(); return }
        #endif
        if ready { configurationChanged(); return }
        let persistence = self.persistence
        ioQueue.async { [weak self] in
            let loaded = persistence.load()
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped else { return }
                self.preferences = loaded; self.enabled = loaded.enabled; self.ready = true
                self.configurationChanged()
            }
        }
    }
    func stop() {
        stopped = true; discoveryGeneration += 1
        progressTimer?.invalidate(); progressTimer = nil
        if monitoring { monitor.stop(); monitoring = false }
        let current = withSessions { let value = sessions; sessions.removeAll(); return value }
        current.values.forEach { $0.index.stop() }
        notifySources()
    }
    deinit {
        progressTimer?.invalidate(); monitor.stop()
        sessions.values.forEach { $0.index.stop() }
    }
    private func configurationChanged() {
        #if DEBUG
        if snapshot { publish(); return }
        #endif
        if usable {
            if !monitoring { monitor.start(); monitoring = true }
            discoverVolumes()
        } else {
            if monitoring { monitor.stop(); monitoring = false }
            discoveryGeneration += 1
            // Mounts can change while monitoring is suspended; rediscover before going online.
            volumes.removeAll(); discovered = false
            withSessions { ejectingDevices.removeAll(); unmountingVolumes.removeAll() }
        }
        reconcile()
    }
    private func persist() {
        #if DEBUG
        if snapshot { return }
        #endif
        let preferences = self.preferences, persistence = self.persistence
        ioQueue.async { persistence.save(preferences) }
    }
    func setEnabled(_ value: Bool) {
        guard ready, value != enabled else { return }
        enabled = value; preferences.enabled = value; persist(); configurationChanged()
    }
    func setDriveEnabled(_ uuid: String, _ value: Bool) {
        guard usable, let i = preferences.drives.firstIndex(where: { $0.id == uuid }), preferences.drives[i].enabled != value else { return }
        preferences.drives[i].enabled = value
        if !value { discardIndex(uuid) }
        persist(); reconcile()
    }
    func remove(_ uuid: String) {
        guard usable, preferences.drives.contains(where: { $0.id == uuid }) else { return }
        discardIndex(uuid); preferences.drives.removeAll { $0.id == uuid }
        // Keep the mounted volume suppressed until its next mount notification.
        removedUntilDisconnect.insert(uuid)
        volumes.removeValue(forKey: uuid)
        persist(); publish()
    }
    func confirmRemove(_ row: Row, window: NSWindow?) {
        guard usable, let window else { return }
        let alert = NSAlert()
        alert.messageText = L10n.text("driveRemoveTitle", row.record.name)
        alert.informativeText = L10n.text("driveRemoveBody")
        alert.addButton(withTitle: L10n.text("driveRemove"))
        alert.addButton(withTitle: L10n.text("action.cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.remove(row.id) }
        }
    }
    private func discardIndex(_ uuid: String) {
        let index = withSessions { sessions.removeValue(forKey: uuid)?.index }
        index?.stop()
        #if DEBUG
        if snapshot { return }
        #endif
        persistence.remove(uuid)
    }
    func discoverVolumes() {
        guard usable else { return }
        if discovering { discoveryPending = true; return }
        discovering = true
        let generation = discoveryGeneration, discover = self.discover
        discoveryQueue.async { [weak self] in
            let mounted = discover()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.discovering = false
                if self.usable, self.discoveryGeneration == generation { self.updateMounted(mounted) }
                if self.discoveryPending { self.discoveryPending = false; self.discoverVolumes() }
            }
        }
    }
    func updateMounted(_ mounted: [ExternalVolume], now: Date = Date()) {
        #if DEBUG
        let allowImages = allowDiskImages
        #else
        let allowImages = false
        #endif
        let candidates = mounted.filter { $0.eligible(allowDiskImages: allowImages) }
        removedUntilDisconnect.formIntersection(Set(candidates.map { $0.uuid.uppercased() }))
        let eligible = candidates.filter { !removedUntilDisconnect.contains($0.uuid.uppercased()) }
        discovered = true
        let previous = volumes
        volumes = Dictionary(eligible.map { ($0.uuid.uppercased(), $0) }, uniquingKeysWith: { first, _ in first })
        withSessions {
            ejectingDevices.formIntersection(Set(eligible.map(\.device)))
            unmountingVolumes.formIntersection(Set(eligible.map { $0.uuid.uppercased() }))
        }
        for (uuid, volume) in volumes {
            if let i = preferences.drives.firstIndex(where: { $0.id == uuid }) {
                preferences.drives[i].name = volume.name; preferences.drives[i].path = volume.path
                if previous[uuid] == nil || previous[uuid]?.path != volume.path { preferences.drives[i].lastConnected = now }
            } else {
                preferences.drives.append(.init(id: uuid, name: volume.name, path: volume.path, lastConnected: now))
            }
        }
        persist(); reconcile()
    }
    private func config(path: String) -> IndexConfig {
        let standard = IndexConfig.standard()
        return IndexConfig(rootPath: path, excludedNames: standard.excludedNames)
    }
    private func reconcile() {
        #if DEBUG
        if snapshot { publish(); return }
        #endif
        for record in preferences.drives {
            let volume = volumes[record.id]
            let suppressed = withSessions { unmountingVolumes.contains(record.id) || (volume.map { ejectingDevices.contains($0.device) } ?? false) }
            let online = volume != nil && !suppressed
            let old = withSessions { sessions[record.id] }
            // 与上游差异（Astfind C 场景）：在线状态翻转也要重建会话——离线会话在盘重新插上时必须让位给在线扫描，
            // 反之在线会话在拔盘后转为离线快照会话，而不是整源消失。见 docs/fork-diff.md。
            if let old, !usable || !record.enabled || old.online != online || old.path != record.path {
                if old.online { old.index.stop() }
                _ = withSessions { sessions.removeValue(forKey: record.id) }
            }
            guard usable, record.enabled, withSessions({ sessions[record.id] == nil }) else { continue }
            if !online {
                // 拔盘后仅当本地留有该卷的索引快照才挂离线会话；从未建过索引的盘离线时不可检索。
                guard FileManager.default.fileExists(atPath: persistence.indexURL(record.id).path) else { continue }
            }
            let index = makeIndex(config(path: record.path), persistence.indexURL(record.id), record.id)
            index.onStateChange = { [weak self, weak index] _ in
                guard let self, let index, self.withSessions({ self.sessions[record.id]?.index === index }) else { return }
                self.publish()
            }
            index.onIndexChange = { [weak self, weak index] in
                guard let self, let index, self.withSessions({ self.sessions[record.id]?.index === index }) else { return }
                self.publish()
            }
            withSessions { sessions[record.id] = Session(index: index, path: record.path, device: volume?.device ?? "", online: online) }
            if online { index.start() } else { index.startOffline() }
        }
        publish()
    }
    /// Called synchronously from Disk Arbitration before its approval is returned.
    func prepareToEject(device: String) {
        prepareApproval {
            let affected = sessions.filter { $0.value.online && $0.value.device == device }
            if !affected.isEmpty { ejectingDevices.insert(device) }
            for uuid in affected.keys { sessions[uuid]?.online = false; approvalsInProgress.insert(uuid) }
            return affected
        }
    }
    func prepareToUnmount(uuid: String) {
        let uuid = uuid.uppercased()
        prepareApproval {
            let affected = sessions.filter { $0.key == uuid && $0.value.online }
            if !affected.isEmpty { unmountingVolumes.insert(uuid); sessions[uuid]?.online = false; approvalsInProgress.insert(uuid) }; return affected
        }
    }
    private func prepareApproval(_ affectedSessions: () -> [String: Session]) {
        let affected = withSessions(affectedSessions)
        guard !affected.isEmpty else { return }
        for session in affected.values { session.index.stop() }
        // State callbacks can run while stop is saving. Publish disconnection only after every catalog is complete.
        withSessions { approvalsInProgress.subtract(affected.keys) }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.publish()
        }
    }
    func searchSources() -> [SearchSource] {
        guard usable else { return [] }
        return preferences.drives.filter(\.enabled).compactMap { record in
            let session = withSessions { sessions[record.id] }
            guard let session, let store = session.index.store else { return nil }
            // 在线会话校验 rootPath，防止同路径挂了别的卷；离线快照按 UUID 文名持久化，天然只属于本卷。
            if session.online, store.rootPath != record.path { return nil }
            let config = config(path: store.rootPath)
            return SearchSource(id: record.id, displayName: record.name, isOnline: session.online, store: store,
                                explainPath: { Coverage.explain(path: $0, config: config, store: store) })
        }
    }
    private func notifySources() {
        let signature = searchSources().map { source in
            SourceSignature(id: source.id, name: source.displayName, online: source.isOnline,
                            store: ObjectIdentifier(source.store), version: source.store.read { source.store.version })
        }
        let known = knownDrives
        if known != lastKnownDrives { lastKnownDrives = known; catalogChanges.send() }
        guard signature != lastSourceSignature else { return }
        lastSourceSignature = signature; onSourcesChange?()
    }
    private func publish() {
        #if DEBUG
        if snapshot { objectWillChange.send(); notifySources(); return }
        #endif
        rows = preferences.drives.sorted { $0.lastConnected > $1.lastConnected }.map { record in
            let session = withSessions { sessions[record.id] }
            let store = session?.index.store
            let count = store.map { value in value.read { max(0, value.liveCount - 1) } } ?? session?.index.scannedCount ?? 0
            let status: Row.Status = !record.enabled ? .disabled : session?.online != true ? .offline
                : session?.index.state == .ready ? .connected : .indexing
            return Row(record: record, status: status, count: count)
        }
        if rows.contains(where: { $0.status == .indexing }), progressTimer == nil {
            progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.publish() }
        } else if !rows.contains(where: { $0.status == .indexing }) {
            progressTimer?.invalidate(); progressTimer = nil
        }
        notifySources()
    }
    #if DEBUG
    func prepareArguments(_ arguments: inout [String]) throws {
        for key in ["--allow-external-disk-images", "--external-drives-sample"] {
            guard arguments.filter({ $0 == key }).count <= 1 else { throw SnapshotError.failed("\(key) may only occur once") }
        }
        if arguments.contains("--external-drives-sample"), !arguments.contains("--snapshot") {
            throw SnapshotError.failed("--external-drives-sample requires --snapshot")
        }
        allowDiskImages = arguments.contains("--allow-external-disk-images")
        if arguments.contains("--snapshot") { installSnapshot(sample: arguments.contains("--external-drives-sample")) }
        arguments.removeAll { $0 == "--allow-external-disk-images" || $0 == "--external-drives-sample" }
    }
    func installSnapshot(sample: Bool = true) {
        snapshot = true; ready = true; enabled = true; discovered = true
        guard sample else { return }
        let date = Date(timeIntervalSince1970: 1791532800)
        let sample: [(String, String, Row.Status, Int)] = [
            ("00000000-0000-0000-0000-000000000001", "T7 Shield", .connected, 1_234_567),
            ("00000000-0000-0000-0000-000000000002", "SD Card", .indexing, 45_000),
            ("00000000-0000-0000-0000-000000000003", "Archive", .offline, 854_320)]
        rows = sample.enumerated().map { i, item in
            Row(record: .init(id: item.0, name: item.1, path: "/Volumes/" + item.1, lastConnected: date.addingTimeInterval(-Double(i == 2 ? 86400 : i * 1800))), status: item.2, count: item.3)
        }
        preferences.drives = rows.map(\.record)
        volumes = Dictionary(uniqueKeysWithValues: rows.filter { $0.status != .offline }.map { ($0.id, ExternalVolume(uuid: $0.id, name: $0.record.name, path: $0.record.path)) })
        notifySources()
    }
    #endif
}
