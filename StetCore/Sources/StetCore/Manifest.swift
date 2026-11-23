import Foundation
import Yams

/// `manuscript.yaml`: book metadata and structure (order of parts, chapters and scenes).
public struct Manifest: Equatable {
    public static let fileName = "manuscript.yaml"
    public static let currentFormat = 1

    public var format = Manifest.currentFormat
    public var title: String
    public var authors: [String]
    public var language: String
    /// The book's quotation marks, if chosen (nil: by language, see `quoteStyle`).
    public var quotes: QuoteStyle?
    public var year: Int?
    public var cover: String?
    public var epubCSS: String?
    /// The quick-fact fields of scenes (nil: the defaults).
    public var factFields: [String]?
    /// Words that are spelled right in this book (names, invented words …), for the spelling check.
    public var words: [String]?
    /// Words the book should reach (the writer's goal), if set.
    public var wordGoal: Int?
    public var structure: [StructureNode]
    /// Top-level keys Stet doesn't know (written by a newer version); preserved as is.
    public var unknown: [UnknownKey] = []

    public init(title: String, authors: [String], language: String, year: Int? = nil, structure: [StructureNode] = []) {
        self.title = title
        self.authors = authors
        self.language = language
        self.year = year
        self.structure = structure
    }

    /// The quotation marks typing and exports use.
    public var quoteStyle: QuoteStyle { quotes ?? .standard(forLanguage: language) }

    public struct UnknownKey: Equatable {
        public var key: String
        public var value: Node
    }
}

public enum StructureNode: Equatable {
    case chapter(Chapter)
    case part(Part)
}

public struct Chapter: Equatable, Identifiable {
    public var id: String
    public var title: String
    public var sceneIDs: [String]
    /// Quick facts for the whole chapter (e.g. "Datum: Juli 1998"); scenes inherit what they don't set.
    public var facts: [Fact]

    public init(id: String, title: String, sceneIDs: [String] = [], facts: [Fact] = []) {
        self.id = id
        self.title = title
        self.sceneIDs = sceneIDs
        self.facts = facts
    }
}

public struct Part: Equatable, Identifiable {
    public var id: String
    public var title: String
    public var chapters: [Chapter]
    /// Quick facts for the whole part; its chapters and scenes inherit them.
    public var facts: [Fact]

    public init(id: String, title: String, chapters: [Chapter] = [], facts: [Fact] = []) {
        self.id = id
        self.title = title
        self.chapters = chapters
        self.facts = facts
    }
}

public enum ManifestError: Error, LocalizedError {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let detail): "manuscript.yaml ist ungültig: \(detail)"
        }
    }
}

// MARK: - Queries and edits

extension Manifest {
    /// All chapters in reading order, including those inside parts.
    public var chapters: [Chapter] {
        structure.flatMap { node -> [Chapter] in
            switch node {
            case .chapter(let chapter): [chapter]
            case .part(let part): part.chapters
            }
        }
    }

    /// All scene IDs in reading order.
    public var sceneIDs: [String] { chapters.flatMap(\.sceneIDs) }

    public var allIDs: Set<String> {
        var ids = Set(sceneIDs)
        for node in structure {
            switch node {
            case .chapter(let chapter): ids.insert(chapter.id)
            case .part(let part):
                ids.insert(part.id)
                part.chapters.forEach { ids.insert($0.id) }
            }
        }
        return ids
    }

    public func chapter(containing sceneID: String) -> Chapter? {
        chapters.first { $0.sceneIDs.contains(sceneID) }
    }

    public func chapter(withID id: String) -> Chapter? {
        chapters.first { $0.id == id }
    }

    /// Applies `change` to the chapter with `id`, wherever it lives.
    public mutating func updateChapter(_ id: String, _ change: (inout Chapter) -> Void) {
        for index in structure.indices {
            switch structure[index] {
            case .chapter(var chapter) where chapter.id == id:
                change(&chapter)
                structure[index] = .chapter(chapter)
                return
            case .part(var part):
                if let c = part.chapters.firstIndex(where: { $0.id == id }) {
                    change(&part.chapters[c])
                    structure[index] = .part(part)
                    return
                }
            default:
                continue
            }
        }
    }

