import Foundation

/// Locates the built editor (editor/dist): inside the app bundle, via STET_EDITOR_DIR,
/// or, during development, relative to this source file.
enum EditorResources {
    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["STET_EDITOR_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let bundled = Bundle.main.url(forResource: "editor", withExtension: nil) {
            return bundled
        }
        // Stet/Sources/EditorResources.swift → repository root → editor/dist
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("editor/dist", isDirectory: true)
    }

    static var indexURL: URL { directory.appendingPathComponent("index.html") }
    static var sampleURL: URL { directory.appendingPathComponent("samples/szene.md") }
}
