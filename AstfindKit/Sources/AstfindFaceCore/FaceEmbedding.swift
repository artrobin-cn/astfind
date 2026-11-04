import CoreGraphics
import CoreImage
import CoreML
import CoreVideo
import Foundation

public enum FaceEmbeddingError: Error, Equatable {
    case invalidImageSize
    case pixelBufferCreationFailed
    case invalidOutputDimension
    case nonFiniteOutput
    case zeroNorm
    case modelInputNotFound
    case modelOutputNotFound
}

public enum FaceInputTensor {
    public static func make112(image: CGImage) throws -> MLMultiArray {
        guard image.width == 112, image.height == 112 else {
            throw FaceEmbeddingError.invalidImageSize
        }
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            112,
            112,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer)
        guard status == kCVReturnSuccess, let pixelBuffer = buffer else {
            throw FaceEmbeddingError.pixelBufferCreationFailed
        }
        let tensor = try MLMultiArray(shape: [1, 3, 112, 112], dataType: .float32)
        let tensorPointer = tensor.dataPointer.bindMemory(to: Float32.self, capacity: 3 * 112 * 112)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw FaceEmbeddingError.pixelBufferCreationFailed
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(
            data: baseAddress,
            width: 112,
            height: 112,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo) else {
            throw FaceEmbeddingError.pixelBufferCreationFailed
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: 112, height: 112))
        for y in 0..<112 {
            let row = baseAddress.advanced(by: y * bytesPerRow).bindMemory(to: UInt8.self, capacity: 112 * 4)
            for x in 0..<112 {
                let pixel = x * 4
                let offset = y * 112 + x
                tensorPointer[offset] = (Float(row[pixel + 2]) - 127.5) / 127.5
                tensorPointer[112 * 112 + offset] = (Float(row[pixel + 1]) - 127.5) / 127.5
                tensorPointer[2 * 112 * 112 + offset] = (Float(row[pixel]) - 127.5) / 127.5
            }
        }
        return tensor
    }
}

public enum FaceEmbeddingValidator {
    public static func normalized(_ values: [Float], dimension: Int = 512) throws -> [Float] {
        guard values.count == dimension else { throw FaceEmbeddingError.invalidOutputDimension }
        guard values.allSatisfy(\.isFinite) else { throw FaceEmbeddingError.nonFiniteOutput }
        let norm = values.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
        guard norm > 0, norm.isFinite else { throw FaceEmbeddingError.zeroNorm }
        return values.map { Float(Double($0) / norm) }
    }
}

public final class FaceCoreMLModel {
    private let model: MLModel
    private let inputName: String
    private let outputName: String

    public init(contentsOf url: URL) throws {
        model = try MLModel(contentsOf: url)
        guard let input = model.modelDescription.inputDescriptionsByName
            .sorted(by: { $0.key < $1.key })
            .first(where: { $0.value.type == .multiArray }) else {
            throw FaceEmbeddingError.modelInputNotFound
        }
        guard let output = model.modelDescription.outputDescriptionsByName
            .sorted(by: { $0.key < $1.key })
            .first(where: { $0.value.type == .multiArray }) else {
            throw FaceEmbeddingError.modelOutputNotFound
        }
        inputName = input.key
        outputName = output.key
    }

    public func embed(image: CGImage) throws -> [Float] {
        let tensor = try FaceInputTensor.make112(image: image)
        let input = try MLDictionaryFeatureProvider(dictionary: [
            inputName: MLFeatureValue(multiArray: tensor)
        ])
        let prediction = try model.prediction(from: input)
        guard let output = prediction.featureValue(for: outputName)?.multiArrayValue else {
            throw FaceEmbeddingError.modelOutputNotFound
        }
        let values = (0..<output.count).map { output[$0].floatValue }
        return try FaceEmbeddingValidator.normalized(values)
    }
}
