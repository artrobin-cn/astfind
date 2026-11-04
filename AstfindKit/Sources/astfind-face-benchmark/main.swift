import Foundation
import FaceBenchmarkCore

struct FaceBenchmarkValidationOutput: Encodable {
    let assetCount: Int
    let knownQueryCount: Int
    let unknownQueryCount: Int
    let valid: Bool
}

func writeError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func writeJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let data = try encoder.encode(value)
    guard let output = String(data: data, encoding: .utf8) else {
        throw CocoaError(.fileWriteInapplicableStringEncoding)
    }
    print(output)
}

func decode<T: Decodable>(_ type: T.Type, at path: String) throws -> T {
    do {
        return try JSONDecoder().decode(
            type,
            from: Data(contentsOf: URL(fileURLWithPath: path)))
    } catch {
        throw FaceBenchmarkCLIError.readFailed
    }
}

func loadManifest(at path: String) throws -> FaceBenchmarkManifest? {
    let manifest = try decode(FaceBenchmarkManifest.self, at: path)
    let issues = manifest.validationIssues()
    guard issues.isEmpty else {
        issues.forEach(writeError)
        return nil
    }
    return manifest
}

func evaluationMessage(_ error: FaceBenchmarkEvaluationError) -> String {
    switch error {
    case .invalidManifest(let issues): return issues.joined(separator: "\n")
    case .duplicateResult(let id): return "duplicate result id \(id)"
    case .missingResult(let id): return "missing result id \(id)"
    case .unexpectedResult(let id): return "unexpected result id \(id)"
    case .unknownHitAsset(let id): return "unknown hit asset id \(id)"
    }
}

let usage = """
usage: astfind-face-benchmark <command>
  validate <manifest.json>
  evaluate <manifest.json> <results.json>
  align <input-image> <output.png>
  embed <compiled-model> <aligned.png> [reference.json]
  remote-health
  index-local <manifest> <model.mlmodelc> <store.json> [--generation N]
  index-remote <manifest> <store.json> [--generation N]
  query-local <manifest> <model.mlmodelc> <store.json> <results.json> [--limit N]
  query-remote <manifest> <store.json> <results.json> [--limit N]
  report <manifest> <results.json> [--video-truth truth.json] [--threshold 0.5]
  capacity [--assets N] [--faces-per-asset N] [--dimension N] [--queries N]
  sample-video <video> <output-dir> [--interval-ms N] [--max-frames N] [--max-side N] [--format png|jpeg]
  extract-faces <source-dir> <model.mlmodelc> <output-dir> [--max-images N] [--min-face-side N] [--min-confidence 0.3]
"""

