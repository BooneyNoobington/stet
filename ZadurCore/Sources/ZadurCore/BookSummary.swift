import Foundation

/// A read-only overview of a book for Quick Look: metadata, structure, word counts and the
/// opening. Reads only files (no git, no writes), so it works inside sandboxed extensions.
public struct BookSummary: Equatable {
    public struct SceneInfo: Equatable {
        public var title: String
        public var words: Int
    }

    public struct ChapterInfo: Equatable {
        public var title: String
        public var part: String?
        public var scenes: [SceneInfo]
        public var words: Int { scenes.reduce(0) { $0 + $1.words } }
    }

    public var title: String
    public var authors: [String]
    public var language: String
    public var chapters: [ChapterInfo]
    public var coverURL: URL?
    /// Prose of the first non-empty scene.
    public var opening: String

    public var totalWords: Int { chapters.reduce(0) { $0 + $1.words } }
    public var sceneCount: Int { chapters.reduce(0) { $0 + $1.scenes.count } }

    public static func read(_ bookURL: URL) throws -> BookSummary {
        let yaml = try String(contentsOf: bookURL.appendingPathComponent(Manifest.fileName), encoding: .utf8)
        let manifest = try Manifest.parse(yaml)

        func scene(_ id: String) -> SceneFile? {
            guard let data = FileManager.default.contents(atPath: Book.sceneURL(id, in: bookURL).path) else { return nil }
            return SceneFile.parse(id: id, text: String(decoding: data, as: UTF8.self))
        }

        var opening = ""
        func info(_ chapter: Chapter, part: String?) -> ChapterInfo {
            let scenes = chapter.sceneIDs.compactMap(scene)
            if opening.isEmpty, let first = scenes.first(where: { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                opening = first.body
            }
            return ChapterInfo(
                title: chapter.title,
                part: part,
                scenes: scenes.map { SceneInfo(title: $0.displayTitle, words: TextStats.words(in: $0.body)) }
            )
        }

        let chapters = manifest.structure.flatMap { node -> [ChapterInfo] in
            switch node {
            case .chapter(let chapter): [info(chapter, part: nil)]
            case .part(let part): part.chapters.map { info($0, part: part.title) }
            }
        }
        let cover = manifest.cover.map { bookURL.appendingPathComponent($0) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }

        return BookSummary(
            title: manifest.title,
            authors: manifest.authors,
            language: manifest.language,
            chapters: chapters,
            coverURL: cover,
            opening: opening
        )
    }
}

/// Just enough Markdown → HTML for a preview: paragraphs, emphasis, headings, scene breaks.
/// Comments are removed. (Real exports go through Pandoc.)
public enum MarkdownSnippet {
    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let strong = try! NSRegularExpression(pattern: #"\*\*(?=\S)(.+?)(?<=\S)\*\*"#)
    private static let emphasis = try! NSRegularExpression(pattern: #"(?<![*\w])[*_](?=\S)(.+?)(?<=\S)[*_](?![*\w])"#)
    private static let sceneBreak = try! NSRegularExpression(pattern: #"^\s*([-*_])(\s*\1){2,}\s*$"#)

    /// The first paragraphs of `markdown`, up to roughly `wordLimit` words (whole paragraphs only).
    public static func html(_ markdown: String, wordLimit: Int = .max) -> String {
        let prose = TextStats.stripComments(markdown)
        var html: [String] = []
        var words = 0
        for block in prose.components(separatedBy: "\n\n") {
            let text = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if words >= wordLimit { break }
            words += TextStats.words(in: text)

            let range = NSRange(text.startIndex..., in: text)
            if sceneBreak.firstMatch(in: text, range: range) != nil {
                html.append("<p class=\"break\">⁂</p>")
            } else if let heading = text.firstIndex(where: { $0 != "#" }), heading != text.startIndex,
                      text[heading] == " ", text.distance(from: text.startIndex, to: heading) <= 6
            {
                html.append("<h3>\(inline(String(text[text.index(after: heading)...])))</h3>")
            } else {
                html.append("<p>\(inline(text.replacingOccurrences(of: "\n", with: " ")))</p>")
            }
        }
        return html.joined(separator: "\n")
    }

    static func inline(_ text: String) -> String {
        var result = escape(text)
        result = strong.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "<strong>$1</strong>")
        result = emphasis.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "<em>$1</em>")
        return result
    }
}

/// The Quick Look preview page for a book.
public enum BookPreviewHTML {
    public static func render(_ summary: BookSummary, coverSource: String? = nil, openingWords: Int = 350) -> String {
        let e = MarkdownSnippet.escape
        let authors = summary.authors.isEmpty ? "" : "<p class=\"authors\">\(e(summary.authors.joined(separator: ", ")))</p>"
        let stats = "\(summary.chapters.count) Kapitel · \(summary.sceneCount) Szenen · \(summary.totalWords.formatted(.number.locale(Locale(identifier: "de_DE")))) Wörter"
        let cover = coverSource.map { "<img class=\"cover\" src=\"\(e($0))\" alt=\"\">" } ?? ""

        var toc: [String] = []
        var currentPart: String?
        for chapter in summary.chapters {
            if let part = chapter.part, part != currentPart {
                toc.append("<li class=\"part\">\(e(part))</li>")
            }
            currentPart = chapter.part
            let scenes = chapter.scenes.count > 1
                ? "<ol>" + chapter.scenes.map { "<li>\(e($0.title))</li>" }.joined() + "</ol>"
                : ""
            toc.append("<li><span class=\"chapter\">\(e(chapter.title))</span><span class=\"words\">\(chapter.words.formatted(.number.locale(Locale(identifier: "de_DE"))))</span>\(scenes)</li>")
        }

        let opening = MarkdownSnippet.html(summary.opening, wordLimit: openingWords)

        return """
        <!doctype html>
        <html lang="\(e(summary.language))">
        <head>
        <meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <style>
        :root { --bg: #fbfaf7; --text: #26231f; --muted: #8a847a; --rule: #e4ded3; --accent: #9a5b2a; }
        @media (prefers-color-scheme: dark) { :root { --bg: #1c1b19; --text: #e6e1d8; --muted: #8f897f; --rule: #34322e; --accent: #e0a46d; } }
        html { background: var(--bg); color: var(--text); }
        body { margin: 0; padding: 40px 48px 56px; font: 16px/1.6 "Iowan Old Style", "New York", ui-serif, Georgia, serif; }
        header { display: flex; gap: 28px; align-items: flex-end; padding-bottom: 24px; border-bottom: 1px solid var(--rule); }
        .cover { width: 150px; border-radius: 3px; box-shadow: 0 2px 10px rgba(0,0,0,.25); }
        h1 { font-weight: 500; font-size: 34px; line-height: 1.15; margin: 0 0 6px; }
        .authors { margin: 0 0 10px; font-size: 18px; }
        .stats { margin: 0; color: var(--muted); font: 13px -apple-system, system-ui, sans-serif; }
        main { display: grid; grid-template-columns: minmax(180px, 1fr) 2fr; gap: 40px; padding-top: 24px; }
        h2 { font: 600 11px -apple-system, system-ui, sans-serif; letter-spacing: .08em; text-transform: uppercase; color: var(--muted); margin: 0 0 12px; }
        nav ol { list-style: none; margin: 0; padding: 0; font-size: 15px; }
        nav > ol > li { margin-bottom: 10px; }
        nav li.part { font: 600 11px -apple-system, system-ui, sans-serif; letter-spacing: .08em; text-transform: uppercase; color: var(--accent); margin-top: 14px; }
        .chapter { font-weight: 600; }
        .words { float: right; color: var(--muted); font: 12px -apple-system, system-ui, sans-serif; font-variant-numeric: tabular-nums; }
        nav ol ol { margin-top: 3px; padding-left: 12px; color: var(--muted); font-size: 14px; }
        article p { margin: 0 0 .9em; hyphens: auto; }
        article p.break { text-align: center; color: var(--muted); }
        article .more { color: var(--muted); font-style: italic; }
        </style>
        </head>
        <body>
        <header>
        \(cover)
        <div>
        <h1>\(e(summary.title))</h1>
        \(authors)
        <p class="stats">\(stats)</p>
        </div>
        </header>
        <main>
        <nav><h2>Inhalt</h2><ol>\(toc.joined(separator: "\n"))</ol></nav>
        <article><h2>Anfang</h2>\(opening.isEmpty ? "<p class=\"more\">Noch kein Text.</p>" : opening + "\n<p class=\"more\">…</p>")</article>
        </main>
        </body>
        </html>
        """
    }
}
