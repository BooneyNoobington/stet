// swift-tools-version: 5.10
// Editor spike: a minimal macOS shell around the CodeMirror writing pane in editor/dist.
// Build an .app with scripts/build-spike.sh; for development, `swift run --package-path app`.
import PackageDescription

let package = Package(
    name: "Stet",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Stet", path: "Sources/Stet")
    ]
)
