import CoreGraphics
import Foundation

/// 人脸索引 profile：模型、检测器、对齐与归一化版本必须整体一致。
/// 不同 profile 的向量不共享索引（M0.8 红线）。
public struct FaceProfile: Codable, Equatable, Sendable {
    public let id: String
    public let model: String
    public let detector: String
    public let alignment: String
    public let preprocessing: String
    public let normalization: String
    public let dimension: Int

    public init(id: String, model: String, detector: String, alignment: String,
                preprocessing: String, normalization: String, dimension: Int) {
        self.id = id
        self.model = model
        self.detector = detector
        self.alignment = alignment
        self.preprocessing = preprocessing
        self.normalization = normalization
        self.dimension = dimension
    }

    /// M0.8a 验证选定的本机轻量模型；权重不随 App 分发。
    public static let buffaloSC = FaceProfile(
        id: "face-buffalo_sc-v1",
        model: "buffalo_sc",
        detector: "vision",
        alignment: "arcface-5pt",
        preprocessing: "112x112-rgb-chw",
        normalization: "arcface",
        dimension: 512)
}

/// 生产抽取器协议；测试可注入 fake，CoreML/Python/服务器实现共用。
public protocol FaceEmbeddingProviding {
    var profile: FaceProfile { get }
    func embed(alignedImage: CGImage) throws -> [Float]
}

/// 检测/对齐预处理器协议；生产用 Vision，测试可注入 fake。
public protocol FacePreprocessing {
    func process(image: CGImage) throws -> FacePreprocessResult
}

extension VisionFacePreprocessor: FacePreprocessing {}
