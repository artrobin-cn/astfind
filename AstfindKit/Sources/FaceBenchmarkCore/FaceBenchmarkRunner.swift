import AstfindFaceCore
import CoreGraphics
import Foundation

public struct FaceBenchmarkIndexBuildStats: Codable, Equatable, Sendable {
    public let assetCount: Int
    public let indexedAssetCount: Int
    public let skippedAssetCount: Int
    public let rejectedFaceCount: Int
    public let vectorCount: Int
    public let elapsedMs: Double
    public let storageBytes: Int
    public let peakResidentBytes: UInt64

    public init(
        assetCount: Int,
        indexedAssetCount: Int,
        skippedAssetCount: Int,
        rejectedFaceCount: Int,
        vectorCount: Int,
        elapsedMs: Double,
        storageBytes: Int,
        peakResidentBytes: UInt64
    ) {
        self.assetCount = assetCount
        self.indexedAssetCount = indexedAssetCount
        self.skippedAssetCount = skippedAssetCount
        self.rejectedFaceCount = rejectedFaceCount
        self.vectorCount = vectorCount
        self.elapsedMs = elapsedMs
        self.storageBytes = storageBytes
        self.peakResidentBytes = peakResidentBytes
    }
}

public struct FaceBenchmarkQueryDiagnostic: Codable, Equatable, Sendable {
    public let queryID: String
    public let faceCount: Int
    public let selectedFaceIndex: Int
    public let preprocessMs: Double
    public let embeddingMs: Double
    public let searchMs: Double
    public let totalMs: Double
    public let hitCount: Int
    public let failureReason: String?

    enum CodingKeys: String, CodingKey {
        case queryID = "query_id"
        case faceCount = "face_count"
        case selectedFaceIndex = "selected_face_index"
        case preprocessMs = "preprocess_ms"
        case embeddingMs = "embedding_ms"
        case searchMs = "search_ms"
        case totalMs = "total_ms"
        case hitCount = "hit_count"
        case failureReason = "failure_reason"
    }

    public init(
        queryID: String,
        faceCount: Int,
        selectedFaceIndex: Int,
        preprocessMs: Double,
        embeddingMs: Double,
        searchMs: Double,
        totalMs: Double,
        hitCount: Int,
        failureReason: String?
    ) {
        self.queryID = queryID
        self.faceCount = faceCount
        self.selectedFaceIndex = selectedFaceIndex
        self.preprocessMs = preprocessMs
        self.embeddingMs = embeddingMs
        self.searchMs = searchMs
        self.totalMs = totalMs
        self.hitCount = hitCount
        self.failureReason = failureReason
    }
}

public struct FaceBenchmarkQueryRun: Codable, Equatable, Sendable {
    public let results: [FaceBenchmarkQueryResult]
    public let diagnostics: [FaceBenchmarkQueryDiagnostic]

    public init(
        results: [FaceBenchmarkQueryResult],
        diagnostics: [FaceBenchmarkQueryDiagnostic]
    ) {
        self.results = results
        self.diagnostics = diagnostics
    }
}

public enum FaceBenchmarkRunnerError: Error, Equatable {
    case invalidManifest([String])
    case invalidGeneration(Int)
    case dimensionMismatch(expected: Int, actual: Int)
    case vectorCountMismatch(expected: Int, actual: Int)
    case invalidEmbedding(String)
    case selectedFaceOutOfRange(queryID: String, faceCount: Int)
    case generationMismatch(expected: Int, actual: Int)
    case profileMismatch
    case assetReadFailed(String)
    case queryReadFailed(String)
}

