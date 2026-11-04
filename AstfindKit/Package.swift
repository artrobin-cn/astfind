// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "AstfindKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AstfindKit", targets: ["AstfindKit"])
    ],
    dependencies: [
        .package(path: "../oil-find")
    ],
    targets: [
        // vendored fork of upstream OilFindApp（ADR-121：品牌替换 + 禁上游更新器）。
        // 模块更名 AstfindPanel（SwiftPM 禁止包图内同名 target）；差异清单见 docs/fork-diff.md
        .target(
            name: "AstfindPanel",
            dependencies: [.product(name: "OilFindCore", package: "oil-find")],
            path: "Sources/AstfindPanel",
            resources: [.copy("Resources")]
        ),
        // 人脸检测/对齐/CoreML 向量/相似度：生产与 benchmark 共用，权重不随包分发。
        .target(name: "AstfindFaceCore"),
        .target(name: "AstfindKit", dependencies: [
            .product(name: "OilFindCore", package: "oil-find"),
            "AstfindPanel",
            "AstfindFaceCore"
        ]),
        .executableTarget(
            name: "astfind-registry-demo",
            dependencies: ["AstfindKit"]
        ),
        .executableTarget(
            name: "Astfind",
            dependencies: [
                "AstfindPanel",
                "AstfindKit"
            ]
        ),
        .executableTarget(
            name: "astfind-sources",
            dependencies: ["AstfindKit"]
        ),
        .testTarget(name: "AstfindKitTests", dependencies: ["AstfindKit", "AstfindPanel"]),
        .target(name: "FaceBenchmarkCore", dependencies: ["AstfindFaceCore"]),
        .executableTarget(
            name: "astfind-face-benchmark",
            dependencies: ["FaceBenchmarkCore"]
        ),
        .testTarget(name: "FaceBenchmarkTests", dependencies: ["FaceBenchmarkCore", "AstfindFaceCore"])
    ]
)
