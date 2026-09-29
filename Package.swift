// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodenotchLocal",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "CodenotchLocal", targets: ["CodenotchLocal"])],
    dependencies: [],
    targets: [
        .target(name: "TokenCounter"),
        .executableTarget(name: "CodenotchLocal", dependencies: ["TokenCounter"]),
        .testTarget(name: "TokenCounterTests", dependencies: ["TokenCounter"])
    ]
)