    /// Removes a scene from whichever chapter holds it.
    public mutating func removeScene(_ sceneID: String) {
        for chapter in chapters where chapter.sceneIDs.contains(sceneID) {
            updateChapter(chapter.id) { $0.sceneIDs.removeAll { $0 == sceneID } }
        }
    }

    /// Moves a scene into `chapterID` at `index` (clamped).
    public mutating func moveScene(_ sceneID: String, toChapter chapterID: String, at index: Int) {
        removeScene(sceneID)
        updateChapter(chapterID) { chapter in
            let clamped = max(0, min(index, chapter.sceneIDs.count))
            chapter.sceneIDs.insert(sceneID, at: clamped)
        }
    }

    /// Moves a top-level chapter or part up (-1) or down (+1).
    public mutating func moveStructureNode(containingChapter chapterID: String, by offset: Int) {
        if let index = structure.firstIndex(where: {
            if case .chapter(let c) = $0 { return c.id == chapterID }
            return false
        }) {
            let target = index + offset
            guard structure.indices.contains(target) else { return }
            structure.swapAt(index, target)
            return
        }
        // Inside a part: move within the part.
        for (p, node) in structure.enumerated() {
            guard case .part(var part) = node, let index = part.chapters.firstIndex(where: { $0.id == chapterID })
            else { continue }
            let target = index + offset
            guard part.chapters.indices.contains(target) else { return }
            part.chapters.swapAt(index, target)
            structure[p] = .part(part)
            return
        }
    }

    /// Inserts a chapter after `afterChapterID` (or at the end).
    public mutating func insertChapter(_ chapter: Chapter, after afterChapterID: String?) {
        guard let afterChapterID else {
            structure.append(.chapter(chapter))
            return
        }
        for (index, node) in structure.enumerated() {
            switch node {
            case .chapter(let c) where c.id == afterChapterID:
                structure.insert(.chapter(chapter), at: index + 1)
                return
            case .part(var part):
                if let c = part.chapters.firstIndex(where: { $0.id == afterChapterID }) {
                    part.chapters.insert(chapter, at: c + 1)
                    structure[index] = .part(part)
                    return
                }
            default:
                continue
            }
        }
        structure.append(.chapter(chapter))
    }

    /// Removes a chapter; its scenes move to the previous chapter (or the next one).
    public mutating func removeChapter(_ chapterID: String) {
        let all = chapters
        guard let index = all.firstIndex(where: { $0.id == chapterID }), all.count > 1 else { return }
        let orphans = all[index].sceneIDs
        let heir = index > 0 ? all[index - 1].id : all[index + 1].id
        structure = structure.compactMap { node in
            switch node {
            case .chapter(let c): return c.id == chapterID ? nil : node
            case .part(var part):
                part.chapters.removeAll { $0.id == chapterID }
                return .part(part)
            }
        }
        updateChapter(heir) { $0.sceneIDs.append(contentsOf: orphans) }
    }
}

// MARK: - YAML

extension Manifest {
    public static func parse(_ yaml: String) throws -> Manifest {
        guard let root = try Yams.compose(yaml: yaml), let map = root.mapping else {
            throw ManifestError.invalid("kein YAML-Objekt")
        }
        guard let title = map["title"]?.string else { throw ManifestError.invalid("'title' fehlt") }

        var manifest = Manifest(
            title: title,
            authors: Self.stringList(map["authors"] ?? map["author"]),
            language: map["language"]?.string ?? "de",
            year: map["year"]?.int
        )
        manifest.format = map["format"]?.int ?? Manifest.currentFormat
        manifest.quotes = map["quotes"]?.string.flatMap(QuoteStyle.init(rawValue:))
        manifest.cover = map["cover"]?.string
        manifest.epubCSS = map["epubCSS"]?.string
        manifest.factFields = map["factFields"]?.sequence?.compactMap(\.string)
        manifest.words = map["words"]?.sequence?.compactMap(\.string)
        manifest.wordGoal = map["wordGoal"]?.int
        manifest.structure = try (map["structure"]?.sequence ?? []).map(Self.parseNode)

        let known: Set<String> = ["format", "title", "authors", "author", "language", "quotes", "year", "cover", "epubCSS", "factFields", "words", "wordGoal", "structure"]
        for (key, value) in map {
            if let name = key.string, !known.contains(name) {
                manifest.unknown.append(UnknownKey(key: name, value: value))
            }
        }
        return manifest
    }

