// swift-tools-version:5.10
import PackageDescription

// Astfind 只依赖上游 Oil Find 的核心库（文件名索引、扫描、查询）。
// 上游 App、官网、Pro 页面、支付/许可服务、素材、脚本与测试不在本仓库分发。
let package = Package(
    name: "OilFind",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OilFindCore", targets: ["OilFindCore"])
    ],
    targets: [
        .target(name: "COilFind", publicHeadersPath: "include"),
        .target(name: "OilFindCore", dependencies: ["COilFind"])
    ],
    swiftLanguageVersions: [.v5]
)
