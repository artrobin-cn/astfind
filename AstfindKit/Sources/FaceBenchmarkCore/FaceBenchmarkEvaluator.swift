import Foundation

public struct FaceBenchmarkAggregate: Codable, Equatable, Sendable {
    public let queryCount: Int
    public let rank1: Double
    public let recallAt10: Double
    public let precisionAt10: Double
}

public struct FaceBenchmarkSummary: Codable, Equatable, Sendable {
    public let overall: FaceBenchmarkAggregate
    public let byCondition: [String: FaceBenchmarkAggregate]
    public let unknownQueryCount: Int
    public let unknownReturnRate: Double
    public let latencyP50Ms: Double
    public let latencyP95Ms: Double
}

public enum FaceBenchmarkEvaluationError: Error, Equatable {
    case invalidManifest([String])
    case duplicateResult(String)
    case missingResult(String)
    case unexpectedResult(String)
    case unknownHitAsset(String)
}

public enum FaceBenchmarkEvaluator {
    private struct KnownEvaluation {
        let conditions: [FaceBenchmarkCondition]
        let rank1: Double
        let recalled: Double
        let relevantAt10: Int
    }

    public static func evaluate(manifest: FaceBenchmarkManifest,
                                results: [FaceBenchmarkQueryResult]) throws -> FaceBenchmarkSummary {
        let issues = manifest.validationIssues()
        guard issues.isEmpty else { throw FaceBenchmarkEvaluationError.invalidManifest(issues) }

        let queryIDs = Set(manifest.queries.map(\.queryID))
        var resultsByID: [String: FaceBenchmarkQueryResult] = [:]
        for result in results {
            guard !queryIDs.contains(result.queryID) else {
                guard resultsByID[result.queryID] == nil else {
                    throw FaceBenchmarkEvaluationError.duplicateResult(result.queryID)
                }
                resultsByID[result.queryID] = result
                continue
            }
            throw FaceBenchmarkEvaluationError.unexpectedResult(result.queryID)
        }
        for query in manifest.queries where resultsByID[query.queryID] == nil {
            throw FaceBenchmarkEvaluationError.missingResult(query.queryID)
        }

        let assetsByID = Dictionary(uniqueKeysWithValues: manifest.assets.map { ($0.assetID, $0) })
        var known: [KnownEvaluation] = []
        var unknownReturned = 0

        for query in manifest.queries {
            guard let result = resultsByID[query.queryID] else { continue }
            let hits = try deduplicatedHits(result.hits, assetsByID: assetsByID)
            guard let personID = query.personID else {
                if !hits.isEmpty { unknownReturned += 1 }
                continue
            }
            let top10 = hits.prefix(10)
            let relevant = top10.filter { assetsByID[$0.assetID]?.personIDs.contains(personID) == true }
            known.append(KnownEvaluation(
                conditions: query.conditions,
                rank1: relevant.first?.assetID == hits.first?.assetID && hits.first != nil ? 1 : 0,
                recalled: relevant.isEmpty ? 0 : 1,
                relevantAt10: relevant.count))
        }

        var conditionEvaluations: [FaceBenchmarkCondition: [KnownEvaluation]] = [:]
        for evaluation in known {
            for condition in evaluation.conditions {
                conditionEvaluations[condition, default: []].append(evaluation)
            }
        }

        let latencies = results.map(\.elapsedMs).sorted()
        let unknownCount = manifest.queries.filter { $0.personID == nil }.count
        return FaceBenchmarkSummary(
            overall: aggregate(known),
            byCondition: Dictionary(uniqueKeysWithValues: conditionEvaluations.map {
                ($0.key.rawValue, aggregate($0.value))
            }),
            unknownQueryCount: unknownCount,
            unknownReturnRate: unknownCount == 0 ? 0 : Double(unknownReturned) / Double(unknownCount),
            latencyP50Ms: percentile(0.50, sortedValues: latencies),
            latencyP95Ms: percentile(0.95, sortedValues: latencies))
    }

    private static func deduplicatedHits(
        _ hits: [FaceBenchmarkHit],
        assetsByID: [String: FaceBenchmarkAsset]
    ) throws -> [FaceBenchmarkHit] {
        for hit in hits where assetsByID[hit.assetID] == nil {
            throw FaceBenchmarkEvaluationError.unknownHitAsset(hit.assetID)
        }
        let sorted = hits.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.assetID < $1.assetID
        }
        var seen = Set<String>()
        return sorted.filter { seen.insert($0.assetID).inserted }
    }

    private static func aggregate(_ evaluations: [KnownEvaluation]) -> FaceBenchmarkAggregate {
        let count = evaluations.count
        guard count > 0 else {
            return FaceBenchmarkAggregate(queryCount: 0, rank1: 0, recallAt10: 0, precisionAt10: 0)
        }
        return FaceBenchmarkAggregate(
            queryCount: count,
            rank1: evaluations.map(\.rank1).reduce(0, +) / Double(count),
            recallAt10: evaluations.map(\.recalled).reduce(0, +) / Double(count),
            precisionAt10: Double(evaluations.map(\.relevantAt10).reduce(0, +)) / Double(10 * count))
    }

    private static func percentile(_ percentile: Double, sortedValues: [Double]) -> Double {
        guard !sortedValues.isEmpty else { return 0 }
        let rank = Int((percentile * Double(sortedValues.count)).rounded(.up))
        return sortedValues[max(0, min(sortedValues.count - 1, rank - 1))]
    }
}
