import AppKit
import UniformTypeIdentifiers

enum ImagePasteSource {
    case data(Data)
    case file(URL)
}

/// 拖入/粘贴的图片提取规则（面板与搜索框共用）：
/// - Finder 复制的单张图片文件 → 文件 URL（即使剪贴板同时带路径字符串也优先以图搜图）；
/// - 截图/浏览器复制的位图 → 仅在剪贴板没有纯文本时接管，绝不抢普通文字粘贴。
enum ImagePasteboard {
    static let types: [NSPasteboard.PasteboardType] = [.fileURL, .tiff, .png]

    #if DEBUG
    /// 测试注入：避免 UI 集成测试改写用户真实剪贴板（release 不含）。
    static var testPasteboard: NSPasteboard?
    #endif
    private static var activePasteboard: NSPasteboard {
        #if DEBUG
        if let testPasteboard { return testPasteboard }
        #endif
        return .general
    }

    static func imageURL(from pasteboard: NSPasteboard) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              urls.count == 1 else { return nil }
        let url = urls[0]
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()), type.conforms(to: .image) else { return nil }
        return url
    }

    static func hasImage(_ pasteboard: NSPasteboard) -> Bool {
        if imageURL(from: pasteboard) != nil { return true }
        return pasteboard.data(forType: .png) != nil || pasteboard.data(forType: .tiff) != nil
    }

    static func pasteSource(from pasteboard: NSPasteboard? = nil) -> ImagePasteSource? {
        let pb = pasteboard ?? activePasteboard
        if let url = imageURL(from: pb) { return .file(url) }
        guard pb.string(forType: .string) == nil else { return nil }
        if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff) { return .data(data) }
        return nil
    }

    static func dropSource(from pasteboard: NSPasteboard) -> ImagePasteSource? {
        if let url = imageURL(from: pasteboard) { return .file(url) }
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) { return .data(data) }
        return nil
    }

    /// 从磁盘读取图片带看门狗：NAS/SMB 坏文件可能卡死读线程（超时返回 nil，不吊住 UI）。
    static func readData(at url: URL, timeout: TimeInterval = 10) -> Data? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = DataBox()
        DispatchQueue.global(qos: .userInitiated).async {
            box.value = try? Data(contentsOf: url)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.value
    }
    private final class DataBox: @unchecked Sendable { var value: Data? }
}
