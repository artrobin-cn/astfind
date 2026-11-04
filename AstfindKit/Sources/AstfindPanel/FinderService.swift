import AppKit
import Foundation
import UniformTypeIdentifiers

/// Finder 右键“服务/快速操作 → 在 Astfind 中找相似”的接收端。
///
/// 不引入 Finder Sync 扩展：那个方案只能对注册监控的文件夹生效，且扩展必须沙盒化；
/// macOS Services 对 Finder 里任意位置的图片都生效，也不需要 appex / App Group。
protocol FinderServiceDelegate: AnyObject {
    func finderService(_ service: FinderServiceProvider, findSimilar url: URL)
}

final class FinderServiceProvider: NSObject {
    /// 与 Info.plist `NSServices` 里的 NSMessage 保持一致。
    static let message = "findSimilar"
    static let menuTitle = "在 Astfind 中找相似"

    weak var delegate: FinderServiceDelegate?

    /// 从 Finder 传来的 pasteboard 中取第一张图片文件。只接受图片 UTI，避免把文件夹/文档塞进以图搜图。
    static func imageURL(from pasteboard: NSPasteboard) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              urls.count > 0 else { return nil }
        return urls.first { url in
            guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
            return type.conforms(to: .image)
        }
    }

    /// 测试可直接调用；返回 false 表示没有可处理的图片。
    @discardableResult
    func perform(pasteboard: NSPasteboard) -> Bool {
        guard let url = Self.imageURL(from: pasteboard) else { return false }
        delegate?.finderService(self, findSimilar: url)
        return true
    }

    /// Objective-C Services 入口。签名必须是 `message:userData:error:`，与 NSServices.NSMessage 对应。
    @objc func findSimilar(_ pasteboard: NSPasteboard, userData: String,
                           error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard perform(pasteboard: pasteboard) else {
            error.pointee = "请在 Finder 中选择一张图片。" as NSString
            return
        }
    }
}
