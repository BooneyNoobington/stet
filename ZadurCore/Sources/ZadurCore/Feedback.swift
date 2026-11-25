import Foundation
import Yams

/// A comment someone made in a Word document (imported from a returned .docx).
public struct WordComment: Equatable, Identifiable {
    public var author: String
    public var text: String
    /// The passage the comment was attached to.
    public var anchor: String
    /// Already placed as a comment in the manuscript.
    public var placed: Bool
    public var id: String { author + "|" + anchor + "|" + text }

    public init(author: String, text: String, anchor: String, placed: Bool = false) {
        self.author = author
        self.text = text
        self.anchor = anchor
        self.placed = placed
    }
}

/// One piece of feedback in the book's `feedback/` folder: who, when, on which version, the text,
/// attachments (e.g. a photo of a marked-up printout) and comments imported from Word.
public struct FeedbackEntry: Identifiable, Equatable {
    public static let folder = "feedback"
    public static let attachmentsFolder = "feedback/attachments"

    public let id: String
    public var from: String
    public var received: Date
    /// The export mark or milestone (tag) this feedback is about.
    public var refersTo: String?
    public var isDone = false
    public var text: String
    public var attachments: [String] = []
    public var wordComments: [WordComment] = []
    /// Front-matter keys Zadur doesn't know (another program's): kept as they are.
    public var unknown: [Manifest.UnknownKey] = []
    static let knownKeys: Set<String> = ["from", "received", "refersTo", "status", "attachments", "wordComments"]

    public var path: String { "\(Self.folder)/\(id).md" }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    func serialized() -> String {
        func str(_ s: String) -> Node { Node(s, Tag(.str), .doubleQuoted) }
        var pairs: [(Node, Node)] = [
            ("from", str(from)),
            ("received", Node(Self.dayFormatter.string(from: received))),
        ]
        if let refersTo { pairs.append(("refersTo", str(refersTo))) }
        pairs.append(("status", Node(isDone ? "done" : "open")))
        if !attachments.isEmpty { pairs.append(("attachments", Node(attachments.map(str)))) }
        if !wordComments.isEmpty {
            pairs.append(("wordComments", Node(wordComments.map { c in
                Manifest.mapping([("author", str(c.author)), ("anchor", str(c.anchor)), ("text", str(c.text)), ("placed", Node(c.placed ? "true" : "false"))])
            })))
        }
        for extra in unknown { pairs.append((Node(extra.key), extra.value)) }
        return "---\n" + Manifest.emit(Node(pairs)) + "---\n" + text
    }

    static func parse(id: String, text: String) -> FeedbackEntry? {
        guard let (_, yaml, body) = SceneFile.splitFrontMatter(text),
              let map = (try? Yams.compose(yaml: yaml))?.mapping
        else { return nil }
        var entry = FeedbackEntry(
            id: id,
            from: map["from"]?.string ?? "",
            received: map["received"]?.string.flatMap(dayFormatter.date(from:)) ?? .distantPast,
            refersTo: map["refersTo"]?.string,
            text: body
        )
        entry.isDone = map["status"]?.string == "done"
        entry.attachments = map["attachments"]?.sequence?.compactMap(\.string) ?? []
        entry.wordComments = map["wordComments"]?.sequence?.compactMap { node in
            guard let m = node.mapping else { return nil }
            return WordComment(author: m["author"]?.string ?? "", text: m["text"]?.string ?? "",
                               anchor: m["anchor"]?.string ?? "", placed: m["placed"]?.string == "true")
        } ?? []
        entry.unknown = map.compactMap { pair in
            guard let key = pair.key.string, !knownKeys.contains(key) else { return nil }
            return Manifest.UnknownKey(key: key, value: pair.value)
        }
        return entry
    }
}

extension Book {
    private var feedbackURL: URL { url.appendingPathComponent(FeedbackEntry.folder) }

