import Foundation
import Yams

/// A quick fact: "Datum: 14.3.1953", "Ort: [[Hafen]]".
public struct Fact: Equatable, Hashable, Identifiable {
    public var key: String
    public var value: String
    public var id: String { key }

    public init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }

    /// The value without wiki-link brackets: "[[Hafen]]" → "Hafen".
    public var displayValue: String {
        value.replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "")
    }

    /// The wiki title a value links to, if it's written as "[[Title]]".
    public var linkedTitle: String? {
        guard value.hasPrefix("[["), value.hasSuffix("]]"), value.count > 4 else { return nil }
        return String(value.dropFirst(2).dropLast(2))
    }
}

public enum WikiKind: String, CaseIterable, Identifiable {
    case character, place, term, note
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .character: "Figur"
        case .place: "Ort"
        case .term: "Begriff"
        case .note: "Notiz"
        }
    }
    public var plural: String {
        switch self {
        case .character: "Figuren"
        case .place: "Orte"
        case .term: "Begriffe"
        case .note: "Notizen"
        }
    }
}

/// A wiki entry in `wiki/<slug>.md`: front matter (title, kind, aliases, facts) and free text.
public struct WikiEntry: Identifiable, Equatable {
    public static let folder = "wiki"

    public let id: String
    public var title: String
    public var kind: WikiKind
    public var aliases: [String]
    public var facts: [Fact]
    public var body: String

    public var path: String { "\(Self.folder)/\(id).md" }

    /// Title and aliases: the names the editor recognises.
    public var names: [String] {
        ([title] + aliases).map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 2 }
    }

    /// First non-empty line of the text, without heading marks.
    public var summary: String {
        body.split(separator: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces)) }
            .first { !$0.isEmpty } ?? ""
    }

    public init(id: String, title: String, kind: WikiKind = .character, aliases: [String] = [], facts: [Fact] = [], body: String = "") {
        self.id = id
        self.title = title
        self.kind = kind
        self.aliases = aliases
        self.facts = facts
        self.body = body
    }

    static func parse(id: String, text: String) -> WikiEntry {
        guard let (_, yaml, body) = SceneFile.splitFrontMatter(text),
              let map = (try? Yams.compose(yaml: yaml))?.mapping
        else {
            // A plain Markdown file (e.g. imported notes): title from the file name.
            return WikiEntry(id: id, title: id, kind: .note, body: text)
        }
        return WikiEntry(
            id: id,
            title: map["title"]?.string ?? id,
            kind: map["kind"]?.string.flatMap(WikiKind.init(rawValue:)) ?? .note,
            aliases: map["aliases"]?.sequence?.compactMap(\.string) ?? [],
            facts: map["facts"]?.mapping?.compactMap { pair in
                guard let key = pair.key.string, let value = pair.value.string else { return nil }
                return Fact(key, value)
            } ?? [],
            body: body
        )
    }

    func serialized() -> String {
        func str(_ s: String) -> Node { Node(s, Tag(.str), .doubleQuoted) }
        var pairs: [(Node, Node)] = [("title", str(title)), ("kind", Node(kind.rawValue))]
        let cleanAliases = aliases.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !cleanAliases.isEmpty { pairs.append(("aliases", Node(cleanAliases.map(str)))) }
        let cleanFacts = facts.filter { !$0.key.isEmpty && !$0.value.isEmpty }
        if !cleanFacts.isEmpty { pairs.append(("facts", Node(cleanFacts.map { (str($0.key), str($0.value)) }))) }
        return "---\n" + Manifest.emit(Node(pairs)) + "---\n" + body
    }
}

// MARK: - Recognising names in prose

/// Finds wiki names in prose: whole words only (Unicode letters), case-sensitive, longest name
/// first, and a German genitive "-s" counts ("Maras Sicht" → Mara).
public enum WikiMatcher {
    public struct Match: Equatable {
        public let range: NSRange
        public let name: String
    }