public enum FaceBenchmarkRunner {
    public static func index(
        manifest: FaceBenchmarkManifest,
        storeURL: URL,
        generation: Int,
        embedder: FaceBenchmarkEmbedder,
        preprocessor: FaceBenchmarkPreprocessing,
        policy: FaceBenchmarkFaceSelectionPolicy,
        imageLoader: FaceBenchmarkImageLoader
    ) throws -> FaceBenchmarkIndexBuildStats {
        let issues = manifest.validationIssues()
        guard issues.isEmpty else {
            throw FaceBenchmarkRunnerError.invalidManifest(issues)
        }
        guard generation >= 0 else {
            throw FaceBenchmarkRunnerError.invalidGeneration(generation)
        }
        guard embedder.dimension == manifest.profile.dimension else {
            throw FaceBenchmarkRunnerError.dimensionMismatch(
                expected: manifest.profile.dimension,
                actual: embedder.dimension)
        }

        let started = Date()
        var index = FaceBenchmarkIndex(profile: manifest.profile, generation: generation)
        var indexedAssets = 0
        var skippedAssets = 0
        var rejectedFaces = 0

        for asset in manifest.assets {
            let image: CGImage
            do {
                image = try imageLoader.load(asset.path)
            } catch {
                throw FaceBenchmarkRunnerError.assetReadFailed(asset.assetID)
            }
            let processed: [FaceBenchmarkPreprocessedFace]
            do {
                processed = try preprocessor.process(image: image)
            } catch is FaceAlignmentError {
                skippedAssets += 1
                continue
            }
            let accepted = FaceBenchmarkFaceSelection.accepted(
                processed.map(\.region),
                policy: policy)
            rejectedFaces += processed.count - accepted.count
            guard !accepted.isEmpty else {
                skippedAssets += 1
                continue
            }
            let byDetectionIndex = Dictionary(
                uniqueKeysWithValues: processed.map { ($0.region.detectionIndex, $0) })
            let faces = accepted.compactMap { byDetectionIndex[$0.detectionIndex] }
            guard faces.count == accepted.count else {
                throw FaceBenchmarkRunnerError.invalidEmbedding(asset.assetID)
            }
            let vectors = try embedder.embed(images: faces.map(\.alignedImage))
            guard vectors.count == faces.count else {
                throw FaceBenchmarkRunnerError.vectorCountMismatch(
                    expected: faces.count,
                    actual: vectors.count)
            }
            var records: [FaceBenchmarkIndexRecord] = []
            for (offset, vector) in vectors.enumerated() {
                let normalized: [Float]
                do {
                    normalized = try FaceEmbeddingValidator.normalized(
                        vector,
                        dimension: manifest.profile.dimension)
                } catch {
                    throw FaceBenchmarkRunnerError.invalidEmbedding(asset.assetID)
                }
                records.append(FaceBenchmarkIndexRecord(
                    faceID: "\(asset.assetID)#\(offset)",
                    assetID: asset.assetID,
                    vector: normalized,
                    videoID: asset.videoID,
                    startMs: asset.startMs))
            }
            try index.append(contentsOf: records)
            indexedAssets += 1
        }

        try index.write(to: storeURL)
        let storageBytes = try index.encodedData().count
        return FaceBenchmarkIndexBuildStats(
            assetCount: manifest.assets.count,
            indexedAssetCount: indexedAssets,
            skippedAssetCount: skippedAssets,
            rejectedFaceCount: rejectedFaces,
            vectorCount: index.vectorCount,
            elapsedMs: Date().timeIntervalSince(started) * 1_000,
            storageBytes: storageBytes,
            peakResidentBytes: FaceBenchmarkResourceProbe.peakResidentBytes())
    }

