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
            ]
        ),
        .target(
            name: "MoxServer",
            dependencies: [
                "MoxCore",
                "MoxShared",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
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
            dependencies: ["MoxCore"]
        ),
    ]
)
