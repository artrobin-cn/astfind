import CoreGraphics
import Foundation

/// CoreML 本机人脸向量实现。模型由用户按许可自行放置，不随 App 分发。
public final class CoreMLFaceEmbedder: FaceEmbeddingProviding {
    public let profile: FaceProfile
    private let model: FaceCoreMLModel

    public init(modelURL: URL, profile: FaceProfile = .buffaloSC) throws {
        self.profile = profile
        self.model = try FaceCoreMLModel(contentsOf: modelURL)
    }

    public func embed(alignedImage: CGImage) throws -> [Float] {
        try model.embed(image: alignedImage)
    }
}
