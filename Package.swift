// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Mox",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "MoxCore", targets: ["MoxCore"]),
    .library(name: "MoxDomain", targets: ["MoxDomain"]),
    .library(name: "MoxClient", targets: ["MoxClient"]),
    .library(name: "MoxChat", targets: ["MoxChat"]),
    .library(name: "MoxBootstrap", targets: ["MoxBootstrap"]),
    .library(name: "MoxPersistence", targets: ["MoxPersistence"]),
    .executable(name: "mox", targets: ["MoxCLI"]),
  ],
  dependencies: [
    .package(url: "https://github.com/huggingface/swift-huggingface", exact: "0.11.0"),
    .package(url: "https://github.com/hummingbird-project/hummingbird", exact: "2.26.0"),
    .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.6"),
    .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.31.4"),
    .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.3"),
    .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.8.2"),
  ],
  targets: [
    .target(name: "MoxDomain"),
    .target(name: "MoxSources", dependencies: ["MoxCore", .product(name: "HuggingFace", package: "swift-huggingface")]),
    .target(name: "MoxProtocol", dependencies: ["MoxDomain"]),
    .target(name: "MoxChat", dependencies: ["MoxClient", "MoxPersistence"]),
    .target(name: "MoxPersistence", dependencies: ["MoxCore", "MoxProtocol", "MoxBootstrap"]),
    .target(name: "MoxClient", dependencies: ["MoxProtocol", "MoxBootstrap"]),
    .target(name: "MoxBootstrap", dependencies: ["MoxProtocol"]),
    .target(name: "MoxServer", dependencies: ["MoxCore", "MoxProtocol", .product(name: "Hummingbird", package: "hummingbird"), .product(name: "HummingbirdCore", package: "hummingbird")]),
    .target(name: "MoxCore", dependencies: ["MoxDomain"]),
    .target(
      name: "MoxMLX",
      dependencies: [
        "MoxCore", .product(name: "MLXLLM", package: "mlx-swift-lm"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "Tokenizers", package: "swift-transformers"),
      ]),
    .executableTarget(
      name: "MoxCLI",
      dependencies: ["MoxMLX", "MoxServer", "MoxClient", "MoxBootstrap", "MoxSources", "MoxPersistence", .product(name: "ArgumentParser", package: "swift-argument-parser")]),
    .executableTarget(name: "MoxTestSupport", dependencies: ["MoxServer", "MoxPersistence"], path: "Tests/Support"),
    .testTarget(name: "MoxServiceTests", dependencies: ["MoxChat", "MoxServer", "MoxClient", "MoxPersistence", .product(name: "Hummingbird", package: "hummingbird")]),
    .testTarget(name: "MoxCoreTests", dependencies: ["MoxCore"]),
    .testTarget(name: "MoxSourcesTests", dependencies: ["MoxSources"]),
    .testTarget(name: "MoxMLXTests", dependencies: ["MoxMLX", "MoxDomain"]),
  ],
  swiftLanguageModes: [.v6]
)
