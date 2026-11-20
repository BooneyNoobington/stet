// swift-tools-version: 5.10
// StetCore: everything that isn't UI. Book format, git, history, diff, import, safety checks.
import PackageDescription

let package = Package(
    name: "StetCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StetCore", targets: ["StetCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.0")
    ],
    targets: [
        .target(name: "StetCore", dependencies: ["Yams"], resources: [.copy("Resources")]),
        .testTarget(name: "StetCoreTests", dependencies: ["StetCore"]),
    ]
)
