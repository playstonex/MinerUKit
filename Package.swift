// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MinerUKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "MinerUKit", targets: ["MinerUKit"]),
        .executable(name: "minerukit", targets: ["minerukit-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", .upToNextMinor(from: "3.32.3")),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.4"),
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.32.3")),
    ],
    targets: [
        .target(
            name: "MinerUKit",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
            ]
        ),
        .executableTarget(
            name: "minerukit-cli",
            dependencies: ["MinerUKit"]
        ),
        .testTarget(
            name: "MinerUKitTests",
            dependencies: ["MinerUKit"]
        ),
    ]
)
