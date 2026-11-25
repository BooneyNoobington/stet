// swift-tools-version: 5.10
// ZadurCore: everything that isn't UI. Book format, git, history, diff, import, safety checks.
import PackageDescription

let package = Package(
    name: "ZadurCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ZadurCore", targets: ["ZadurCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.0")
    ],
    targets: [
        .target(name: "ZadurCore", dependencies: ["Yams"], resources: [.copy("Resources")]),
        .testTarget(name: "ZadurCoreTests", dependencies: ["ZadurCore"]),
    ]
)
