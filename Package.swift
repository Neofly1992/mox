// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Mox",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MoxCore", targets: ["MoxCore"]),
    ],
    targets: [
        .target(name: "MoxDomain"),
        .target(name: "MoxCore", dependencies: ["MoxDomain"]),
    ],
    swiftLanguageModes: [.v6]
)
