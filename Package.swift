// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "mox",
    platforms: [
        .macOS(.v15),
        .iOS(.v17)
    ],
    products: [
        .executable(name: "mox", targets: ["MoxCLI"]),
        .executable(name: "mox-server", targets: ["MoxServerCLI"]),
        .executable(name: "mox-gui", targets: ["MoxGUI"]),
        .library(name: "MoxGUIClient", targets: ["MoxGUIClient"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift.git", from: "0.31.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "3.31.0"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.0"),
        .package(url: "https://github.com/swiftlang/swift-testing.git", from: "0.10.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.101.0"),
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
                "MoxConvertCore",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
            ]
        ),
        .target(
            name: "MoxConvertCore",
            dependencies: [
                "MoxShared",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
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
        .target(
            name: "MoxGUIClient",
            dependencies: ["MoxShared"]
        ),
        .executableTarget(
            name: "MoxCLI",
            dependencies: [
                "MoxCore",
                "MoxConvertCore",
                "MoxServer",
                "MoxShared",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            // mox uses `@main struct MoxCLI` but also has top-level
            // constructs (private enum `AskError` was historically
            // top-level, and Swift treats the module's other
            // declarations as "top-level code" by default). The
            // canonical fix is `-parse-as-library`, which tells the
            // compiler to treat the file as a library entry point
            // (only `@main` is the entry; everything else is just a
            // declaration). Without it, the build emits the error
            // "'main' attribute cannot be used in a module that
            // contains top-level code" and the binary can't be
            // produced.
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        ),
        .executableTarget(
            name: "MoxServerCLI",
            dependencies: ["MoxCore", "MoxServer", "MoxShared"]
        ),
        .executableTarget(
            name: "MoxGUI",
            dependencies: [
                "MoxGUIClient",
                "MoxShared"
            ]
        ),
        .testTarget(
            name: "MoxCoreTests",
            dependencies: [
                "MoxCore",
                "MoxConvertCore",
                .product(name: "Testing", package: "swift-testing"),
                "MoxShared",
                "MoxServer"
            ]
        ),
        .testTarget(
            name: "MoxGUIClientTests",
            dependencies: [
                "MoxGUIClient",
                .product(name: "Testing", package: "swift-testing"),
                "MoxShared"
            ]
        ),
        .testTarget(
            // Tests for the MoxCLI target's pure helpers. Currently
            // limited to `Doctor` (the only pure-enough surface in
            // the CLI to unit test without spawning a daemon). Tests
            // for handlePull / handleChat stay out — those need an
            // integration harness that doesn't exist yet.
            name: "MoxCLITests",
            dependencies: [
                "MoxCLI",
                .product(name: "Testing", package: "swift-testing"),
                "MoxCore",
                "MoxShared"
            ]
        ),
        .testTarget(
            // Unit tests for the MoxServer router / JSON response
            // helpers. Integration tests for live endpoints (model
            // load, chat) need a daemon harness that doesn't exist
            // yet — those land alongside the daemon harness in a
            // later release.
            name: "MoxServerTests",
            dependencies: [
                "MoxServer",
                "MoxCore",
                "MoxShared",
                .product(name: "Testing", package: "swift-testing")
            ]
        ),
    ]
)
