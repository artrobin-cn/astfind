import XCTest
import AppKit
import OilFindCore
@testable import AstfindKit
@testable import AstfindPanel

/// 开发者实测场景复刻（2026-10-19）：`/Volumes/ExternalSSD/Downloads-Backup/example.jpeg`
/// 里的「人民教师」搜不到——外置盘文件名索引属面板 catalog，内容索引未覆盖。
/// 内容专用来源（schema v3）：复用 catalog 索引文件登记资产，只做 OCR，
/// 不进 sources()（文件名不重复），面板补充通道命中可反查回 catalog 源的 entry。
final class ContentOnlySourceTests: XCTestCase {
    private var home: URL!
    private var volume: URL!

    private final class FakeDriveMonitor: ExternalDriveMonitoring {
        var onChange: (() -> Void)?
        var beforeEject: ((String) -> Void)?
        var beforeUnmount: ((String) -> Void)?
        func start() {}
        func stop() {}
    }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("astfind-content-only-\(UUID().uuidString)")
        volume = home.appendingPathComponent("ExternalSSD/Downloads-Backup")
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func makeImage(text: String, at url: URL) throws {
        let size = NSSize(width: 480, height: 140)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        (text as NSString).draw(at: NSPoint(x: 30, y: 50),
            withAttributes: [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black])
        image.unlockFocus()
        let data = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?
            .representation(using: .png, properties: [:]))
        try data.write(to: url)
    }

    func testExternalSSDImageTextSearchableViaContentOnlySource() throws {
        let uuid = UUID().uuidString.uppercased()
        try makeImage(text: "人民教师 光荣之家", at: volume.appendingPathComponent("12944978.jpeg"))

        // ① 面板 catalog 先建好文件名索引（生产路径：插盘授权→扫描→落盘）
        let extDir = home.appendingPathComponent("external-drives")
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        let storeFile = extDir.appendingPathComponent("\(uuid).oilfind")
        let catalog = ExternalDriveCatalog(
            directory: extDir, monitor: FakeDriveMonitor(),
            initialPreferences: ExternalDrivePreferences(
                drives: [ExternalDriveRecord(id: uuid, name: "ExternalSSD", path: volume.path, lastConnected: Date())]),
            discover: { [ExternalVolume(uuid: uuid, name: "ExternalSSD", path: self.volume.path)] },
            makeIndex: { config, url, _ in IndexManager(config: config, dbURL: url, volumeUUID: nil) })
        catalog.start()
        let deadline = Date(timeIntervalSinceNow: 20)
        while Date() < deadline {
            if catalog.searchSources().contains(where: { $0.id == uuid && $0.isOnline && $0.store != nil }) { break }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        catalog.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeFile.path), "catalog 索引文件应已落盘")

        // ② 引擎建立内容专用来源（扩展 attachExternalDrives 的驱动逻辑收敛于此）
        let engine = try AstfindEngine(home: home.appendingPathComponent("data"))
        engine.autoExtractContent = false
        _ = try engine.ensureContentSource(volumeUUID: uuid, name: "ExternalSSD",
                                           mountPath: volume.path, storeFile: storeFile)
        // 幂等：重复驱动不产生重复来源
        _ = try engine.ensureContentSource(volumeUUID: uuid, name: "ExternalSSD",
                                           mountPath: volume.path, storeFile: storeFile)

        // ③ 内容专用来源对文件名检索与用户来源清单不可见（同卷不双扫/不重复出结果）
        XCTAssertTrue(engine.sources().isEmpty)
        XCTAssertTrue(engine.records().isEmpty)

        // ④ 内容抽取 + 面板补充通道：命中可反查回 catalog 源的 entry
        _ = try XCTUnwrap(engine.extractContent(sourceId: nil))
        let panelSources = [SearchSource(id: uuid, displayName: "ExternalSSD", isOnline: true,
                                         store: try XCTUnwrap(IndexStore.load(from: storeFile.path)))]
        let provider = ContentSupplementaryProvider(engine: engine)
        let work = provider.prepareSearch(Query.parse("人民教师"), options: SearchOptions(),
                                          sources: panelSources, isCancelled: { false })
        let hits = work()
        let hit = try XCTUnwrap(hits.first, "面板通道应返回 ExternalSSD 图片的 OCR 命中")
        XCTAssertTrue(hit.detail.contains("图片OCR"), hit.detail)
        let path = panelSources[0].store.path(hit.entryID)
        XCTAssertTrue(path.hasSuffix("12944978.jpeg"), "反查路径 \(path)")

        engine.stop()
    }
}
