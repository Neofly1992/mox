// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Mox",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "MoxCore", targets: ["MoxCore"]),
    .executable(name: "mox", targets: ["MoxCLI"]),
  ],
  dependencies: [
    .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.6"),
    .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.31.4"),
    .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.3"),
    .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.8.2"),
  ],
  targets: [
    .target(name: "MoxDomain"),
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
      dependencies: ["MoxMLX", .product(name: "ArgumentParser", package: "swift-argument-parser")]),
    .testTarget(name: "MoxCoreTests", dependencies: ["MoxCore"]),
    .testTarget(name: "MoxMLXTests", dependencies: ["MoxMLX"]),
  ],
  swiftLanguageModes: [.v6]
)
