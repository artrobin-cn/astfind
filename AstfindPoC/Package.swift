// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "AstfindPoC",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../oil-find")
    ],
    targets: [
        .executableTarget(
            name: "astfind-poc",
            dependencies: [
                .product(name: "OilFindCore", package: "oil-find")
            ]
        ),
        .executableTarget(
            name: "astfind-smb-poc",
            dependencies: [
                .product(name: "OilFindCore", package: "oil-find")
            ]
        )
    ]
)
