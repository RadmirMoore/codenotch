// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "CodenotchLocal", platforms: [.macOS("15.0")], products: [.executable(name: "CodenotchLocal", targets: ["CodenotchLocal"])], dependencies: [], targets: [
    .executableTarget(name: "CodenotchLocal", path: "Sources", exclude: ["Assets.xcassets", "Localizable.xcstrings"]),
    .testTarget(name: "CodenotchTests", dependencies: ["CodenotchLocal"], path: "Tests")
])
