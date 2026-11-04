import CoreGraphics
import Foundation

enum FaceTestImages {
    static func rgba(width: Int, height: Int, pixels: [UInt8]) -> CGImage {
        precondition(pixels.count == width * height * 4)
        let data = Data(pixels) as CFData
        let provider = CGDataProvider(data: data)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent)!
    }

    static func solid(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) -> CGImage {
        rgba(
            width: width,
            height: height,
            pixels: Array(repeating: 255, count: width * height).flatMap { _ in
                [red, green, blue, 255]
            })
    }
}
