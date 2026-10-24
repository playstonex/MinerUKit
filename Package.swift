// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MinerUKit",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "MinerUKit", targets: ["MinerUKit"]),
        .executable(name: "minerukit", targets: ["minerukit-cli"]),
    ],
    dependencies: [
        // Pin mlx-swift / mlx-swift-lm to EXACT versions. MinerUKit and PetalASR
        // are each dlopen'd into the host app as separate frameworks that each
        // statically embed MLX; if their mlx-swift versions ever diverge, the
        // ObjC runtime's "first class wins" rule makes the second framework use
        // the FIRST one's MLX classes — a source of spurious casting failures
        // and crashes. Keeping both frameworks on the exact same mlx-swift
        // commit is the cheap guard. Must match speech-swift (PetalASR's source)
        // which pins mlx-swift-lm exact 3.32.3 / mlx-swift 0.32.3.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.4"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
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
