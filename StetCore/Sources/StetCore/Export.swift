import Foundation
import Yams

// MARK: - Formats and options

public enum ExportFormat: String, CaseIterable, Identifiable {
    case pdfManuscript, pdfBook, epub, docx, odt, markdown

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .pdfManuscript: "PDF – Manuskript"
        case .pdfBook: "PDF – Buch"
        case .epub: "ePUB"
        case .docx: "Word (.docx)"
        case .odt: "OpenDocument (.odt)"
        case .markdown: "Markdown (zusammengeführt)"
        }
    }

    public var detail: String {
        switch self {
        case .pdfManuscript: "A4, Times 12 pt, großer Zeilenabstand, Kopfzeile mit Name, Titel und Seite – zum Ausdrucken und Anmerken."
        case .pdfBook: "Buchsatz 13,5 × 21 cm, Blocksatz mit Silbentrennung, Kolumnentitel, Kapitel auf rechten Seiten."
        case .epub: "E-Book mit Inhaltsverzeichnis, Cover und deinem Stylesheet."
        case .docx: "Für Word und LibreOffice; Kommentare können als Word-Kommentare mit."
        case .odt: "Für LibreOffice und andere Textverarbeitungen."
        case .markdown: "Alle Szenen in einer Datei, mit Kapitelüberschriften."
        }
    }

    public var fileExtension: String {
        switch self {
        case .pdfManuscript, .pdfBook: "pdf"
        case .epub: "epub"
        case .docx: "docx"
        case .odt: "odt"
        case .markdown: "md"
        }
    }

    /// Short name for the export tag (`export/2026-11-20-pdf-manuskript`).
    var tagName: String {
        switch self {
        case .pdfManuscript: "pdf-manuskript"
        case .pdfBook: "pdf-buch"
        case .epub: "epub"
        case .docx: "docx"
        case .odt: "odt"
        case .markdown: "markdown"
        }
    }

    var needsTypst: Bool { self == .pdfManuscript || self == .pdfBook }
    var needsPandoc: Bool { self != .markdown }
    public var supportsWordComments: Bool { self == .docx || self == .odt }
}

public enum ExportQuotes: String, CaseIterable, Identifiable {
    case de, guillemets, en, keep
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .de: "„Deutsch“"
        case .guillemets: "»Buch«"
        case .en: "“English”"
        case .keep: "unverändert"
        }
    }
}

public struct ExportOptions: Equatable {
    public var format: ExportFormat
    public var quotes: ExportQuotes
    /// docx/odt: carry comments and TODOs along as comments of the word processor.
    public var commentsAsAnnotations = false
    /// Show scene titles as small headings.
    public var sceneTitles = false

    public init(format: ExportFormat, quotes: ExportQuotes = .de) {
        self.format = format
        self.quotes = quotes
    }
}

/// Which version an export shows.
public struct ExportStamp: Equatable {
    public var commit: String
    public var date: Date
    public var versionName: String
    public var words: Int

    public var shortCommit: String { String(commit.prefix(7)) }

    public var dateText: String {
        date.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "de_DE")))
    }

    public var line: String {
        let version = versionName == "Hauptfassung" ? "" : " (\(versionName))"
        return "Fassung \(shortCommit)\(version) vom \(dateText)"
    }
}

// MARK: - Typography

public enum Typography {
    struct Marks { let dOpen, dClose, sOpen, sClose: Character }

    static func marks(_ quotes: ExportQuotes) -> Marks? {
        switch quotes {
        case .de: Marks(dOpen: "„", dClose: "“", sOpen: "‚", sClose: "‘")
        case .guillemets: Marks(dOpen: "»", dClose: "«", sOpen: "›", sClose: "‹")
        case .en: Marks(dOpen: "“", dClose: "”", sOpen: "‘", sClose: "’")
        case .keep: nil
        }
    }

