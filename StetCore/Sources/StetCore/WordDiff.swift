import Foundation

/// Word-level comparison of two texts, for showing what changed between versions.
public enum WordDiff {
    public struct Segment: Equatable {
        public enum Kind: Equatable { case same, inserted, removed }
        public var kind: Kind
        public var text: String

        public init(_ kind: Kind, _ text: String) {
            self.kind = kind
            self.text = text
        }
    }

    public struct Summary: Equatable {
        public var insertedWords = 0
        public var removedWords = 0
    }

    /// Splits text into words, whitespace runs and single punctuation characters.
    static func tokenize(_ text: String) -> [Substring] {
        enum Class { case word, space, other }
        func classify(_ c: Character) -> Class {
            if c.isLetter || c.isNumber { return .word }
            if c.isWhitespace { return .space }
            return .other
        }
        var tokens: [Substring] = []
        var start = text.startIndex
        var current: Class?
        for index in text.indices {
            let kind = classify(text[index])
            if let current, kind == current, kind != .other { continue }
            if index != start { tokens.append(text[start..<index]) }
            start = index
            current = kind
        }
        if start != text.endIndex { tokens.append(text[start...]) }
        return tokens
    }

    public static func diff(old: String, new: String) -> [Segment] {
        let a = tokenize(old), b = tokenize(new)
        let changes = b.difference(from: a)
        var removedOffsets = Set<Int>(), insertedOffsets = Set<Int>()
        for change in changes {
            switch change {
            case .remove(let offset, _, _): removedOffsets.insert(offset)
            case .insert(let offset, _, _): insertedOffsets.insert(offset)
            }
        }

        var segments: [Segment] = []
        func append(_ kind: Segment.Kind, _ token: Substring) {
            if let last = segments.last, last.kind == kind {
                segments[segments.count - 1].text += token
            } else {
                segments.append(Segment(kind, String(token)))
            }
        }
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removedOffsets.contains(i) {
                append(.removed, a[i]); i += 1
            } else if j < b.count, insertedOffsets.contains(j) {
                append(.inserted, b[j]); j += 1
            } else {
                append(.same, a[i]); i += 1; j += 1
            }
        }
        return segments
    }

    public static func summary(of segments: [Segment]) -> Summary {
        var summary = Summary()
        for segment in segments where segment.kind != .same {
            let words = TextStats.words(in: segment.text)
            if segment.kind == .inserted { summary.insertedWords += words } else { summary.removedWords += words }
        }
        return summary
    }
}
