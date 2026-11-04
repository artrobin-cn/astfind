import AVFoundation
import CoreGraphics
import Foundation

public struct FaceBenchmarkVideoSamplingPolicy: Equatable, Sendable {
    public let intervalMs: Int
    public let maxFrames: Int
    public let startMs: Int

    public init(intervalMs: Int = 10_000, maxFrames: Int = 60, startMs: Int = 0) {
        self.intervalMs = intervalMs
        self.maxFrames = maxFrames
        self.startMs = startMs
    }
}

public enum FaceBenchmarkVideoSamplingError: Error, Equatable {
    case invalidDuration
    case invalidPolicy
}

public enum FaceBenchmarkVideoSampling {
    public static func frameTimes(
        durationMs: Int,
        policy: FaceBenchmarkVideoSamplingPolicy
    ) throws -> [Int] {
        guard durationMs > 0 else { throw FaceBenchmarkVideoSamplingError.invalidDuration }
        guard policy.intervalMs > 0,
              policy.maxFrames > 0,
              policy.startMs >= 0
        else {
            throw FaceBenchmarkVideoSamplingError.invalidPolicy
        }
        var times: [Int] = []
        var index = 0
        while index < policy.maxFrames {
            let time = policy.startMs + index * policy.intervalMs
            guard time < durationMs else { break }
            times.append(time)
            index += 1
        }
        return times
    }
}

public enum FaceBenchmarkFrameFormat: String, Sendable {
    case png
    case jpeg
}

public struct FaceBenchmarkExtractedFrame: Codable, Equatable, Sendable {
    public let fileName: String
    public let startMs: Int

    public init(fileName: String, startMs: Int) {
        self.fileName = fileName
        self.startMs = startMs
    }
}

public enum FaceBenchmarkVideoFrameExtractionError: Error, Equatable {
    case durationUnavailable
    case outputDirectoryFailed
    case frameExtractionFailed(Int)
    case frameWriteFailed(Int)
}

public enum FaceBenchmarkVideoFrameExtractor {
    public static func extract(
        videoURL: URL,
        outputDirectory: URL,
        policy: FaceBenchmarkVideoSamplingPolicy,
        fileNamePrefix: String = "frame",
        maxSide: Int? = nil,
        format: FaceBenchmarkFrameFormat = .png
    ) throws -> [FaceBenchmarkExtractedFrame] {
        let asset = AVURLAsset(url: videoURL)
        let seconds = CMTimeGetSeconds(asset.duration)
        guard seconds.isFinite, seconds > 0 else {
            throw FaceBenchmarkVideoFrameExtractionError.durationUnavailable
        }
        let durationMs = Int((seconds * 1_000).rounded(.down))
        let times = try FaceBenchmarkVideoSampling.frameTimes(
            durationMs: durationMs,
            policy: policy)
        do {
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true)
        } catch {
            throw FaceBenchmarkVideoFrameExtractionError.outputDirectoryFailed
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        var frames: [FaceBenchmarkExtractedFrame] = []
        for (index, startMs) in times.enumerated() {
            let time = CMTime(value: CMTimeValue(startMs), timescale: 1_000)
            let image: CGImage
            do {
                image = try generator.copyCGImage(at: time, actualTime: nil)
            } catch {
                throw FaceBenchmarkVideoFrameExtractionError.frameExtractionFailed(index)
            }
            let scaled: CGImage
            do {
                scaled = try maxSide.map {
                    try FaceBenchmarkImageScaler.scaled(image, maxSide: $0)
                } ?? image
            } catch {
                throw FaceBenchmarkVideoFrameExtractionError.frameWriteFailed(index)
            }
            let suffix = format == .png ? "png" : "jpg"
            let fileName = String(format: "%@-%06d.%@", fileNamePrefix, index, suffix)
            do {
                let destination = outputDirectory.appendingPathComponent(fileName)
                switch format {
                case .png:
                    try FaceBenchmarkImageIO.writePNG(scaled, to: destination)
                case .jpeg:
                    try FaceBenchmarkImageIO.writeJPEG(scaled, to: destination)
                }
            } catch {
                throw FaceBenchmarkVideoFrameExtractionError.frameWriteFailed(index)
            }
            frames.append(FaceBenchmarkExtractedFrame(fileName: fileName, startMs: startMs))
        }
        return frames
    }
}

public struct FaceBenchmarkVideoAppearance: Codable, Equatable, Sendable {
    public var personID: String
    public var startMs: Int
    public var endMs: Int

    enum CodingKeys: String, CodingKey {
        case personID = "person_id"
        case startMs = "start_ms"
        case endMs = "end_ms"
    }

    public init(personID: String, startMs: Int, endMs: Int) {
        self.personID = personID
        self.startMs = startMs
        self.endMs = endMs
    }
}

public struct FaceBenchmarkVideoTruth: Codable, Equatable, Sendable {
    public var videoID: String
    public var durationMs: Int
    public var appearances: [FaceBenchmarkVideoAppearance]

    enum CodingKeys: String, CodingKey {
        case videoID = "video_id"
        case durationMs = "duration_ms"
        case appearances
    }

    public init(
        videoID: String,
        durationMs: Int,
        appearances: [FaceBenchmarkVideoAppearance]
    ) {
        self.videoID = videoID
        self.durationMs = durationMs
        self.appearances = appearances
    }
}

public struct FaceBenchmarkVideoTruthManifest: Codable, Equatable, Sendable {
    public var videos: [FaceBenchmarkVideoTruth]

    public init(videos: [FaceBenchmarkVideoTruth]) {
        self.videos = videos
    }