    /// Typographic quotes (straight and already curly ones in the target style), apostrophes,
    /// dashes between spaces and ellipses — the same rules as typing in the editor.
    public static func apply(_ text: String, quotes: ExportQuotes) -> String {
        guard let m = marks(quotes) else { return text }
        var out = ""
        out.reserveCapacity(text.utf8.count)
        var paragraphOpenSingle = false
        var previous: Character?
        let chars = Array(text)
        var i = 0
        func isOpening(_ p: Character?) -> Bool {
            guard let p else { return true }
            return p.isWhitespace || "([{–—-/*_".contains(p) || p == m.dOpen || p == m.sOpen
        }
        while i < chars.count {
            let c = chars[i]
            if c == "\n" { paragraphOpenSingle = false }
            switch c {
            case "\"":
                out.append(isOpening(previous) ? m.dOpen : m.dClose)
            case "'":
                if let p = previous, p.isLetter || p.isNumber {
                    if paragraphOpenSingle && quotes != .en {
                        out.append(m.sClose)
                        paragraphOpenSingle = false
                    } else {
                        out.append("’")
                    }
                } else if isOpening(previous) {
                    out.append(m.sOpen)
                    paragraphOpenSingle = true
                } else {
                    out.append(m.sClose)
                    paragraphOpenSingle = false
                }
            case "." where i + 2 < chars.count && chars[i + 1] == "." && chars[i + 2] == ".":
                out.append("…")
                i += 2
            case "-" where i + 1 < chars.count && chars[i + 1] == "-" && (i + 2 >= chars.count || chars[i + 2] != "-")
                && (previous == nil || previous!.isWhitespace) && (i + 2 >= chars.count || chars[i + 2].isWhitespace):
                out.append("–")
                i += 1
            default:
                out.append(c)
            }
            previous = out.last
            i += 1
        }
        return out
    }
}

// MARK: - Combined Markdown

/// Builds the one Markdown document an export starts from: metadata, parts/chapters as
/// headings, scenes with scene breaks, comments removed (or turned into word-processor comments).
public enum CombinedMarkdown {
    public enum Target: Equatable { case typst, html, wordProcessor, markdown }

    public static func target(for format: ExportFormat) -> Target {
        switch format {
        case .pdfManuscript, .pdfBook: .typst
        case .epub: .html
        case .docx, .odt: .wordProcessor
        case .markdown: .markdown
        }
    }

