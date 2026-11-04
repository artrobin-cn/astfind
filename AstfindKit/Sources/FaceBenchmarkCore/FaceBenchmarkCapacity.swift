import AstfindFaceCore
import Foundation

public struct FaceBenchmarkCapacityResult: Codable, Equatable, Sendable {
    public let dataSource: String
    public let assetCount: Int
    public let faceCount: Int
    public let dimension: Int
    public let buildElapsedMs: Double
    public let storageBytes: Int
    public let vectorPayloadBytes: Int
    public let peakResidentBytes: UInt64
    public let queryP50Ms: Double
    public let queryP95Ms: Double

    public init(
        dataSource: String,
        assetCount: Int,
        faceCount: Int,
        dimension: Int,
        buildElapsedMs: Double,
        storageBytes: Int,
        vectorPayloadBytes: Int,
        peakResidentBytes: UInt64,
        queryP50Ms: Double,
        queryP95Ms: Double
    ) {
        self.dataSource = dataSource
        self.assetCount = assetCount
        self.faceCount = faceCount
        self.dimension = dimension
        self.buildElapsedMs = buildElapsedMs
        self.storageBytes = storageBytes
        self.vectorPayloadBytes = vectorPayloadBytes
        self.peakResidentBytes = peakResidentBytes
        self.queryP50Ms = queryP50Ms
        self.queryP95Ms = queryP95Ms
    }
}

public enum FaceBenchmarkCapacityError: Error, Equatable {
    case invalidInput
}

public enum FaceBenchmarkCapacityRunner {
    private struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }
    }

    public static func run(
        assetCount: Int,
        facesPerAsset: Int,
        dimension: Int,
        queryCount: Int
    ) throws -> FaceBenchmarkCapacityResult {
        guard assetCount > 0, facesPerAsset > 0, dimension > 0, queryCount > 0 else {
            throw FaceBenchmarkCapacityError.invalidInput
        }
        let profile = FaceBenchmarkProfile(
            detector: "synthetic",
            alignment: "synthetic",
            preprocessing: "synthetic",
            model: "synthetic-vectors",
            dimension: dimension,
            normalization: "l2",
            quantization: "float32")
        var rng = SplitMix64(state: 0xA57F_1D3E_5C7B_9D21)
        func vector() -> [Float] {
            var values: [Float] = []
            values.reserveCapacity(dimension)
            for _ in 0..<dimension {
                let unit = Double(rng.next() >> 11) / Double(UInt64(1) << 53)
                values.append(Float(unit * 2 - 1))
            }
            return (try? FaceEmbeddingValidator.normalized(values, dimension: dimension)) ?? []
        }

        let started = Date()
        var index = FaceBenchmarkIndex(profile: profile, generation: 1)
        var records: [FaceBenchmarkIndexRecord] = []
        records.reserveCapacity(assetCount * facesPerAsset)
        for asset in 0..<assetCount {
            for face in 0..<facesPerAsset {
                records.append(FaceBenchmarkIndexRecord(
                    faceID: "asset-\(asset)#\(face)",
                    assetID: "asset-\(asset)",
                    vector: vector()))
            }
        }
        try index.append(contentsOf: records)
        let peakResidentBytes = FaceBenchmarkResourceProbe.peakResidentBytes()
        let storageBytes = try index.encodedData().count
        let buildElapsedMs = Date().timeIntervalSince(started) * 1_000

        var latencies: [Double] = []
        latencies.reserveCapacity(queryCount)
        for _ in 0..<queryCount {
            let query = vector()
            let queryStarted = Date()
            _ = try index.search(query: query, limit: 10, generation: 1)
            latencies.append(Date().timeIntervalSince(queryStarted) * 1_000)
        }
        latencies.sort()
        return FaceBenchmarkCapacityResult(
            dataSource: "synthetic_vectors",
            assetCount: assetCount,
            faceCount: index.vectorCount,
            dimension: dimension,
            buildElapsedMs: buildElapsedMs,
            storageBytes: storageBytes,
            vectorPayloadBytes: index.vectorCount * dimension * MemoryLayout<Float>.size,
            peakResidentBytes: peakResidentBytes,
            queryP50Ms: percentile(0.50, sorted: latencies),
            queryP95Ms: percentile(0.95, sorted: latencies))
    }

    private static func percentile(_ percentile: Double, sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((percentile * Double(sorted.count)).rounded(.up))
        return sorted[max(0, min(sorted.count - 1, rank - 1))]
    }
}
