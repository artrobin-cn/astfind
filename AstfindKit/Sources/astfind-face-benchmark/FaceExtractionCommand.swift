import CoreGraphics
import Foundation
import FaceBenchmarkCore

struct FaceExtractionAssetRecord: Encodable {
    let assetID: String
    let sourcePath: String
    let width: Int
    let height: Int
    let detectedFaceCount: Int
    let faceCount: Int
    let error: String?

    enum CodingKeys: String, CodingKey {
        case assetID = "asset_id"
        case sourcePath = "source_path"
        case width
        case height
        case detectedFaceCount = "detected_face_count"
        case faceCount = "face_count"
        case error
    }
}

struct FaceExtractionFaceRecord: Encodable {
    let assetID: String
    let faceIndex: Int
    let detectionIndex: Int
    let boundingBox: [Double]
    let confidence: Float
    let pixelWidth: Double
    let pixelHeight: Double
    let cropFile: String
    let vector: [Float]

    enum CodingKeys: String, CodingKey {
        case assetID = "asset_id"
        case faceIndex = "face_index"
        case detectionIndex = "detection_index"
        case boundingBox = "bounding_box"
        case confidence
        case pixelWidth = "pixel_width"
        case pixelHeight = "pixel_height"
        case cropFile = "crop_file"
        case vector
    }
}

struct FaceExtractionSummary: Encodable {
    let imageCount: Int
    let processedImageCount: Int
    let failedImageCount: Int
    let faceCount: Int
    let imagesWithFaces: Int
    let elapsedMs: Double
}

struct FaceExtractionCommandOutput: Encodable {
    let summary: FaceExtractionSummary
}

enum FaceExtractionCommandError: Error, CustomStringConvertible {
    case outputDirectoryFailed
    case writeFailed

    var description: String {
        switch self {
        case .outputDirectoryFailed: return "extraction output directory failed"
        case .writeFailed: return "extraction output write failed"
        }
    }
}

enum FaceExtractionCommand {
    static func run(
        sourceDirectory: String,
        modelPath: String,
        outputDirectory: String,
        maxImages: Int?,
        minFaceSide: Int,
        minConfidence: Float
    ) throws -> FaceExtractionCommandOutput {
        let sourceURL = URL(fileURLWithPath: sourceDirectory, isDirectory: true)
        let outputURL = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        let cropsURL = outputURL.appendingPathComponent("crops", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: cropsURL,
                withIntermediateDirectories: true)
        } catch {
            throw FaceExtractionCommandError.outputDirectoryFailed
        }

        let images = try FaceBenchmarkExtractionPlanner.imageFiles(
            in: sourceURL,
            maxImages: maxImages)
        let policy = FaceBenchmarkFaceSelectionPolicy(
            minimumFaceSidePixels: Double(minFaceSide),
            minimumConfidence: minConfidence,
            maximumFacesPerAsset: 20)
        let preprocessor = VisionFaceBatchPreprocessor(policy: policy)
        let embedder = try FaceCoreMLEmbedder(
            modelPath: modelPath,
            dimension: 512,
            modelIdentifier: "buffalo_sc")

        let started = Date()
        var assets: [FaceExtractionAssetRecord] = []
        var faces: [FaceExtractionFaceRecord] = []
        var failed = 0
        var imagesWithFaces = 0

