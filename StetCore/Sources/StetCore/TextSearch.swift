import Foundation

/// Plain text search for the find bar: no patterns, no whole-word rules, just the text.
public enum TextSearch {
    /// Every occurrence of `query` in `text`, as UTF-16 ranges (what the editor counts in),
    /// without overlaps. Without `caseSensitive` case doesn't matter ("mara" finds "Mara");
    /// accents always do ("Bar" doesn't find "Bär"). Composed and decomposed umlauts count as
    /// the same letter.
    public static func ranges(of query: String, in text: String, caseSensitive: Bool) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let haystack = text as NSString
        let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var result: [NSRange] = []
        var start = 0
        while start < haystack.length {
            let found = haystack.range(of: query, options: options, range: NSRange(location: start, length: haystack.length - start))
            guard found.location != NSNotFound, found.length > 0 else { break }
            result.append(found)
            start = found.location + found.length
        }
        return result
    }

    /// `text` with every exact occurrence of `query` (case counts) replaced, and how many there were.
    public static func replacingAll(_ query: String, with replacement: String, in text: String) -> (text: String, count: Int) {
        let found = ranges(of: query, in: text, caseSensitive: true)
        guard !found.isEmpty else { return (text, 0) }
        let result = NSMutableString(string: text)
        for range in found.reversed() { result.replaceCharacters(in: range, with: replacement) }
        return (result as String, found.count)
    }
}
