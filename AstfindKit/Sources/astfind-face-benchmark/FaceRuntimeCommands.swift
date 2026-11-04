import AstfindFaceCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import FaceBenchmarkCore

struct FaceAlignOutput: Encodable {
    let faceCount: Int
    let selectedFaceIndex: Int
}

struct FaceEmbedOutput: Encodable {
    let dimension: Int
    let norm: Double
    let elapsedMs: Double
    let cosine: Double?
    let maxAbsDifference: Double?
}

enum FaceRuntimeError: Error {
    case imageReadFailed
    case imageWriteFailed
    case invalidReference
}

enum FaceRuntimeCommands {
    static func align(input: String, output: String) throws -> FaceAlignOutput {
        let image = try loadImage(at: input)
        let result = try VisionFacePreprocessor().process(image: image)
        guard let destination = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: output) as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil) else {
            throw FaceRuntimeError.imageWriteFailed
        }
        CGImageDestinationAddImage(destination, result.alignedImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw FaceRuntimeError.imageWriteFailed
        }
        return FaceAlignOutput(
            faceCount: result.faceCount,
            selectedFaceIndex: result.selectedFaceIndex)
    }

    static func embed(modelPath: String, imagePath: String, referencePath: String?) throws -> FaceEmbedOutput {
        let image = try loadImage(at: imagePath)
        let model = try FaceCoreMLModel(contentsOf: URL(fileURLWithPath: modelPath))
        let started = Date()
        let vector = try model.embed(image: image)
        let elapsedMs = Date().timeIntervalSince(started) * 1_000
        let norm = vector.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()

        var cosine: Double?
        var maxAbsDifference: Double?
        if let referencePath {
            let reference = try JSONDecoder().decode(
                [Double].self,
                from: Data(contentsOf: URL(fileURLWithPath: referencePath)))
            guard reference.count == vector.count, reference.allSatisfy(\.isFinite) else {
                throw FaceRuntimeError.invalidReference
            }
            cosine = FaceVectorSearch.cosine(vector, reference.map { Float($0) })
            maxAbsDifference = zip(vector, reference).map {
                abs(Double($0) - $1)
            }.max()
        }
        return FaceEmbedOutput(
            dimension: vector.count,
            norm: norm,
            elapsedMs: elapsedMs,
            cosine: cosine,
            maxAbsDifference: maxAbsDifference)
    }

    private static func loadImage(at path: String) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw FaceRuntimeError.imageReadFailed
        }
        return image
    }
}
