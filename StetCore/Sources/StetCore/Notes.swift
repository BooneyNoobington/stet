import Foundation

/// A comment or TODO somewhere in the book (CriticMarkup in a scene).
/// Positions are UTF-16 offsets into the scene's prose, as the editor (CodeMirror) counts them.
public struct NoteItem: Identifiable, Equatable {
    public enum Kind: Equatable { case comment, todo }

    public let sceneID: String
    public let sceneTitle: String
    public let kind: Kind
    public let author: String?
    public let text: String
    /// The highlighted passage, for `{==…==}{>>…<<}`.
    public let highlighted: String?
    /// The whole construct.
    public let from: Int
    public let to: Int

    public var id: String { "\(sceneID)@\(from)" }
}

public enum CriticMarkup {
    static let pattern = try! NSRegularExpression(pattern: #"\{==([^\n]*?)==\}\{>>([^\n]*?)<<\}|\{>>([^\n]*?)<<\}"#)

    /// All comments and TODOs in a scene's prose.
    public static func notes(in body: String, sceneID: String, sceneTitle: String) -> [NoteItem] {
        let ns = body as NSString
        return pattern.matches(in: body, range: NSRange(location: 0, length: ns.length)).map { match in
            func group(_ i: Int) -> String? {
                let range = match.range(at: i)
                return range.location == NSNotFound ? nil : ns.substring(with: range)
            }
            var text = (group(2) ?? group(3) ?? "").trimmingCharacters(in: .whitespaces)
            var kind = NoteItem.Kind.comment
            var author: String?
            if let todo = text.range(of: #"^TODO\b[:\s]*"#, options: [.regularExpression, .caseInsensitive]) {
                kind = .todo
                text = String(text[todo.upperBound...])
            } else if let at = text.range(of: #"^@[^:\n]{1,40}:\s*"#, options: .regularExpression) {
                author = String(text[at]).dropFirst().split(separator: ":").first.map { $0.trimmingCharacters(in: .whitespaces) }
                text = String(text[at.upperBound...])
            }
            return NoteItem(
                sceneID: sceneID, sceneTitle: sceneTitle, kind: kind, author: author, text: text,
                highlighted: group(1), from: match.range.location, to: match.range.location + match.range.length
            )
        }
    }

    /// The prose with one note removed; a highlighted passage stays as plain text.
    public static func removing(_ note: NoteItem, from body: String) -> String? {
        let ns = body as NSString
        guard note.to <= ns.length else { return nil }
        let range = NSRange(location: note.from, length: note.to - note.from)
        let current = ns.substring(with: range)
        guard current.hasPrefix("{") && current.hasSuffix("}") else { return nil }  // text changed meanwhile
        return ns.replacingCharacters(in: range, with: note.highlighted ?? "")
    }

    /// `{>>@Name: text<<}`, or with a highlighted passage `{==passage==}{>>@Name: text<<}`.
    public static func comment(_ text: String, author: String?, around passage: String? = nil) -> String {
        let clean = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "<<}", with: "<< }")
        let content = (author.map { "@\($0): " } ?? "") + clean
        if let passage, !passage.isEmpty { return "{==\(passage)==}{>>\(content)<<}" }
        return "{>>\(content)<<}"
    }
}

extension Book {
    /// All comments and TODOs, in reading order.
    public func notes() -> [NoteItem] {
        manifest.sceneIDs.flatMap { id -> [NoteItem] in
            guard let scene = try? readScene(id) else { return [] }
            return CriticMarkup.notes(in: scene.body, sceneID: id, sceneTitle: scene.displayTitle)
        }
    }

    /// Removes a note from its scene file (for scenes not open in the editor).
    public func removeNote(_ note: NoteItem) throws {
        var scene = try readScene(note.sceneID)
        guard let body = CriticMarkup.removing(note, from: scene.body) else { return }
        scene.body = body
        try writeScene(scene)
    }
}

// MARK: - Finding a passage again

/// Finds a passage (e.g. text a Word comment was attached to) in today's prose, ignoring the
/// differences typography and Markdown make: straight vs. typographic quotes, dashes, ellipses,
/// emphasis marks, CriticMarkup, line breaks and runs of spaces.
public enum PassageFinder {
    /// Normalised characters plus, for each, its UTF-16 offset in the original text.
    static func normalise(_ text: String, skipMarkup: Bool) -> (chars: [Character], offsets: [Int]) {
        var chars: [Character] = [], offsets: [Int] = []
        let ns = text as NSString
        var hidden = IndexSet()
        if skipMarkup {
            // CriticMarkup comments are not part of the visible text; highlight delimiters neither.
            let comment = try! NSRegularExpression(pattern: #"\{>>[^\n]*?<<\}|\{==|==\}"#)
            for m in comment.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                hidden.insert(integersIn: m.range.location..<(m.range.location + m.range.length))
            }
        }
        var offset = 0
        var lastWasSpace = true
        for character in text {
            let length = String(character).utf16.count
            defer { offset += length }
            if hidden.contains(offset) { continue }
            var c = character
            switch c {
            case "„", "“", "”", "»", "«", "\"": c = "\""
            case "‚", "‘", "’", "›", "‹", "'": c = "'"
            case "–", "—": c = "-"
            case "*", "_": if skipMarkup { continue }
            default: break
            }
            if c == "…" {
                for _ in 0..<3 { chars.append("."); offsets.append(offset) }
                lastWasSpace = false
                continue
            }
            if c.isWhitespace {
                if lastWasSpace { continue }
                c = " "
                lastWasSpace = true
            } else {
                lastWasSpace = false
            }
            chars.append(Character(c.lowercased()))
            offsets.append(offset)
        }
        // "--" in the prose stands for a dash: treat as one.
        var i = 0
        while i + 1 < chars.count {
            if chars[i] == "-" && chars[i + 1] == "-" { chars.remove(at: i + 1); offsets.remove(at: i + 1) } else { i += 1 }
        }
        return (chars, offsets)
    }

    /// UTF-16 range of the first occurrence of `passage` in `text`, or nil.
    public static func find(_ passage: String, in text: String) -> Range<Int>? {
        let needle = normalise(passage, skipMarkup: false).chars
        let trimmed = Array(needle.drop(while: { $0 == " " }).reversed().drop(while: { $0 == " " }).reversed())
        guard trimmed.count >= 3 else { return nil }
        let (haystack, offsets) = normalise(text, skipMarkup: true)
        guard haystack.count >= trimmed.count else { return nil }
        outer: for start in 0...(haystack.count - trimmed.count) {
            for j in 0..<trimmed.count where haystack[start + j] != trimmed[j] { continue outer }
            let lastIndex = start + trimmed.count - 1
            let endOffset = offsets[lastIndex] + String(text.utf16Character(at: offsets[lastIndex])).utf16.count
            return offsets[start]..<endOffset
        }
        return nil
    }
}

private extension String {
    func utf16Character(at offset: Int) -> Character {
        let index = String.Index(utf16Offset: offset, in: self)
        return self[index]
    }
}

extension Book {
    /// Where a passage is today: scene and UTF-16 range in its prose.
    public func locate(_ passage: String) -> (sceneID: String, range: Range<Int>)? {
        for id in manifest.sceneIDs {
            guard let scene = try? readScene(id), let range = PassageFinder.find(passage, in: scene.body) else { continue }
            return (id, range)
        }
        return nil
    }
}
