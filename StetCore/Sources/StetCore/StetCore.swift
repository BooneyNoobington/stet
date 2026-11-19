import Foundation

/// Short random identifiers for scenes, chapters and parts (`7f3a9c`).
/// They never change, so file names and history stay stable when things are renamed or moved.
public enum StetID {
    private static let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")

    public static func make(prefix: String = "", avoiding existing: Set<String> = []) -> String {
        while true {
            let id = prefix + String((0..<6).map { _ in alphabet.randomElement()! })
            if !existing.contains(id) { return id }
        }
    }
}

/// Word counts and comment stripping (CriticMarkup comments don't count as words).
public enum TextStats {
    private static let comment = try! NSRegularExpression(pattern: #"\{>>[^\n]*?<<\}"#)
    private static let highlightDelimiters = try! NSRegularExpression(pattern: #"\{==|==\}"#)

    public static func stripComments(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let withoutComments = comment.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        let range2 = NSRange(withoutComments.startIndex..., in: withoutComments)
        return highlightDelimiters.stringByReplacingMatches(in: withoutComments, range: range2, withTemplate: "")
    }

    public static func words(in text: String) -> Int {
        let prose = stripComments(text)
        var count = 0
        prose.enumerateSubstrings(in: prose.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            count += 1
        }
        return count
    }

    /// The first few words of a text, for scenes without a title.
    public static func opening(of text: String, words limit: Int = 7) -> String {
        let prose = stripComments(text)
        var words: [String] = []
        prose.enumerateSubstrings(in: prose.startIndex..., options: .byWords) { word, _, _, stop in
            if let word { words.append(word) }
            if words.count >= limit { stop = true }
        }
        guard !words.isEmpty else { return "" }
        return words.joined(separator: " ") + "…"
    }
}