    /// Open entries first, newest first.
    public func feedbackEntries() -> [FeedbackEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: feedbackURL.path)) ?? []
        return files.filter { $0.hasSuffix(".md") }.compactMap { file -> FeedbackEntry? in
            guard let data = FileManager.default.contents(atPath: feedbackURL.appendingPathComponent(file).path) else { return nil }
            return FeedbackEntry.parse(id: String(file.dropLast(3)), text: String(decoding: data, as: UTF8.self))
        }
        .sorted { ($0.isDone ? 1 : 0, -$0.received.timeIntervalSince1970, $0.id) < ($1.isDone ? 1 : 0, -$1.received.timeIntervalSince1970, $1.id) }
    }

    public func saveFeedback(_ entry: FeedbackEntry) throws {
        try FileManager.default.createDirectory(at: feedbackURL, withIntermediateDirectories: true)
        try Data(entry.serialized().utf8).write(to: url.appendingPathComponent(entry.path), options: .atomic)
    }

    /// Creates an entry; attachments are copied into `feedback/attachments/`.
    @discardableResult
    public func addFeedback(from: String, received: Date = Date(), refersTo: String?, text: String,
                            attachments: [URL] = [], wordComments: [WordComment] = []) throws -> FeedbackEntry {
        let received = Calendar.current.startOfDay(for: received)  // entries store the day only
        let day = FeedbackEntry.dayFormatter.string(from: received)
        let id = "\(day)-\(Self.slug(from.isEmpty ? "Rueckmeldung" : from))-\(ZadurID.make())"
        var entry = FeedbackEntry(id: id, from: from, received: received, refersTo: refersTo, text: text)
        entry.wordComments = wordComments
        let folder = url.appendingPathComponent(FeedbackEntry.attachmentsFolder)
        for file in attachments {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = "\(id)-\(file.lastPathComponent)"
            try FileManager.default.copyItem(at: file, to: folder.appendingPathComponent(name))
            entry.attachments.append("\(FeedbackEntry.attachmentsFolder)/\(name)")
        }
        try saveFeedback(entry)
        return entry
    }

    /// Removes an entry and its attachments (they stay in the history).
    public func deleteFeedback(_ entry: FeedbackEntry) throws {
        let fm = FileManager.default
        for path in entry.attachments { try? fm.removeItem(at: url.appendingPathComponent(path)) }
        try? fm.removeItem(at: url.appendingPathComponent(entry.path))
    }

    /// Reads the comments of a returned Word document: author, text and the passage each is attached to.
    public static func wordComments(in docx: URL) async throws -> [WordComment] {
        guard Exporter.tool("pandoc") != nil else { throw ExportError.missingTools(["pandoc"]) }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("zadur-docx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        try FileManager.default.copyItem(at: try Exporter.resource("comments.lua"), to: work.appendingPathComponent("comments.lua"))
        try FileManager.default.copyItem(at: docx, to: work.appendingPathComponent("eingang.docx"))
        try await Exporter.run("pandoc", ["--from=docx", "--track-changes=all", "--to=comments.lua", "--output=kommentare.json", "eingang.docx"], in: work)
        let data = try Data(contentsOf: work.appendingPathComponent("kommentare.json"))
        let raw = (try JSONSerialization.jsonObject(with: data) as? [[String: String]]) ?? []
        return raw.map {
            WordComment(author: $0["author"] ?? "", text: $0["text"] ?? "", anchor: ($0["anchor"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        .filter { !$0.text.isEmpty }
    }

    /// The version of a scene as it was at `commit` (e.g. the version an export or feedback is about).
    public func version(ofScene id: String, at commit: String) async -> SceneVersion? {
        let path = Self.scenePath(id)
        guard await git.show(path, at: commit) != nil,
              let info = try? await git.log(commit, limit: 1).first
        else { return nil }
        return SceneVersion(commit: info, path: path, isSnapshot: false)
    }
}
