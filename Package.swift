// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mox",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .executable(name: "mox", targets: ["MoxCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift.git", from: "0.10.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.68.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-examples.git", from: "2.25.4"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "MoxShared",
            dependencies: []
        ),
        .target(
            name: "MoxCore",
            dependencies: [
                "MoxShared",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-examples"),
                .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
                .product(name: "Hub", package: "swift-transformers"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
        .target(
            name: "MoxServer",
            dependencies: [
                "MoxCore",
                "MoxShared",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),
        .executableTarget(
            name: "MoxCLI",
            dependencies: [
                "MoxCore",
                "MoxServer",
                "MoxShared",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "MoxCoreTests",
            dependencies: ["MoxCore", "MoxShared", "MoxServer"]
        ),
    ]
)
