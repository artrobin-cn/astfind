import Foundation

public struct FaceBenchmarkThresholdPoint: Codable, Equatable, Sendable {
    public let threshold: Double
    public let knownQueryCount: Int
    public let rank1: Double
    public let recallAt10: Double
    public let precisionAt10: Double
    public let unknownQueryCount: Int
    public let unknownReturnRate: Double

    public init(
        threshold: Double,
        knownQueryCount: Int,
        rank1: Double,
        recallAt10: Double,
        precisionAt10: Double,
        unknownQueryCount: Int,
        unknownReturnRate: Double
    ) {
        self.threshold = threshold
        self.knownQueryCount = knownQueryCount
        self.rank1 = rank1
        self.recallAt10 = recallAt10
        self.precisionAt10 = precisionAt10
        self.unknownQueryCount = unknownQueryCount
        self.unknownReturnRate = unknownReturnRate
    }
}

public enum FaceBenchmarkThresholdAnalyzer {
    public static func sweep(
        manifest: FaceBenchmarkManifest,
        results: [FaceBenchmarkQueryResult],
        thresholds: [Double]
    ) throws -> [FaceBenchmarkThresholdPoint] {
        try thresholds.sorted().map { threshold in
            let filtered = results.map { result in
                FaceBenchmarkQueryResult(
                    queryID: result.queryID,
                    hits: result.hits.filter { $0.score >= threshold },
                    elapsedMs: result.elapsedMs)
            }
            let summary = try FaceBenchmarkEvaluator.evaluate(
                manifest: manifest,
                results: filtered)
            return FaceBenchmarkThresholdPoint(
                threshold: threshold,
                knownQueryCount: summary.overall.queryCount,
                rank1: summary.overall.rank1,
                recallAt10: summary.overall.recallAt10,
                precisionAt10: summary.overall.precisionAt10,
                unknownQueryCount: summary.unknownQueryCount,
                unknownReturnRate: summary.unknownReturnRate)
        }
    }
}

public struct FaceBenchmarkReport: Codable, Equatable, Sendable {
    public let profile: FaceBenchmarkProfile
    public let assetCount: Int
    public let knownQueryCount: Int
    public let unknownQueryCount: Int
    public let selectedThreshold: Double
    public let selected: FaceBenchmarkThresholdPoint
    public let thresholdCurve: [FaceBenchmarkThresholdPoint]
    public let byCondition: [String: FaceBenchmarkAggregate]
    public let latencyP50Ms: Double
    public let latencyP95Ms: Double
    public let videoRecall: FaceBenchmarkVideoRecall?

    public init(
        profile: FaceBenchmarkProfile,
        assetCount: Int,
        knownQueryCount: Int,
        unknownQueryCount: Int,
        selectedThreshold: Double,
        selected: FaceBenchmarkThresholdPoint,
        thresholdCurve: [FaceBenchmarkThresholdPoint],
        byCondition: [String: FaceBenchmarkAggregate],
        latencyP50Ms: Double,
        latencyP95Ms: Double,
        videoRecall: FaceBenchmarkVideoRecall?
    ) {
        self.profile = profile
        self.assetCount = assetCount
        self.knownQueryCount = knownQueryCount
        self.unknownQueryCount = unknownQueryCount
        self.selectedThreshold = selectedThreshold
        self.selected = selected
        self.thresholdCurve = thresholdCurve
        self.byCondition = byCondition
        self.latencyP50Ms = latencyP50Ms
        self.latencyP95Ms = latencyP95Ms
        self.videoRecall = videoRecall
    }
}

public enum FaceBenchmarkReportBuilder {
    public static func build(
        manifest: FaceBenchmarkManifest,
        results: [FaceBenchmarkQueryResult],
        thresholds: [Double],
        selectedThreshold: Double,
        videoTruth: FaceBenchmarkVideoTruthManifest? = nil
    ) throws -> FaceBenchmarkReport {
        let allThresholds = Array(Set(thresholds + [selectedThreshold])).sorted()
        let sweep = try FaceBenchmarkThresholdAnalyzer.sweep(
            manifest: manifest,
            results: results,
            thresholds: allThresholds)
        guard let selected = sweep.first(where: { $0.threshold == selectedThreshold }) else {
            throw FaceBenchmarkEvaluationError.invalidManifest(["missing selected threshold"])
        }
        let filtered = results.map { result in
            FaceBenchmarkQueryResult(
                queryID: result.queryID,
                hits: result.hits.filter { $0.score >= selectedThreshold },
                elapsedMs: result.elapsedMs)
        }
        let summary = try FaceBenchmarkEvaluator.evaluate(
            manifest: manifest,
            results: filtered)
        let videoRecall = try videoTruth.map {
            try FaceBenchmarkVideoRecallEvaluator.evaluate(
                manifest: manifest,
                truth: $0,
                results: filtered)
        }
        return FaceBenchmarkReport(
            profile: manifest.profile,
            assetCount: manifest.assets.count,
            knownQueryCount: summary.overall.queryCount,
            unknownQueryCount: summary.unknownQueryCount,
            selectedThreshold: selectedThreshold,
            selected: selected,
            thresholdCurve: sweep,
            byCondition: summary.byCondition,
            latencyP50Ms: summary.latencyP50Ms,
            latencyP95Ms: summary.latencyP95Ms,
            videoRecall: videoRecall)
    }
}
