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
        // English G2P inside kokoro-coreml; used directly for unknown-word reports and respellings. Same pin as kokoro-coreml's.
        .package(url: "https://github.com/mattmireles/MisakiSwift", revision: "3a27756a780fc138e328a96e533fb440a3419d5b"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        // Update checks for the app; the feed is docs/appcast.xml on GitHub Pages.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
    ],
    targets: [
        .target(
            name: "NarrateCore",
            dependencies: [
                .product(name: "KokoroTTS", package: "kokoro-coreml"),
                .product(name: "MisakiSwift", package: "MisakiSwift"),
            ]
        ),
        .executableTarget(
            name: "narrate",
            dependencies: [
                "NarrateCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // The SwiftUI app: `swift run NarrateApp [book.epub | book.narrate]`, or scripts/bundle-app.sh for a .app.
        .executableTarget(
            name: "NarrateApp",
            dependencies: ["NarrateCore", .product(name: "KokoroTTS", package: "kokoro-coreml"), .product(name: "Sparkle", package: "Sparkle")]
        ),
        // Shares tests/ with the Python reference implementation's pytest suite.
        .testTarget(name: "NarrateCoreTests", dependencies: ["NarrateCore"], path: "tests/NarrateCoreTests"),
    ]
)
