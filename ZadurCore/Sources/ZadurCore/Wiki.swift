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
    /// Words that look like this name (usually with genitive s) but mean someone else, e.g. for
    /// Andrea: "Andreas". They are not underlined or counted as this entry.
    public var notMeant: [String] = []
    /// Front-matter keys Zadur doesn't know (another program's): kept as they are.
    public var unknown: [Manifest.UnknownKey] = []
    static let knownKeys: Set<String> = ["title", "kind", "aliases", "facts", "notMeant"]

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

    public init(id: String, title: String, kind: WikiKind = .character, aliases: [String] = [], facts: [Fact] = [],
                body: String = "", notMeant: [String] = []) {
        self.id = id
        self.title = title
        self.kind = kind
        self.aliases = aliases
        self.facts = facts
        self.body = body
        self.notMeant = notMeant
    }

    static func parse(id: String, text: String) -> WikiEntry {
        guard let (_, yaml, body) = SceneFile.splitFrontMatter(text),
              let map = (try? Yams.compose(yaml: yaml))?.mapping
        else {
            // A plain Markdown file (e.g. imported notes): title from the file name.
            return WikiEntry(id: id, title: id, kind: .note, body: text)
        }
        var entry = WikiEntry(
            id: id,
            title: map["title"]?.string ?? id,
            kind: map["kind"]?.string.flatMap(WikiKind.init(rawValue:)) ?? .note,
            aliases: map["aliases"]?.sequence?.compactMap(\.string) ?? [],
            facts: map["facts"]?.mapping?.compactMap { pair in
                guard let key = pair.key.string, let value = pair.value.string else { return nil }
                return Fact(key, value)
            } ?? [],
            body: body,
            notMeant: map["notMeant"]?.sequence?.compactMap(\.string) ?? []
        )
        entry.unknown = map.compactMap { pair in
            guard let key = pair.key.string, !knownKeys.contains(key) else { return nil }
            return Manifest.UnknownKey(key: key, value: pair.value)
        }
        return entry
    }

    func serialized() -> String {
        func str(_ s: String) -> Node { Node(s, Tag(.str), .doubleQuoted) }
        var pairs: [(Node, Node)] = [("title", str(title)), ("kind", Node(kind.rawValue))]
        let cleanAliases = aliases.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !cleanAliases.isEmpty { pairs.append(("aliases", Node(cleanAliases.map(str)))) }
        let cleanFacts = facts.filter { !$0.key.isEmpty && !$0.value.isEmpty }
        if !cleanFacts.isEmpty { pairs.append(("facts", Node(cleanFacts.map { (str($0.key), str($0.value)) }))) }
        let cleanNotMeant = notMeant.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !cleanNotMeant.isEmpty { pairs.append(("notMeant", Node(cleanNotMeant.map(str)))) }
        for extra in unknown { pairs.append((Node(extra.key), extra.value)) }
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

    /// The name, optionally with genitive s ("Maras"), English-style 's, or, for names ending in
    /// s, ß, x or z, the old genitive -ens ("Hansens", "Fritzens"). "Andreas'" matches as Andreas.
    public static let suffix = #"(?:s|’s|'s|(?<=[sßxzSXZ])ens)?"#

    public static func regex(for names: [String]) -> NSRegularExpression? {
        let unique = Array(Set(names)).sorted { $0.count > $1.count }
        guard !unique.isEmpty else { return nil }
        let alternatives = unique.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        return try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])("# + alternatives + ")" + suffix + #"(?![\p{L}\p{N}])"#)
    }

    /// `excluding`: the matched words to leave out (an entry's "not meant" words).
    public static func matches(in text: String, regex: NSRegularExpression, excluding: Set<String> = []) -> [Match] {
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            excluding.contains(ns.substring(with: $0.range)) ? nil : Match(range: $0.range, name: ns.substring(with: $0.range(at: 1)))
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
    /// File names are compared ignoring case: the Mac's file system does, too.
    @discardableResult
    public func createWiki(title: String, kind: WikiKind) throws -> WikiEntry {
        let existing = Set(wikiEntries().map { $0.id.lowercased() })
        var id = Self.slug(title)
        var counter = 2
        while existing.contains(id.lowercased()) {
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
        // All names at once, so a longer name of another entry wins ("Andreas" is Andreas,
        // not Andrea with genitive s, if both are in the wiki).
        let all = wikiEntries()
        guard let regex = WikiMatcher.regex(for: Array(Set(all.flatMap(\.names) + entry.names))) else { return [] }
        let names = Set(entry.names)
        let excluded = Set(entry.notMeant)
        return manifest.sceneIDs.compactMap { id in
            guard let scene = try? readScene(id) else { return nil }
            let count = WikiMatcher.matches(in: TextStats.stripComments(scene.body), regex: regex, excluding: excluded)
                .filter { names.contains($0.name) }.count
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

// MARK: - Taking the wiki along (e.g. into a sequel)

public struct WikiImport: Equatable {
    /// Titles of the entries that were added.
    public var added: [String] = []
    /// Titles of entries this book already had (by one of their names); left as they are.
    public var skipped: [String] = []
}

public enum WikiTransferError: Error, LocalizedError, Equatable {
    case empty
    case nothingFound(String)
    case zipFailed(String)

    public var errorDescription: String? {
        switch self {
        case .empty: "Das Wiki dieses Buchs ist noch leer."
        case .nothingFound(let name): "In „\(name)“ gibt es keine Wiki-Einträge."
        case .zipFailed(let detail): "Das Archiv ließ sich nicht verarbeiten: \(detail)"
        }
    }
}

extension Book {
    /// The whole wiki as a ZIP file: a folder "Wiki" with one Markdown file per entry, readable
    /// in any text editor and importable into another book.
    public func exportWiki(to destination: URL) throws {
        let entries = wikiEntries()
        guard !entries.isEmpty else { throw WikiTransferError.empty }
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("zadur-wiki-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temp) }
        let folder = temp.appendingPathComponent("Wiki")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for entry in entries {
            try Data(entry.serialized().utf8).write(to: folder.appendingPathComponent("\(entry.id).md"))
        }
        let archive = temp.appendingPathComponent("wiki.zip")
        let result = try Tools.run(URL(fileURLWithPath: "/usr/bin/zip"), ["-q", "-r", "-X", archive.path, "Wiki"], in: temp)
        guard result.status == 0 else { throw WikiTransferError.zipFailed(result.errors) }
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: archive, to: destination)
    }

    /// Entries from another book (`.crea`), an exported ZIP, or a folder of Markdown files.
    public static func wikiEntries(at source: URL) throws -> [WikiEntry] {
        let fm = FileManager.default
        var isFolder: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isFolder) else { throw WikiTransferError.nothingFound(source.lastPathComponent) }
        if !isFolder.boolValue {
            try ZipCheck.check(source)  // a link in there could pull any file into the wiki
            let temp = fm.temporaryDirectory.appendingPathComponent("zadur-wiki-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: temp) }
            try fm.createDirectory(at: temp, withIntermediateDirectories: true)
            let result = try Tools.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-q", source.path, "-d", temp.path])
            guard result.status == 0 else { throw WikiTransferError.zipFailed(result.errors) }
            return try wikiEntries(inFolder: temp, name: source.lastPathComponent)
        }
        return try wikiEntries(inFolder: source, name: source.lastPathComponent)
    }

    private static func wikiEntries(inFolder folder: URL, name: String) throws -> [WikiEntry] {
        let fm = FileManager.default
        var candidates = [folder.appendingPathComponent(WikiEntry.folder), folder.appendingPathComponent("Wiki"), folder]
        // An archive may hold one folder around everything.
        let inside = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") && !$0.hasPrefix("__MACOSX") }
        if inside.count == 1 { candidates.append(folder.appendingPathComponent(inside[0])) }
        for candidate in candidates {
            let files = ((try? fm.contentsOfDirectory(atPath: candidate.path)) ?? []).filter { $0.lowercased().hasSuffix(".md") && !$0.hasPrefix(".") }
            guard !files.isEmpty else { continue }
            return files.sorted().compactMap { file in
                guard let data = fm.contents(atPath: candidate.appendingPathComponent(file).path) else { return nil }
                return WikiEntry.parse(id: String(file.dropLast(3)), text: String(decoding: data, as: UTF8.self))
            }
        }
        throw WikiTransferError.nothingFound(name)
    }

    /// Adds the entries this book doesn't have yet (matched by any of their names, ignoring
    /// case), with their aliases, facts and notes. Existing entries stay as they are.
    @discardableResult
    public func importWiki(_ entries: [WikiEntry]) throws -> WikiImport {
        var report = WikiImport()
        let current = wikiEntries()
        var names = Set(current.flatMap(\.names).map { $0.lowercased() })
        var ids = Set(current.map { $0.id.lowercased() })
        for entry in entries {
            if entry.names.contains(where: { names.contains($0.lowercased()) }) {
                report.skipped.append(entry.title)
                continue
            }
            // Names compared and kept in NFC (Crea spec §2.3): a source may hand out decomposed ones.
            // (On disk the Mac decomposes them again; git's index keeps NFC.)
            let base = (entry.id.isEmpty ? Self.slug(entry.title) : entry.id).precomposedStringWithCanonicalMapping
            var id = base
            var counter = 2
            while ids.contains(id.lowercased()) {
                id = "\(base)-\(counter)"
                counter += 1
            }
            var copy = WikiEntry(id: id, title: entry.title, kind: entry.kind, aliases: entry.aliases, facts: entry.facts,
                                 body: entry.body, notMeant: entry.notMeant)
            copy.unknown = entry.unknown
            try saveWiki(copy)
            ids.insert(id.lowercased())
            names.formUnion(entry.names.map { $0.lowercased() })
            report.added.append(entry.title)
        }
        return report
    }
}