    public static func regex(for names: [String]) -> NSRegularExpression? {
        let unique = Array(Set(names)).sorted { $0.count > $1.count }
        guard !unique.isEmpty else { return nil }
        let alternatives = unique.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        return try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])("# + alternatives + #")(?:s|’s|'s)?(?![\p{L}\p{N}])"#)
    }

    public static func matches(in text: String, regex: NSRegularExpression) -> [Match] {
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            Match(range: $0.range, name: ns.substring(with: $0.range(at: 1)))
        }
    }
}

// MARK: - Book

extension Book {
    private var wikiURL: URL { url.appendingPathComponent(WikiEntry.folder) }

    /// All entries, by kind and title.
    public func wikiEntries() -> [WikiEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: wikiURL.path)) ?? []
        let order = Dictionary(uniqueKeysWithValues: WikiKind.allCases.enumerated().map { ($1, $0) })
        return files.filter { $0.lowercased().hasSuffix(".md") }.compactMap { file -> WikiEntry? in
            guard let data = FileManager.default.contents(atPath: wikiURL.appendingPathComponent(file).path) else { return nil }
            return WikiEntry.parse(id: String(file.dropLast(3)), text: String(decoding: data, as: UTF8.self))
        }
        .sorted { (order[$0.kind]!, $0.title.lowercased()) < (order[$1.kind]!, $1.title.lowercased()) }
    }

    public func saveWiki(_ entry: WikiEntry) throws {
        try FileManager.default.createDirectory(at: wikiURL, withIntermediateDirectories: true)
        let data = Data(entry.serialized().utf8)
        let target = url.appendingPathComponent(entry.path)
        if FileManager.default.contents(atPath: target.path) == data { return }
        try data.write(to: target, options: .atomic)
    }

    /// A new entry with a file name from its title (kept when the title changes later).
    @discardableResult
    public func createWiki(title: String, kind: WikiKind) throws -> WikiEntry {
        let existing = Set(wikiEntries().map(\.id))
        var id = Self.slug(title)
        var counter = 2
        while existing.contains(id) {
            id = "\(Self.slug(title))-\(counter)"
            counter += 1
        }
        let entry = WikiEntry(id: id, title: title.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind)
        try saveWiki(entry)
        return entry
    }

    public func deleteWiki(_ entry: WikiEntry) throws {
        try FileManager.default.removeItem(at: url.appendingPathComponent(entry.path))
    }

    /// The entry a name (title or alias) belongs to.
    public func wikiEntry(named name: String) -> WikiEntry? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return wikiEntries().first { $0.names.contains(wanted) }
    }

    /// Scenes (in reading order) where an entry's names occur, with how often.
    public func appearances(of entry: WikiEntry) -> [(sceneID: String, count: Int)] {
        guard let regex = WikiMatcher.regex(for: entry.names) else { return [] }
        return manifest.sceneIDs.compactMap { id in
            guard let scene = try? readScene(id) else { return nil }
            let count = WikiMatcher.matches(in: TextStats.stripComments(scene.body), regex: regex).count
            return count > 0 ? (id, count) : nil
        }
    }
}

// MARK: - Scene facts

extension SceneFile {
    /// Quick facts as editable values; empty values are not written.
    public var factList: [Fact] {
        get { facts.map { Fact($0.key, $0.value) } }
        set {
            let clean = newValue.filter { !$0.key.isEmpty && !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
            setFacts(clean.isEmpty ? nil : Node(clean.map { (Node($0.key, Tag(.str), .doubleQuoted), Node($0.value, Tag(.str), .doubleQuoted)) }))
        }
    }
}

extension Manifest {
    public static let defaultFactFields = ["Datum", "Uhrzeit", "Ort", "Perspektive"]

    /// The quick-fact fields every scene offers.
    public var sceneFactFields: [String] {
        get { factFields ?? Self.defaultFactFields }
        set { factFields = newValue == Self.defaultFactFields ? nil : newValue }
    }
}