    private static func stringList(_ node: Node?) -> [String] {
        if let single = node?.string { return [single] }
        return node?.sequence?.compactMap(\.string) ?? []
    }

    private static func parseNode(_ node: Node) throws -> StructureNode {
        guard let map = node.mapping else { throw ManifestError.invalid("Strukturelement ist kein Objekt") }
        if let title = map["part"]?.string {
            let chapters = try (map["chapters"]?.sequence ?? []).map { node -> Chapter in
                guard case .chapter(let chapter) = try parseNode(node) else {
                    throw ManifestError.invalid("Teil '\(title)' enthält etwas anderes als Kapitel")
                }
                return chapter
            }
            return .part(Part(id: map["id"]?.string ?? StetID.make(prefix: "p"), title: title, chapters: chapters, facts: parseFacts(map["facts"])))
        }
        if let title = map["chapter"]?.string {
            let scenes = map["scenes"]?.sequence?.compactMap(\.string) ?? []
            return .chapter(Chapter(id: map["id"]?.string ?? StetID.make(prefix: "c"), title: title, sceneIDs: scenes, facts: parseFacts(map["facts"])))
        }
        throw ManifestError.invalid("Strukturelement ohne 'chapter' oder 'part'")
    }

    public func yaml() -> String {
        var pairs: [(Node, Node)] = [
            ("format", Node(String(format))),
            ("title", Node(title)),
            ("authors", Node(authors.map { Node($0) })),
            ("language", Node(language)),
        ]
        if let quotes { pairs.append(("quotes", Node(quotes.rawValue))) }
        if let year { pairs.append(("year", Node(String(year)))) }
        if let cover { pairs.append(("cover", Node(cover))) }
        if let epubCSS { pairs.append(("epubCSS", Node(epubCSS))) }
        if let factFields { pairs.append(("factFields", Node(factFields.map { Node($0) }))) }
        if let wordGoal { pairs.append(("wordGoal", Node(String(wordGoal)))) }
        if let words, !words.isEmpty { pairs.append(("words", Node(words.map { Node($0, Tag(.str), .doubleQuoted) }))) }
        pairs.append(("structure", Node(structure.map(Self.node))))
        for extra in unknown { pairs.append((Node(extra.key), extra.value)) }
        return Self.emit(Node(pairs))
    }

    private static func node(_ structureNode: StructureNode) -> Node {
        switch structureNode {
        case .chapter(let chapter):
            var pairs: [(String, Node)] = [("chapter", Node(chapter.title)), ("id", Node(chapter.id))]
            if let facts = factsNode(chapter.facts) { pairs.append(("facts", facts)) }
            pairs.append(("scenes", Node(chapter.sceneIDs.map { Node($0) })))
            return mapping(pairs)
        case .part(let part):
            var pairs: [(String, Node)] = [("part", Node(part.title)), ("id", Node(part.id))]
            if let facts = factsNode(part.facts) { pairs.append(("facts", facts)) }
            pairs.append(("chapters", Node(part.chapters.map { node(.chapter($0)) })))
            return mapping(pairs)
        }
    }

    private static func parseFacts(_ node: Node?) -> [Fact] {
        node?.mapping?.compactMap { pair in
            guard let key = pair.key.string, let value = pair.value.string else { return nil }
            return Fact(key, value)
        } ?? []
    }

    private static func factsNode(_ facts: [Fact]) -> Node? {
        let clean = facts.filter { !$0.key.isEmpty && !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !clean.isEmpty else { return nil }
        return Node(clean.map { (Node($0.key, Tag(.str), .doubleQuoted), Node($0.value, Tag(.str), .doubleQuoted)) })
    }

    static func mapping(_ pairs: [(String, Node)]) -> Node {
        Node(pairs.map { (Node($0.0), $0.1) })
    }

    /// Block style, unlimited line width, real umlauts.
    static func emit(_ node: Node) -> String {
        (try? Yams.serialize(node: node, width: -1, allowUnicode: true, sequenceStyle: .block, mappingStyle: .block)) ?? ""
    }
}
