import CoreGraphics
import Foundation
import FaceBenchmarkCore

enum FaceBenchmarkCLIError: Error, CustomStringConvertible {
    case usage
    case readFailed
    case writeFailed
    case invalidOption(String)

    var description: String {
        switch self {
        case .usage: return "invalid command usage"
        case .readFailed: return "local file read failed"
        case .writeFailed: return "local file write failed"
        case .invalidOption(let name): return "invalid option \(name)"
        }
    }
}

struct FaceBenchmarkPolicyOutput: Encodable {
    let minimumFaceSidePixels: Double
    let minimumConfidence: Float
    let maximumFacesPerAsset: Int
}

struct FaceHealthCommandOutput: Encodable {
    let healthy: Bool
    let model: String
    let dimension: Int
}

struct FaceIndexCommandOutput: Encodable {
    let stats: FaceBenchmarkIndexBuildStats
    let policy: FaceBenchmarkPolicyOutput
    let profileFingerprint: String
}

struct FaceQueryCommandOutput: Encodable {
    let queryCount: Int
    let knownQueryCount: Int
    let unknownQueryCount: Int
    let failureReasonCounts: [String: Int]
    let summary: FaceBenchmarkSummary
}

struct FaceVideoSampleCommandOutput: Encodable {
    let frameCount: Int
    let frames: [FaceBenchmarkExtractedFrame]
}

enum FaceBenchmarkCommands {
    static func remoteHealth() throws -> FaceHealthCommandOutput {
        let configuration = try BuffaloLRemoteConfiguration.load()
        let health = try BuffaloLClient(configuration: configuration).health()
        return FaceHealthCommandOutput(
            healthy: true,
            model: health.model,
            dimension: health.dimension)
    }

    static func indexLocal(
        manifestPath: String,
        modelPath: String,
        storePath: String,
        generation: Int
    ) throws -> FaceIndexCommandOutput {
        let manifest = try requireManifest(manifestPath)
        let policy = FaceBenchmarkFaceSelectionPolicy()
        let embedder = try FaceCoreMLEmbedder(
            modelPath: modelPath,
            dimension: manifest.profile.dimension)
        return try index(
            manifest: manifest,
            embedder: embedder,
            storePath: storePath,
            generation: generation,
            policy: policy)
    }

    static func indexRemote(
        manifestPath: String,
        storePath: String,
        generation: Int
    ) throws -> FaceIndexCommandOutput {
        let manifest = try requireManifest(manifestPath)
        let configuration = try BuffaloLRemoteConfiguration.load()
        guard configuration.dimension == manifest.profile.dimension else {
            throw BuffaloLClientError(kind: .dimensionMismatch)
        }
        let client = BuffaloLClient(configuration: configuration)
        _ = try client.health()
        return try index(
            manifest: manifest,
            embedder: client,
            storePath: storePath,
            generation: generation,
            policy: FaceBenchmarkFaceSelectionPolicy())
    }

    private static func index(
        manifest: FaceBenchmarkManifest,
        embedder: FaceBenchmarkEmbedder,
        storePath: String,
        generation: Int,
        policy: FaceBenchmarkFaceSelectionPolicy
    ) throws -> FaceIndexCommandOutput {
        let stats = try FaceBenchmarkRunner.index(
            manifest: manifest,
            storeURL: URL(fileURLWithPath: storePath),
            generation: generation,
            embedder: embedder,
            preprocessor: VisionFaceBatchPreprocessor(policy: policy),
            policy: policy,
            imageLoader: .fileSystem)
        return FaceIndexCommandOutput(
            stats: stats,
            policy: FaceBenchmarkPolicyOutput(
                minimumFaceSidePixels: policy.minimumFaceSidePixels,
                minimumConfidence: policy.minimumConfidence,
                maximumFacesPerAsset: policy.maximumFacesPerAsset),
            profileFingerprint: manifest.profile.fingerprint)
    }

    static func queryLocal(
        manifestPath: String,
        modelPath: String,
        storePath: String,
        resultsPath: String,
        limit: Int
    ) throws -> FaceQueryCommandOutput {
        let manifest = try requireManifest(manifestPath)
        let index = try loadIndex(storePath)
        let embedder = try FaceCoreMLEmbedder(
            modelPath: modelPath,
            dimension: manifest.profile.dimension)
        return try query(
            manifest: manifest,
            index: index,
            embedder: embedder,
            resultsPath: resultsPath,
            limit: limit)
    }

    static func queryRemote(
        manifestPath: String,
        storePath: String,
        resultsPath: String,
        limit: Int
    ) throws -> FaceQueryCommandOutput {
        let manifest = try requireManifest(manifestPath)
        let index = try loadIndex(storePath)
        let configuration = try BuffaloLRemoteConfiguration.load()
        guard configuration.dimension == manifest.profile.dimension else {
            throw BuffaloLClientError(kind: .dimensionMismatch)
        }
        let client = BuffaloLClient(configuration: configuration)
        _ = try client.health()
        return try query(
            manifest: manifest,
            index: index,
            embedder: client,
            resultsPath: resultsPath,
            limit: limit)
    }

