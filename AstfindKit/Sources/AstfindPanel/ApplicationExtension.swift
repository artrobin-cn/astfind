import AppKit
import SwiftUI
import Combine
import OilFindCore

public struct ApplicationMenuItem {
    public let title: String
    public let isVisible: Bool
    public let action: () -> Void

    public init(title: String, isVisible: Bool = true, action: @escaping () -> Void) {
        self.title = title; self.isVisible = isVisible; self.action = action
    }
}

/// Read-only identity and catalog location for a known external drive.
public struct ExternalDriveInfo: Equatable {
    public let id: String
    public let name: String
    public let path: String
    public let enabled: Bool
    public let isConnected: Bool
    public let catalogURL: URL

    public init(id: String, name: String, path: String, enabled: Bool, isConnected: Bool, catalogURL: URL) {
        self.id = id; self.name = name; self.path = path; self.enabled = enabled
        self.isConnected = isConnected; self.catalogURL = catalogURL
    }
}

/// Snapshots and notifications are delivered on the main thread.
public protocol ExternalDriveCatalogReading: AnyObject {
    var knownDrives: [ExternalDriveInfo] { get }
    var changes: AnyPublisher<Void, Never> { get }
}

/// Optional application integration, outside the search and indexing hot paths.
public protocol ApplicationExtension: AnyObject {
    /// An extension may finish a dedicated invocation before the app is initialized.
    func handleLaunch(arguments: [String]) -> Int32?
    #if DEBUG
    func prepareArguments(_ arguments: inout [String]) throws
    #endif
    func attachExternalDrives(_ catalog: ExternalDriveCatalogReading)
    /// 面板主索引（本机盘文件名索引属主）就绪/变化时注入——内容范围选择器据此零双扫登记资产。
    func attachPrimaryIndex(_ manager: IndexManager)
    func start(chinese: Bool, showSettings: @escaping () -> Void)
    func searchSources() -> [SearchSource]
    /// 面板打开结果前的预检（SMB 服务端存活）。默认放行；Astfind 扩展会做真实探测。
    func isSourceReachable(_ source: SearchSource) -> Bool
    var supplementarySearchProvider: SupplementarySearchProvider? { get }
    var onSearchSourcesChange: (() -> Void)? { get set }
    var settingsMenuItem: ApplicationMenuItem? { get }
    var onSettingsMenuItemChange: (() -> Void)? { get set }
    func stop()
    func languageDidChange(chinese: Bool)
    func handle(_ url: URL)
    func quickLookVisibilityChanged(_ visible: Bool)
    func setExternalAppActive(_ active: Bool)
    func settingsSection(window: @escaping () -> NSWindow?) -> AnyView
}

public extension ApplicationExtension {
    func handleLaunch(arguments: [String]) -> Int32? { nil }
    func attachExternalDrives(_ catalog: ExternalDriveCatalogReading) { }
    func attachPrimaryIndex(_ manager: IndexManager) { }
    var settingsMenuItem: ApplicationMenuItem? { nil }
    var onSettingsMenuItemChange: (() -> Void)? { get { nil } set { } }
    var supplementarySearchProvider: SupplementarySearchProvider? { nil }
    func searchSources() -> [SearchSource] { [] }
    func isSourceReachable(_ source: SearchSource) -> Bool { true }
    func quickLookVisibilityChanged(_ visible: Bool) { }
    func setExternalAppActive(_ active: Bool) { }
    var onSearchSourcesChange: (() -> Void)? { get { nil } set { } }
}

#if DEBUG
public extension ApplicationExtension {
    func prepareArguments(_ arguments: inout [String]) throws { }
}
#endif
