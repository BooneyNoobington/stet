import Foundation

/// A book's quotation marks: typed quotes become these, exports set them, and "Anführungszeichen
/// angleichen" turns the book's existing ones into them.
public enum QuoteStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case guillemets, de, en

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .guillemets: "»Buch« ›Zitat‹"
        case .de: "„Deutsch“ ‚Zitat‘"
        case .en: "“English” ‘quote’"
        }
    }

    /// Opening and closing marks, double and single.
    public var marks: (dOpen: Character, dClose: Character, sOpen: Character, sClose: Character) {
        let m = Typography.marks(self)
        return (m.dOpen, m.dClose, m.sOpen, m.sClose)
    }

    /// The double marks around an ellipsis, e.g. for "schon »…«".
    public var sample: String { "\(marks.dOpen)…\(marks.dClose)" }

    /// Chevrons for German books, as in most German novels; English quotes for English ones.
    public static func standard(forLanguage language: String) -> QuoteStyle {
        language.lowercased().hasPrefix("en") ? .en : .guillemets
    }
}

public enum Typography {
    struct Marks { let dOpen, dClose, sOpen, sClose: Character }

    static func marks(_ style: QuoteStyle) -> Marks {
        switch style {
        case .guillemets: Marks(dOpen: "»", dClose: "«", sOpen: "›", sClose: "‹")
        case .de: Marks(dOpen: "„", dClose: "“", sOpen: "‚", sClose: "‘")
        case .en: Marks(dOpen: "“", dClose: "”", sOpen: "‘", sClose: "’")
        }
    }

    static let doubleMarks: Set<Character> = ["\"", "„", "“", "”", "»", "«"]
    static let singleMarks: Set<Character> = ["'", "‚", "‘", "’", "›", "‹"]
    static let apostrophe: Character = "’"

    /// For exports: typographic quotes (see `quotes(_:style:)`), dashes between spaces and
    /// ellipses — the same rules as typing in the editor.
    public static func apply(_ text: String, quotes: ExportQuotes) -> String {
        guard let style = quotes.style else { return text }
        return self.quotes(dashesAndEllipses(text), style: style)
    }

    /// Every quotation mark in one style: straight ones and typographic ones of any style. Whether
    /// a mark opens or closes depends on what comes before it, as when typing (emphasis stars
    /// don't count). A single mark is an apostrophe inside a word (geht's), after a word when no
    /// single quote is open (Andreas'), and at the start of a word when nothing closes it later
    /// in the paragraph ('n Abend). Changes only quotation marks, one character for another.
    public static func quotes(_ text: String, style: QuoteStyle) -> String {
        let m = marks(style)
        let chars = Array(text)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var singleOpen = false

        /// The character before `index` in `list`, skipping emphasis markers.
        func before(_ index: Int, in list: [Character]) -> Character? {
            var j = index - 1
            while j >= 0, list[j] == "*" || list[j] == "_" { j -= 1 }
            return j >= 0 ? list[j] : nil
        }
        func isWordCharacter(_ c: Character?) -> Bool { c.map { $0.isLetter || $0.isNumber } ?? false }
        func isOpeningContext(_ previous: Character?) -> Bool {
            guard let previous else { return true }
            return previous.isWhitespace || "([{–—-/".contains(previous)
        }
        /// After what's already set: a quote right after an opening one opens too.
        func opens(_ previous: Character?) -> Bool {
            isOpeningContext(previous) || previous == m.dOpen || previous == m.sOpen
        }
        /// Whether a single quote opened at `index` is closed later in its paragraph: the next
        /// single mark that isn't an apostrophe inside a word decides.
        func closesLater(after index: Int) -> Bool {
            var k = index + 1
            while k < chars.count, chars[k] != "\n" {
                if singleMarks.contains(chars[k]) {
                    let next = k + 1 < chars.count ? chars[k + 1] : nil
                    if !(isWordCharacter(chars[k - 1]) && isWordCharacter(next)) {
                        let previous = before(k, in: chars)
                        // After a quote mark, it opens if a word follows ("'Ja …).
                        let opening = isOpeningContext(previous) || previous.map(doubleMarks.contains) == true && isWordCharacter(next)
                        return !opening
                    }
                }
                k += 1
            }
            return false
        }

        for (i, c) in chars.enumerated() {
            if c == "\n" { singleOpen = false }
            if doubleMarks.contains(c) {
                out.append(opens(before(out.count, in: out)) ? m.dOpen : m.dClose)
            } else if singleMarks.contains(c) {
                let previous = before(out.count, in: out)
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                if isWordCharacter(out.last) && isWordCharacter(next) {
                    out.append(apostrophe)
                } else if opens(previous) {
                    if closesLater(after: i) {
                        out.append(m.sOpen)
                        singleOpen = true
                    } else {
                        out.append(apostrophe)
                    }
                } else if singleOpen {
                    out.append(m.sClose)
                    singleOpen = false
                } else if isWordCharacter(out.last) {
                    out.append(apostrophe)
                } else {
                    out.append(m.sClose)
                }
            } else {
                out.append(c)
            }
        }
        return String(out)
    }

    /// How many characters two texts of the same length differ in (quotes changed by `quotes`).
    public static func changes(from old: String, to new: String) -> Int {
        zip(old, new).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
    }

    /// `--` between spaces becomes a dash, `...` an ellipsis.
    static func dashesAndEllipses(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        out.reserveCapacity(text.utf8.count)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == ".", i + 2 < chars.count, chars[i + 1] == ".", chars[i + 2] == "." {
                out.append("…")
                i += 3
            } else if c == "-", i + 1 < chars.count, chars[i + 1] == "-", out.last?.isWhitespace ?? true,
                      i + 2 >= chars.count || chars[i + 2].isWhitespace
            {
                out.append("–")
                i += 2
            } else {
                out.append(c)
                i += 1
            }
        }
        return out
    }
}
