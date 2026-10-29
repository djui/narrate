// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "coreml-bench",
    platforms: [.macOS("15.0")],
    dependencies: [.package(name: "KokoroCoreML", path: "../src")],
    targets: [
        .executableTarget(
            name: "coreml-bench",
            dependencies: [.product(name: "KokoroTTS", package: "KokoroCoreML")]
        ),
    ]
)
