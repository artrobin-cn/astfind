import CryptoKit
import Foundation

public enum FaceBenchmarkExtractionError: Error, Equatable {
    case directoryUnreadable
}

public enum FaceBenchmarkExtractionPlanner {
    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "bmp"
    ]

    public static func imageFiles(
        in directory: URL,
        maxImages: Int?
    ) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else {
            throw FaceBenchmarkExtractionError.directoryUnreadable
        }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            guard imageExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            urls.append(url)
        }
        urls.sort { $0.path < $1.path }
        if let maxImages {
            return Array(urls.prefix(max(0, maxImages)))
        }
        return urls
    }

    public static func assetID(relativePath: String) -> String {
        let digest = SHA256.hash(data: Data(relativePath.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
