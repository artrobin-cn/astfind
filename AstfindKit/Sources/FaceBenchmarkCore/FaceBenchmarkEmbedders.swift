import AstfindFaceCore
import CoreGraphics
import Darwin
import Foundation

public protocol FaceBenchmarkEmbedder {
    var modelIdentifier: String { get }
    var dimension: Int { get }
    func embed(images: [CGImage]) throws -> [[Float]]
}

public struct FaceCoreMLEmbedder: FaceBenchmarkEmbedder {
    public let modelIdentifier: String
    public let dimension: Int
    private let model: FaceCoreMLModel

    public init(
        modelPath: String,
        dimension: Int,
        modelIdentifier: String = "buffalo_sc"
    ) throws {
        guard dimension > 0 else { throw FaceEmbeddingError.invalidOutputDimension }
        self.model = try FaceCoreMLModel(contentsOf: URL(fileURLWithPath: modelPath))
        self.dimension = dimension
        self.modelIdentifier = modelIdentifier
    }

    public func embed(images: [CGImage]) throws -> [[Float]] {
        try images.map { image in
            let vector = try model.embed(image: image)
            guard vector.count == dimension else {
                throw FaceEmbeddingError.invalidOutputDimension
            }
            return vector
        }
    }
}

public struct FaceBenchmarkImageLoader {
    public let load: (String) throws -> CGImage

    public init(load: @escaping (String) throws -> CGImage) {
        self.load = load
    }

    public static let fileSystem = FaceBenchmarkImageLoader {
        try FaceBenchmarkImageIO.load(path: $0)
    }
}

public enum FaceBenchmarkResourceProbe {
    public static func peakResidentBytes() -> UInt64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return UInt64(max(0, usage.ru_maxrss))
    }
}