        for (offset, imageURL) in images.enumerated() {
            let relative = imageURL.path.replacingOccurrences(
                of: sourceURL.path.hasSuffix("/") ? sourceURL.path : sourceURL.path + "/",
                with: "")
            let assetID = FaceBenchmarkExtractionPlanner.assetID(relativePath: relative)
            let image: CGImage
            do {
                image = try FaceBenchmarkImageIO.load(path: imageURL.path)
            } catch {
                failed += 1
                assets.append(FaceExtractionAssetRecord(
                    assetID: assetID,
                    sourcePath: imageURL.path,
                    width: 0,
                    height: 0,
                    detectedFaceCount: 0,
                    faceCount: 0,
                    error: "read_failed"))
                continue
            }

            let processed: [FaceBenchmarkPreprocessedFace]
            do {
                processed = try preprocessor.process(image: image)
            } catch {
                assets.append(FaceExtractionAssetRecord(
                    assetID: assetID,
                    sourcePath: imageURL.path,
                    width: image.width,
                    height: image.height,
                    detectedFaceCount: 0,
                    faceCount: 0,
                    error: nil))
                if (offset + 1) % 10 == 0 {
                    writeProgress(offset + 1, faces: faces.count)
                }
                continue
            }
            let accepted = FaceBenchmarkFaceSelection.accepted(
                processed.map(\.region),
                policy: policy)
            let byIndex = Dictionary(
                uniqueKeysWithValues: processed.map { ($0.region.detectionIndex, $0) })
            let selectedFaces = accepted.compactMap { byIndex[$0.detectionIndex] }
            guard selectedFaces.count == accepted.count else {
                throw FaceExtractionCommandError.writeFailed
            }

            if !selectedFaces.isEmpty {
                let vectors = try embedder.embed(images: selectedFaces.map(\.alignedImage))
                guard vectors.count == selectedFaces.count else {
                    throw FaceExtractionCommandError.writeFailed
                }
                for (faceIndex, pair) in zip(selectedFaces, vectors).enumerated() {
                    let cropFile = "crops/\(assetID)_\(faceIndex).png"
                    do {
                        try FaceBenchmarkImageIO.writePNG(
                            pair.0.alignedImage,
                            to: outputURL.appendingPathComponent(cropFile))
                    } catch {
                        throw FaceExtractionCommandError.writeFailed
                    }
                    let region = pair.0.region
                    faces.append(FaceExtractionFaceRecord(
                        assetID: assetID,
                        faceIndex: faceIndex,
                        detectionIndex: region.detectionIndex,
                        boundingBox: [
                            Double(region.boundingBox.origin.x),
                            Double(region.boundingBox.origin.y),
                            Double(region.boundingBox.width),
                            Double(region.boundingBox.height)
                        ],
                        confidence: region.confidence,
                        pixelWidth: region.pixelWidth,
                        pixelHeight: region.pixelHeight,
                        cropFile: cropFile,
                        vector: pair.1))
                }
                imagesWithFaces += 1
            }
            assets.append(FaceExtractionAssetRecord(
                assetID: assetID,
                sourcePath: imageURL.path,
                width: image.width,
                height: image.height,
                detectedFaceCount: processed.count,
                faceCount: selectedFaces.count,
                error: nil))
            if (offset + 1) % 10 == 0 {
                writeProgress(offset + 1, faces: faces.count)
            }
        }

        let summary = FaceExtractionSummary(
            imageCount: images.count,
            processedImageCount: images.count - failed,
            failedImageCount: failed,
            faceCount: faces.count,
            imagesWithFaces: imagesWithFaces,
            elapsedMs: Date().timeIntervalSince(started) * 1_000)
        do {
            try writeJSONLines(assets, to: outputURL.appendingPathComponent("assets.jsonl"))
            try writeJSONLines(faces, to: outputURL.appendingPathComponent("faces.jsonl"))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(summary).write(
                to: outputURL.appendingPathComponent("summary.json"),
                options: .atomic)
        } catch {
            throw FaceExtractionCommandError.writeFailed
        }
        return FaceExtractionCommandOutput(summary: summary)
    }

    private static func writeProgress(_ images: Int, faces: Int) {
        FileHandle.standardError.write(Data("extracted images=\(images) faces=\(faces)\n".utf8))
    }

    private static func writeJSONLines<T: Encodable>(_ values: [T], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = Data()
        for value in values {
            data.append(try encoder.encode(value))
            data.append(0x0A)
        }
        try data.write(to: url, options: .atomic)
    }
}