    private static func query(
        manifest: FaceBenchmarkManifest,
        index: FaceBenchmarkIndex,
        embedder: FaceBenchmarkEmbedder,
        resultsPath: String,
        limit: Int
    ) throws -> FaceQueryCommandOutput {
        let run = try FaceBenchmarkRunner.query(
            manifest: manifest,
            index: index,
            generation: index.generation,
            embedder: embedder,
            preprocessor: VisionFaceBatchPreprocessor(),
            policy: FaceBenchmarkFaceSelectionPolicy(),
            limit: limit,
            threshold: nil,
            imageLoader: .fileSystem,
            queryPreprocessor: VisionFaceBatchPreprocessor())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(run.results)
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: resultsPath).deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: resultsPath), options: .atomic)
            let diagnostics = try encoder.encode(run.diagnostics)
            try diagnostics.write(
                to: URL(fileURLWithPath: resultsPath + ".diagnostics.json"),
                options: .atomic)
        } catch {
            throw FaceBenchmarkCLIError.writeFailed
        }
        let summary = try FaceBenchmarkEvaluator.evaluate(
            manifest: manifest,
            results: run.results)
        let failureCounts = Dictionary(
            grouping: run.diagnostics.compactMap(\.failureReason),
            by: { $0 })
            .mapValues { $0.count }
        return FaceQueryCommandOutput(
            queryCount: run.results.count,
            knownQueryCount: summary.overall.queryCount,
            unknownQueryCount: summary.unknownQueryCount,
            failureReasonCounts: failureCounts,
            summary: summary)
    }

    static func report(
        manifestPath: String,
        resultsPath: String,
        videoTruthPath: String?,
        threshold: Double,
        thresholds: [Double]
    ) throws -> FaceBenchmarkReport {
        let manifest = try requireManifest(manifestPath)
        let results: [FaceBenchmarkQueryResult] = try decodeFile(resultsPath)
        let truth: FaceBenchmarkVideoTruthManifest?
        if let videoTruthPath {
            truth = try decodeFile(videoTruthPath)
        } else {
            truth = nil
        }
        return try FaceBenchmarkReportBuilder.build(
            manifest: manifest,
            results: results,
            thresholds: thresholds,
            selectedThreshold: threshold,
            videoTruth: truth)
    }

    static func capacity(
        assets: Int,
        facesPerAsset: Int,
        dimension: Int,
        queries: Int
    ) throws -> FaceBenchmarkCapacityResult {
        try FaceBenchmarkCapacityRunner.run(
            assetCount: assets,
            facesPerAsset: facesPerAsset,
            dimension: dimension,
            queryCount: queries)
    }

    static func sampleVideo(
        videoPath: String,
        outputDirectory: String,
        intervalMs: Int,
        maxFrames: Int,
        maxSide: Int?,
        format: FaceBenchmarkFrameFormat
    ) throws -> FaceVideoSampleCommandOutput {
        let frames = try FaceBenchmarkVideoFrameExtractor.extract(
            videoURL: URL(fileURLWithPath: videoPath),
            outputDirectory: URL(fileURLWithPath: outputDirectory),
            policy: FaceBenchmarkVideoSamplingPolicy(
                intervalMs: intervalMs,
                maxFrames: maxFrames),
            maxSide: maxSide,
            format: format)
        return FaceVideoSampleCommandOutput(frameCount: frames.count, frames: frames)
    }

    static func requireManifest(_ path: String) throws -> FaceBenchmarkManifest {
        guard let manifest = try loadManifest(at: path) else {
            throw FaceBenchmarkCLIError.usage
        }
        return manifest
    }

    static func loadIndex(_ path: String) throws -> FaceBenchmarkIndex {
        do {
            return try FaceBenchmarkIndex.load(from: URL(fileURLWithPath: path))
        } catch {
            throw FaceBenchmarkCLIError.readFailed
        }
    }

    static func decodeFile<T: Decodable>(_ path: String) throws -> T {
        do {
            return try JSONDecoder().decode(
                T.self,
                from: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            throw FaceBenchmarkCLIError.readFailed
        }
    }

    static func option(_ name: String, in arguments: [String]) throws -> String? {
        guard let index = arguments.firstIndex(of: name) else { return nil }
        guard index + 1 < arguments.count else {
            throw FaceBenchmarkCLIError.invalidOption(name)
        }
        return arguments[index + 1]
    }

    static func positiveIntOption(
        _ name: String,
        in arguments: [String],
        default fallback: Int
    ) throws -> Int {
        guard let raw = try option(name, in: arguments) else { return fallback }
        guard let value = Int(raw), value > 0 else {
            throw FaceBenchmarkCLIError.invalidOption(name)
        }
        return value
    }

    static func optionalPositiveIntOption(
        _ name: String,
        in arguments: [String]
    ) throws -> Int? {
        guard let raw = try option(name, in: arguments) else { return nil }
        guard let value = Int(raw), value > 0 else {
            throw FaceBenchmarkCLIError.invalidOption(name)
        }
        return value
    }

    static func thresholdOption(
        _ name: String,
        in arguments: [String],
        default fallback: Double
    ) throws -> Double {
        guard let raw = try option(name, in: arguments) else { return fallback }
        guard let value = Double(raw), value.isFinite, (0...1).contains(value) else {
            throw FaceBenchmarkCLIError.invalidOption(name)
        }
        return value
    }

    static func thresholdsOption(
        _ name: String,
        in arguments: [String],
        default fallback: [Double]
    ) throws -> [Double] {
        guard let raw = try option(name, in: arguments) else { return fallback }
        let values = raw.split(separator: ",").compactMap { Double($0) }
        guard !values.isEmpty,
              values.allSatisfy({ $0.isFinite && (0...1).contains($0) })
        else {
            throw FaceBenchmarkCLIError.invalidOption(name)
        }
        return values
    }
}

extension BuffaloLClient: FaceBenchmarkEmbedder {}