    public func validationIssues() -> [String] {
        var issues: [String] = []
        if videos.isEmpty { issues.append("video truth must contain videos") }
        var seen = Set<String>()
        for video in videos where !seen.insert(video.videoID).inserted {
            issues.append("duplicate video id \(video.videoID)")
        }
        for video in videos {
            if video.durationMs <= 0 {
                issues.append("video \(video.videoID) duration must be positive")
            }
            for (index, appearance) in video.appearances.enumerated() {
                if appearance.personID.isEmpty {
                    issues.append("video \(video.videoID) appearance \(index) person must be nonempty")
                }
                if appearance.startMs < 0 {
                    issues.append("video \(video.videoID) appearance \(index) start must be nonnegative")
                }
                if appearance.endMs <= appearance.startMs {
                    issues.append("video \(video.videoID) appearance \(index) must end after start")
                }
                if appearance.endMs > video.durationMs {
                    issues.append("video \(video.videoID) appearance \(index) must fit within duration")
                }
            }
        }
        return issues
    }
}

public struct FaceBenchmarkVideoRecall: Codable, Equatable, Sendable {
    public let sampledFramePairCount: Int
    public let sampledFrameHits: Int
    public let sampledFrameConditionalRecall: Double
    public let actualShotCount: Int
    public let actualShotHits: Int
    public let actualShotRecall: Double

    public init(
        sampledFramePairCount: Int,
        sampledFrameHits: Int,
        sampledFrameConditionalRecall: Double,
        actualShotCount: Int,
        actualShotHits: Int,
        actualShotRecall: Double
    ) {
        self.sampledFramePairCount = sampledFramePairCount
        self.sampledFrameHits = sampledFrameHits
        self.sampledFrameConditionalRecall = sampledFrameConditionalRecall
        self.actualShotCount = actualShotCount
        self.actualShotHits = actualShotHits
        self.actualShotRecall = actualShotRecall
    }
}

public enum FaceBenchmarkVideoRecallError: Error, Equatable {
    case invalidManifest([String])
    case invalidTruth([String])
    case duplicateResult(String)
    case missingResult(String)
    case unexpectedResult(String)
    case unknownHitAsset(String)
}

public enum FaceBenchmarkVideoRecallEvaluator {
    public static func evaluate(
        manifest: FaceBenchmarkManifest,
        truth: FaceBenchmarkVideoTruthManifest,
        results: [FaceBenchmarkQueryResult]
    ) throws -> FaceBenchmarkVideoRecall {
        let manifestIssues = manifest.validationIssues()
        guard manifestIssues.isEmpty else {
            throw FaceBenchmarkVideoRecallError.invalidManifest(manifestIssues)
        }
        let truthIssues = truth.validationIssues()
        guard truthIssues.isEmpty else {
            throw FaceBenchmarkVideoRecallError.invalidTruth(truthIssues)
        }

        let queryIDs = Set(manifest.queries.map(\.queryID))
        var resultsByID: [String: FaceBenchmarkQueryResult] = [:]
        for result in results {
            guard queryIDs.contains(result.queryID) else {
                throw FaceBenchmarkVideoRecallError.unexpectedResult(result.queryID)
            }
            guard resultsByID[result.queryID] == nil else {
                throw FaceBenchmarkVideoRecallError.duplicateResult(result.queryID)
            }
            resultsByID[result.queryID] = result
        }
        for query in manifest.queries where resultsByID[query.queryID] == nil {
            throw FaceBenchmarkVideoRecallError.missingResult(query.queryID)
        }

        let assetsByID = Dictionary(uniqueKeysWithValues: manifest.assets.map { ($0.assetID, $0) })
        for result in results {
            for hit in result.hits where assetsByID[hit.assetID] == nil {
                throw FaceBenchmarkVideoRecallError.unknownHitAsset(hit.assetID)
            }
        }

        var sampledPairs = 0
        var sampledHits = 0
        var actualShots = 0
        var actualHits = 0

        for query in manifest.queries {
            guard let personID = query.personID,
                  let result = resultsByID[query.queryID]
            else { continue }
            let hitAssetIDs = Set(result.hits.map(\.assetID))
            let relevantHits = hitAssetIDs.compactMap { assetsByID[$0] }.filter {
                $0.personIDs.contains(personID) && $0.videoID != nil
            }
            let truthVideosForPerson = Set(truth.videos.compactMap { video -> String? in
                guard video.appearances.contains(where: { $0.personID == personID }) else {
                    return nil
                }
                return video.videoID
            })
            let sampledVideos = Set(manifest.assets.compactMap { asset -> String? in
                guard asset.personIDs.contains(personID) else { return nil }
                return asset.videoID
            }).intersection(truthVideosForPerson)

            for videoID in sampledVideos {
                sampledPairs += 1
                if relevantHits.contains(where: { $0.videoID == videoID }) {
                    sampledHits += 1
                }
            }

            for video in truth.videos {
                for appearance in video.appearances where appearance.personID == personID {
                    actualShots += 1
                    let covered = relevantHits.contains {
                        guard $0.videoID == video.videoID, let startMs = $0.startMs else {
                            return false
                        }
                        return startMs >= appearance.startMs && startMs < appearance.endMs
                    }
                    if covered { actualHits += 1 }
                }
            }
        }

        return FaceBenchmarkVideoRecall(
            sampledFramePairCount: sampledPairs,
            sampledFrameHits: sampledHits,
            sampledFrameConditionalRecall: sampledPairs == 0
                ? 0 : Double(sampledHits) / Double(sampledPairs),
            actualShotCount: actualShots,
            actualShotHits: actualHits,
            actualShotRecall: actualShots == 0
                ? 0 : Double(actualHits) / Double(actualShots))
    }
}
