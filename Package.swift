// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Narrate",
    platforms: [.macOS("15.0")],
    products: [
        .library(name: "NarrateCore", targets: ["NarrateCore"]),
        .executable(name: "narrate", targets: ["narrate"]),
    ],
    dependencies: [
        // Kokoro-82M on Core ML (Neural Engine, GPU, CPU). Pinned: the SDK pins its own model revision.
        .package(url: "https://github.com/mattmireles/kokoro-coreml.git", revision: "58d56359683ad057a159c4c5233c2ab68e620d2c"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "NarrateCore",
            dependencies: [.product(name: "KokoroTTS", package: "kokoro-coreml")]
        ),
        .executableTarget(
            name: "narrate",
            dependencies: [
                "NarrateCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // Shares tests/ with the Python reference implementation's pytest suite.
        .testTarget(name: "NarrateCoreTests", dependencies: ["NarrateCore"], path: "tests/NarrateCoreTests"),
    ]
)
