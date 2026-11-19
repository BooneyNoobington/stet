import Foundation
import Yams

public enum SceneStatus: String, CaseIterable, Identifiable {
    case draft, revised, done
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .draft: "Entwurf"
        case .revised: "Überarbeitet"
        case .done: "Fertig"
        }
    }
}

/// A scene file: optional YAML front matter plus the prose.
///
/// The front matter is kept byte for byte unless a property is changed, so opening and
/// saving a scene never produces a diff by itself.
public struct SceneFile: Equatable {
    public let id: String
    public var body: String
    private var meta: Node.Mapping
    private var rawHeader: String?

    public init(id: String, body: String = "", title: String? = nil) {
        self.id = id
        self.body = body
        self.meta = Node.Mapping([])
        self.rawHeader = nil
        if let title { self.title = title }
    }

    // MARK: Front matter fields

    public var title: String? {
        get { meta["title"]?.string.flatMap { $0.isEmpty ? nil : $0 } }
        set { set("title", newValue.flatMap { $0.isEmpty ? nil : Node($0) }) }
    }

    public var status: SceneStatus? {
        get { meta["status"]?.string.flatMap(SceneStatus.init(rawValue:)) }
        set { set("status", newValue.map { Node($0.rawValue) }) }
    }

    public var synopsis: String? {
        get { meta["synopsis"]?.string.flatMap { $0.isEmpty ? nil : $0 } }
        set { set("synopsis", newValue.flatMap { $0.isEmpty ? nil : Node($0) }) }
    }

    /// Quick facts (`facts:` mapping), in file order.
    public var facts: [(key: String, value: String)] {
        meta["facts"]?.mapping?.compactMap { pair in
            guard let key = pair.key.string, let value = pair.value.string else { return nil }
            return (key, value)
        } ?? []
    }

    /// Title, or the opening words when the scene has none.
    public var displayTitle: String {
        if let title { return title }
        let opening = TextStats.opening(of: body)
        return opening.isEmpty ? "Leere Szene" : opening
    }

    private mutating func set(_ key: String, _ value: Node?) {
        guard meta[key] != value else { return }
        meta[key] = value
        rawHeader = nil
    }

    // MARK: Parsing and serializing

    public static func parse(id: String, text: String) -> SceneFile {
        var scene = SceneFile(id: id, body: text)
        guard let (header, yaml, body) = splitFrontMatter(text),
              let node = try? Yams.compose(yaml: yaml),
              let mapping = node.mapping
        else { return scene }
        scene.meta = mapping
        scene.rawHeader = header
        scene.body = body
        return scene
    }

    public func serialized() -> String {
        if let rawHeader { return rawHeader + body }
        if meta.isEmpty { return body }
        let yaml = Manifest.emit(Node(meta.map { ($0.key, $0.value) }))
        return "---\n" + yaml + "---\n" + body
    }

    /// Splits `---\n<yaml>---\n<body>` into (header including delimiters, yaml, body).
    static func splitFrontMatter(_ text: String) -> (String, String, String)? {
        guard text.hasPrefix("---\n") else { return nil }
        let afterOpen = text.index(text.startIndex, offsetBy: 4)
        var searchStart = afterOpen
        while let close = text.range(of: "---", range: searchStart..<text.endIndex) {
            let atLineStart = close.lowerBound == afterOpen || text[text.index(before: close.lowerBound)] == "\n"
            let lineEnd = close.upperBound
            let atLineEnd = lineEnd == text.endIndex || text[lineEnd] == "\n"
            if atLineStart && atLineEnd {
                let headerEnd = lineEnd == text.endIndex ? lineEnd : text.index(after: lineEnd)
                let yaml = String(text[afterOpen..<close.lowerBound])
                return (String(text[..<headerEnd]), yaml, String(text[headerEnd...]))
            }
            searchStart = close.upperBound
        }
        return nil
    }
}