do {
    let arguments = CommandLine.arguments
    guard arguments.count >= 2 else {
        writeError(usage)
        exit(1)
    }
    switch arguments[1] {
    case "validate" where arguments.count == 3:
        guard let manifest = try loadManifest(at: arguments[2]) else { exit(1) }
        try writeJSON(FaceBenchmarkValidationOutput(
            assetCount: manifest.assets.count,
            knownQueryCount: manifest.queries.filter { $0.personID != nil }.count,
            unknownQueryCount: manifest.queries.filter { $0.personID == nil }.count,
            valid: true))
    case "evaluate" where arguments.count == 4:
        guard let manifest = try loadManifest(at: arguments[2]) else { exit(1) }
        let results = try decode([FaceBenchmarkQueryResult].self, at: arguments[3])
        do {
            try writeJSON(FaceBenchmarkEvaluator.evaluate(manifest: manifest, results: results))
        } catch let error as FaceBenchmarkEvaluationError {
            writeError(evaluationMessage(error))
            exit(1)
        }
    case "align" where arguments.count == 4:
        try writeJSON(FaceRuntimeCommands.align(input: arguments[2], output: arguments[3]))
    case "embed" where arguments.count == 4 || arguments.count == 5:
        try writeJSON(FaceRuntimeCommands.embed(
            modelPath: arguments[2],
            imagePath: arguments[3],
            referencePath: arguments.count == 5 ? arguments[4] : nil))
    case "remote-health" where arguments.count == 2:
        try writeJSON(try FaceBenchmarkCommands.remoteHealth())
    case "index-local" where arguments.count >= 5:
        let generation = try FaceBenchmarkCommands.positiveIntOption(
            "--generation", in: arguments, default: 1)
        try writeJSON(try FaceBenchmarkCommands.indexLocal(
            manifestPath: arguments[2],
            modelPath: arguments[3],
            storePath: arguments[4],
            generation: generation))
    case "index-remote" where arguments.count >= 4:
        let generation = try FaceBenchmarkCommands.positiveIntOption(
            "--generation", in: arguments, default: 1)
        try writeJSON(try FaceBenchmarkCommands.indexRemote(
            manifestPath: arguments[2],
            storePath: arguments[3],
            generation: generation))
    case "query-local" where arguments.count >= 6:
        let limit = try FaceBenchmarkCommands.positiveIntOption(
            "--limit", in: arguments, default: 20)
        try writeJSON(try FaceBenchmarkCommands.queryLocal(
            manifestPath: arguments[2],
            modelPath: arguments[3],
            storePath: arguments[4],
            resultsPath: arguments[5],
            limit: limit))
    case "query-remote" where arguments.count >= 5:
        let limit = try FaceBenchmarkCommands.positiveIntOption(
            "--limit", in: arguments, default: 20)
        try writeJSON(try FaceBenchmarkCommands.queryRemote(
            manifestPath: arguments[2],
            storePath: arguments[3],
            resultsPath: arguments[4],
            limit: limit))
    case "report" where arguments.count >= 4:
        let threshold = try FaceBenchmarkCommands.thresholdOption(
            "--threshold", in: arguments, default: 0.5)
        let thresholds = try FaceBenchmarkCommands.thresholdsOption(
            "--thresholds",
            in: arguments,
            default: [0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8])
        let truth = try FaceBenchmarkCommands.option("--video-truth", in: arguments)
        try writeJSON(try FaceBenchmarkCommands.report(
            manifestPath: arguments[2],
            resultsPath: arguments[3],
            videoTruthPath: truth,
            threshold: threshold,
            thresholds: thresholds))
    case "capacity" where arguments.count >= 2:
        let assets = try FaceBenchmarkCommands.positiveIntOption(
            "--assets", in: arguments, default: 5_000)
        let faces = try FaceBenchmarkCommands.positiveIntOption(
            "--faces-per-asset", in: arguments, default: 2)
        let dimension = try FaceBenchmarkCommands.positiveIntOption(
            "--dimension", in: arguments, default: 512)
        let queries = try FaceBenchmarkCommands.positiveIntOption(
            "--queries", in: arguments, default: 50)
        try writeJSON(try FaceBenchmarkCommands.capacity(
            assets: assets,
            facesPerAsset: faces,
            dimension: dimension,
            queries: queries))
    case "sample-video" where arguments.count >= 4:
        let interval = try FaceBenchmarkCommands.positiveIntOption(
            "--interval-ms", in: arguments, default: 10_000)
        let maxFrames = try FaceBenchmarkCommands.positiveIntOption(
            "--max-frames", in: arguments, default: 60)
        let maxSide = try FaceBenchmarkCommands.optionalPositiveIntOption(
            "--max-side", in: arguments)
        let rawFormat = try FaceBenchmarkCommands.option("--format", in: arguments) ?? "png"
        guard let format = FaceBenchmarkFrameFormat(rawValue: rawFormat) else {
            throw FaceBenchmarkCLIError.invalidOption("--format")
        }
        try writeJSON(try FaceBenchmarkCommands.sampleVideo(
            videoPath: arguments[2],
            outputDirectory: arguments[3],
            intervalMs: interval,
            maxFrames: maxFrames,
            maxSide: maxSide,
            format: format))
    case "extract-faces" where arguments.count >= 5:
        let maxImages = try FaceBenchmarkCommands.optionalPositiveIntOption(
            "--max-images", in: arguments)
        let minFaceSide = try FaceBenchmarkCommands.positiveIntOption(
            "--min-face-side", in: arguments, default: 40)
        let minConfidence = try FaceBenchmarkCommands.thresholdOption(
            "--min-confidence", in: arguments, default: 0.3)
        try writeJSON(try FaceExtractionCommand.run(
            sourceDirectory: arguments[2],
            modelPath: arguments[3],
            outputDirectory: arguments[4],
            maxImages: maxImages,
            minFaceSide: minFaceSide,
            minConfidence: Float(minConfidence)))
    default:
        writeError(usage)
        exit(1)
    }
} catch {
    writeError(String(describing: error))
    exit(1)
}
