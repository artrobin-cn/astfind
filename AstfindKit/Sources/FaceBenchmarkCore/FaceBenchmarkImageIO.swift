import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum FaceBenchmarkImageIOError: Error, Equatable {
    case readFailed
    case writeFailed
    case scalingFailed
}

public enum FaceBenchmarkImageScaler {
    public static func scaled(_ image: CGImage, maxSide: Int) throws -> CGImage {
        guard maxSide > 0 else { throw FaceBenchmarkImageIOError.scalingFailed }
        let largest = max(image.width, image.height)
        guard largest > maxSide else { return image }
        let scale = Double(maxSide) / Double(largest)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            throw FaceBenchmarkImageIOError.scalingFailed
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else {
            throw FaceBenchmarkImageIOError.scalingFailed
        }
        return result
    }
}

public enum FaceBenchmarkImageIO {
    public static func load(path: String) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(
            URL(fileURLWithPath: path) as CFURL,
            nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw FaceBenchmarkImageIOError.readFailed
        }
        return image
    }

    public static func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil)
        else {
            throw FaceBenchmarkImageIOError.writeFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw FaceBenchmarkImageIOError.writeFailed
        }
        return data as Data
    }

    public static func writePNG(_ image: CGImage, to url: URL) throws {
        let data = try pngData(image)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw FaceBenchmarkImageIOError.writeFailed
        }
    }

    public static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.85) throws {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil)
        else {
            throw FaceBenchmarkImageIOError.writeFailed
        }
        let options = [
            kCGImageDestinationLossyCompressionQuality: max(0, min(1, quality))
        ] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else {
            throw FaceBenchmarkImageIOError.writeFailed
        }
        do {
            try (data as Data).write(to: url, options: .atomic)
        } catch {
            throw FaceBenchmarkImageIOError.writeFailed
        }
    }
}