    public static func build(_ book: Book, options: ExportOptions, stamp: ExportStamp, extra: [String: String] = [:]) -> String {
        let target = target(for: options.format)
        var blocks: [String] = [metadata(book.manifest, options: options, stamp: stamp, extra: extra)]
        var commentID = 0
        let hasParts = book.manifest.structure.contains { if case .part = $0 { return true } else { return false } }

        func chapterBlocks(_ chapter: Chapter, level: Int) {
            blocks.append(String(repeating: "#", count: level) + " " + escapeHeading(chapter.title))
            var first = true
            for id in chapter.sceneIDs {
                guard let scene = try? book.readScene(id) else { continue }
                let body = scene.body.trimmingCharacters(in: .whitespacesAndNewlines)
                if body.isEmpty && scene.title == nil { continue }
                if !first { blocks.append(sceneBreak(target, format: options.format)) }
                first = false
                if options.sceneTitles, let title = scene.title {
                    blocks.append(String(repeating: "#", count: level + 1) + " " + escapeHeading(title) + " {.unnumbered .scene-title}")
                }
                // Typography first: the comment spans added afterwards carry attributes in straight quotes.
                let text = Typography.apply(body, quotes: options.quotes)
                blocks.append(options.commentsAsAnnotations && target == .wordProcessor
                    ? annotations(text, author: book.manifest.authors.first ?? "Stet", nextID: &commentID)
                    : TextStats.stripComments(text))
            }
        }

        for node in book.manifest.structure {
            switch node {
            case .chapter(let chapter):
                chapterBlocks(chapter, level: hasParts ? 2 : 1)
            case .part(let part):
                blocks.append("# " + escapeHeading(part.title) + " {.part}")
                for chapter in part.chapters { chapterBlocks(chapter, level: 2) }
            }
        }
        if target == .html {
            blocks.append("# Über diese Ausgabe {.unnumbered .colophon}")
            blocks.append(stamp.line + ". Gesetzt mit Stet.")
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    static func metadata(_ manifest: Manifest, options: ExportOptions, stamp: ExportStamp, extra: [String: String] = [:]) -> String {
        // Always quoted: "1.530" or a title like "1984" must stay text, not become numbers.
        func Node(_ value: String) -> Yams.Node { Yams.Node(value, Tag(.str), .doubleQuoted) }
        func Node(_ values: [Yams.Node]) -> Yams.Node { Yams.Node(values) }
        let parts = manifest.language.split(separator: "-")
        var pairs: [(Yams.Node, Yams.Node)] = [
            ("title", Node(manifest.title)),
            ("author", Node(manifest.authors.map { Node($0) })),
            ("lang", Node(manifest.language)),
            ("typst-lang", Node(String(parts.first ?? "de").lowercased())),
            ("stet-version", Node(stamp.shortCommit)),
            ("stet-version-line", Node(stamp.line)),
            ("stet-date", Node(stamp.dateText)),
            ("stet-words", Node(stamp.words.formatted(.number.locale(Locale(identifier: "de_DE"))))),
            ("stet-year", Node(String(Calendar.current.component(.year, from: stamp.date)))),
        ]
        if parts.count > 1 { pairs.append(("typst-region", Node(String(parts[1]).uppercased()))) }
        if options.quotes == .keep { pairs.append(("stet-keep-quotes", Node("true"))) }
        if options.format == .docx || options.format == .odt { pairs.append(("date", Node(stamp.line))) }
        if options.format == .epub { pairs.append(("description", Node(stamp.line))) }
        for (key, value) in extra.sorted(by: { $0.key < $1.key }) { pairs.append((Yams.Node(key), Node(value))) }
        return "---\n" + Manifest.emit(Yams.Node(pairs)) + "---"
    }

    static func sceneBreak(_ target: Target, format: ExportFormat) -> String {
        switch target {
        case .typst: "```{=typst}\n#scenebreak()\n```"
        case .html: "```{=html}\n<p class=\"scene-break\">⁂</p>\n```"
        case .wordProcessor: "::: {custom-style=\"Szenenwechsel\"}\n\\#\n:::"
        case .markdown: "* * *"
        }
    }

    static func escapeHeading(_ text: String) -> String {
        text.replacingOccurrences(of: "{", with: "\\{").replacingOccurrences(of: "#", with: "\\#")
    }

    /// CriticMarkup → Pandoc's comment spans, which the docx/odt writers turn into real comments.
    static func annotations(_ text: String, author fallback: String, nextID: inout Int) -> String {
        let pattern = try! NSRegularExpression(pattern: #"\{==([^\n]*?)==\}\{>>([^\n]*?)<<\}|\{>>([^\n]*?)<<\}"#)
        var result = ""
        var last = text.startIndex
        let date = ISO8601DateFormatter().string(from: Date())
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[last..<range.lowerBound]
            func group(_ i: Int) -> String? { Range(match.range(at: i), in: text).map { String(text[$0]) } }
            let highlighted = group(1) ?? ""
            var comment = (group(2) ?? group(3) ?? "").trimmingCharacters(in: .whitespaces)
            var author = fallback
            if let at = comment.firstMatch(of: #/^@([^:]{1,40}):\s*/#) {
                author = String(at.1)
                comment = String(comment[at.range.upperBound...])
            }
            let id = nextID
            nextID += 1
            let escapedComment = comment.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            let escapedAuthor = author.replacingOccurrences(of: "\"", with: "'")
            result += "[\(escapedComment)]{.comment-start id=\"\(id)\" author=\"\(escapedAuthor)\" date=\"\(date)\"}"
            result += highlighted
            result += "[]{.comment-end id=\"\(id)\"}"
            last = range.upperBound
        }
        result += text[last...]
        return TextStats.stripComments(result)
    }
}