    public static func query(
        manifest: FaceBenchmarkManifest,
        index: FaceBenchmarkIndex,
        generation: Int,
        embedder: FaceBenchmarkEmbedder,
        preprocessor: FaceBenchmarkPreprocessing,
        policy: FaceBenchmarkFaceSelectionPolicy,
        limit: Int,
        threshold: Double?,
        imageLoader: FaceBenchmarkImageLoader,
        queryPreprocessor: FaceBenchmarkQueryPreprocessing? = nil
    ) throws -> FaceBenchmarkQueryRun {
        let issues = manifest.validationIssues()
        guard issues.isEmpty else {
            throw FaceBenchmarkRunnerError.invalidManifest(issues)
        }
        guard generation == index.generation else {
            throw FaceBenchmarkRunnerError.generationMismatch(
                expected: index.generation,
                actual: generation)
        }
        guard index.profile.fingerprint == manifest.profile.fingerprint else {
            throw FaceBenchmarkRunnerError.profileMismatch
        }
        guard embedder.dimension == manifest.profile.dimension else {
            throw FaceBenchmarkRunnerError.dimensionMismatch(
                expected: manifest.profile.dimension,
                actual: embedder.dimension)
        }

        var results: [FaceBenchmarkQueryResult] = []
        var diagnostics: [FaceBenchmarkQueryDiagnostic] = []
        results.reserveCapacity(manifest.queries.count)
        diagnostics.reserveCapacity(manifest.queries.count)

        for query in manifest.queries {
            let totalStarted = Date()
            let image: CGImage
            do {
                image = try imageLoader.load(query.imagePath)
            } catch {
                throw FaceBenchmarkRunnerError.queryReadFailed(query.queryID)
            }

            if let queryPreprocessor {
                let preprocessStarted = Date()
                do {
                    let selectedFace = try queryPreprocessor.processSelected(
                        image: image,
                        selectedFaceIndex: query.selectedFaceIndex,
                        policy: policy)
                    let preprocessMs = Date().timeIntervalSince(preprocessStarted) * 1_000
                    let evaluated = try evaluate(
                        query: query,
                        alignedImage: selectedFace.alignedImage,
                        faceCount: selectedFace.faceCount,
                        preprocessMs: preprocessMs,
                        totalStarted: totalStarted,
                        embedder: embedder,
                        index: index,
                        dimension: manifest.profile.dimension,
                        limit: limit,
                        threshold: threshold,
                        generation: generation)
                    results.append(evaluated.0)
                    diagnostics.append(evaluated.1)
                    continue
                } catch let error as FaceBenchmarkFaceSelectionError {
                    switch error {
                    case .selectedFaceOutOfRange(let faceCount):
                        throw FaceBenchmarkRunnerError.selectedFaceOutOfRange(
                            queryID: query.queryID,
                            faceCount: faceCount)
                    }
                } catch let error as FaceAlignmentError {
                    let preprocessMs = Date().timeIntervalSince(preprocessStarted) * 1_000
                    let reason: String
                    switch error {
                    case .noFace: reason = "no_face"
                    case .missingLandmarks: reason = "missing_landmarks"
                    default: reason = "preprocess_failed"
                    }
                    results.append(FaceBenchmarkQueryResult(
                        queryID: query.queryID,
                        hits: [],
                        elapsedMs: Date().timeIntervalSince(totalStarted) * 1_000))
                    diagnostics.append(FaceBenchmarkQueryDiagnostic(
                        queryID: query.queryID,
                        faceCount: 0,
                        selectedFaceIndex: query.selectedFaceIndex,
                        preprocessMs: preprocessMs,
                        embeddingMs: 0,
                        searchMs: 0,
                        totalMs: Date().timeIntervalSince(totalStarted) * 1_000,
                        hitCount: 0,
                        failureReason: reason))
                    continue
                }
            }

            let preprocessStarted = Date()
            let processed: [FaceBenchmarkPreprocessedFace]
            do {
                processed = try preprocessor.process(image: image)
            } catch let error as FaceAlignmentError {
                let preprocessMs = Date().timeIntervalSince(preprocessStarted) * 1_000
                let reason: String
                switch error {
                case .noFace: reason = "no_face"
                case .missingLandmarks: reason = "missing_landmarks"
                default: reason = "preprocess_failed"
                }
                results.append(FaceBenchmarkQueryResult(
                    queryID: query.queryID,
                    hits: [],
                    elapsedMs: Date().timeIntervalSince(totalStarted) * 1_000))
                diagnostics.append(FaceBenchmarkQueryDiagnostic(
                    queryID: query.queryID,
                    faceCount: 0,
                    selectedFaceIndex: query.selectedFaceIndex,
                    preprocessMs: preprocessMs,
                    embeddingMs: 0,
                    searchMs: 0,
                    totalMs: Date().timeIntervalSince(totalStarted) * 1_000,
                    hitCount: 0,
                    failureReason: reason))
                continue
            }
            let preprocessMs = Date().timeIntervalSince(preprocessStarted) * 1_000
            let accepted = FaceBenchmarkFaceSelection.accepted(
                processed.map(\.region),
                policy: policy)
            guard !accepted.isEmpty else {
                results.append(FaceBenchmarkQueryResult(
                    queryID: query.queryID,
                    hits: [],
                    elapsedMs: Date().timeIntervalSince(totalStarted) * 1_000))
                diagnostics.append(FaceBenchmarkQueryDiagnostic(
                    queryID: query.queryID,
                    faceCount: processed.count,
                    selectedFaceIndex: query.selectedFaceIndex,
                    preprocessMs: preprocessMs,
                    embeddingMs: 0,
                    searchMs: 0,
                    totalMs: Date().timeIntervalSince(totalStarted) * 1_000,
                    hitCount: 0,
                    failureReason: "quality_rejected"))
                continue
            }
            let selected: FaceBenchmarkFaceRegion
            do {
                selected = try FaceBenchmarkFaceSelection.selected(
                    at: query.selectedFaceIndex,
                    from: processed.map(\.region),
                    policy: policy)
            } catch {
                throw FaceBenchmarkRunnerError.selectedFaceOutOfRange(
                    queryID: query.queryID,
                    faceCount: accepted.count)
            }
            guard let face = processed.first(where: {
                $0.region.detectionIndex == selected.detectionIndex
            }) else {
                throw FaceBenchmarkRunnerError.selectedFaceOutOfRange(
                    queryID: query.queryID,
                    faceCount: accepted.count)
            }

            let evaluated = try evaluate(
                query: query,
                alignedImage: face.alignedImage,
                faceCount: processed.count,
                preprocessMs: preprocessMs,
                totalStarted: totalStarted,
                embedder: embedder,
                index: index,
                dimension: manifest.profile.dimension,
                limit: limit,
                threshold: threshold,
                generation: generation)
            results.append(evaluated.0)
            diagnostics.append(evaluated.1)
        }
        return FaceBenchmarkQueryRun(results: results, diagnostics: diagnostics)
    }

    private static func evaluate(
        query: FaceBenchmarkQuery,
        alignedImage: CGImage,
        faceCount: Int,
        preprocessMs: Double,
        totalStarted: Date,
        embedder: FaceBenchmarkEmbedder,
        index: FaceBenchmarkIndex,
        dimension: Int,
        limit: Int,
        threshold: Double?,
        generation: Int
    ) throws -> (FaceBenchmarkQueryResult, FaceBenchmarkQueryDiagnostic) {
        let embeddingStarted = Date()
        let vectors = try embedder.embed(images: [alignedImage])
        guard vectors.count == 1 else {
            throw FaceBenchmarkRunnerError.vectorCountMismatch(
                expected: 1,
                actual: vectors.count)
        }
        let queryVector: [Float]
        do {
            queryVector = try FaceEmbeddingValidator.normalized(
                vectors[0],
                dimension: dimension)
        } catch {
            throw FaceBenchmarkRunnerError.invalidEmbedding(query.queryID)
        }
        let embeddingMs = Date().timeIntervalSince(embeddingStarted) * 1_000

        let searchStarted = Date()
        let indexHits = try index.search(
            query: queryVector,
            limit: limit,
            threshold: threshold,
            generation: generation)
        let searchMs = Date().timeIntervalSince(searchStarted) * 1_000
        let hits = indexHits.map {
            FaceBenchmarkHit(assetID: $0.assetID, score: $0.score)
        }
        let totalMs = Date().timeIntervalSince(totalStarted) * 1_000
        return (
            FaceBenchmarkQueryResult(
                queryID: query.queryID,
                hits: hits,
                elapsedMs: totalMs),
            FaceBenchmarkQueryDiagnostic(
                queryID: query.queryID,
                faceCount: faceCount,
                selectedFaceIndex: query.selectedFaceIndex,
                preprocessMs: preprocessMs,
                embeddingMs: embeddingMs,
                searchMs: searchMs,
                totalMs: totalMs,
                hitCount: hits.count,
                failureReason: nil))
    }
}
