import AppKit
import ZadurCore
import SwiftUI

/// macOS's spelling dictionaries for one open book. The book's own words and the wiki's names
/// count as right: they are this book's "ignored words" (a spell document of its own), so the
/// system-wide dictionary stays clean.
@MainActor
final class SpellingChecker {
    private let checker = NSSpellChecker.shared
    let tag = NSSpellChecker.uniqueSpellDocumentTag()
    private(set) var language: String

    init(language: String) {
        self.language = Self.dictionary(for: language)
    }

    func setLanguage(_ language: String) {
        self.language = Self.dictionary(for: language)
    }

    /// The installed dictionary for a book's language ("de" → "de", "de-AT" → "de_AT" or "de").
    static func dictionary(for language: String) -> String {
        let available = NSSpellChecker.shared.availableLanguages
        let wanted = language.replacingOccurrences(of: "-", with: "_")
        if available.contains(wanted) { return wanted }
        let base = wanted.split(separator: "_").first.map(String.init) ?? wanted
        return available.first { $0 == base } ?? available.first { $0.hasPrefix(base + "_") } ?? base
    }

    /// Words that count as right. Names also in their parts and with genitive s ("Maras").
    func setAllowed(_ words: [String]) {
        var allowed = Set<String>()
        for entry in words {
            allowed.insert(entry)
            for part in entry.components(separatedBy: CharacterSet.letters.union(.decimalDigits).inverted) where !part.isEmpty {
                allowed.insert(part)
                allowed.insert(part + "s")
                if let last = part.last, "sßxzSXZ".contains(last) { allowed.insert(part + "ens") }
            }
        }
        checker.setIgnoredWords(Array(allowed), inSpellDocumentWithTag: tag)
    }

    private static let comment = try! NSRegularExpression(pattern: #"\{>>.*?<<\}"#, options: [.dotMatchesLineSeparators])

    /// Misspelled words with their UTF-16 ranges; comments (`{>>…<<}`, often from others) are left out.
    func misspellings(in text: String) -> [(range: NSRange, word: String)] {
        let ns = text as NSString
        let comments = Self.comment.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
        var result: [(NSRange, String)] = []
        var start = 0
        while start < ns.length {
            let range = checker.checkSpelling(of: text, startingAt: start, language: language, wrap: false,
                                              inSpellDocumentWithTag: tag, wordCount: nil)
            guard range.location != NSNotFound, range.length > 0, range.location >= start else { break }
            if !comments.contains(where: { NSIntersectionRange($0, range).length > 0 }) {
                result.append((range, ns.substring(with: range)))
            }
            start = range.location + range.length
        }
        return result
    }

    func isMisspelled(_ word: String) -> Bool { !misspellings(in: word).isEmpty }

    private static let possessive = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])(\p{L}[\p{L}\p{N}]*)(['’])s(?![\p{L}\p{N}])"#)

    /// German books only: a known name with an English-style possessive ("Gabriela's" → "Gabrielas",
    /// "Andreas's" → "Andreas’"). "Andrea's" stays if there is also an Andreas: that apostrophe is
    /// the accepted way to make clear which name is meant.
    func apostropheHints(in text: String, names: Set<String>, allowed: Set<String>) -> [SpellingHint] {
        guard language.hasPrefix("de") else { return [] }
        let ns = text as NSString
        let comments = Self.comment.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
        return Self.possessive.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let word = ns.substring(with: match.range)
            let base = ns.substring(with: match.range(at: 1))
            let apostrophe = ns.substring(with: match.range(at: 2))
            guard names.contains(base), !names.contains(base + "s"), !allowed.contains(word),
                  !comments.contains(where: { NSIntersectionRange($0, match.range).length > 0 })
            else { return nil }
            if let last = base.last, "sßxzSXZ".contains(last) {
                return SpellingHint(range: match.range, word: word, suggestion: base + apostrophe,
                                    reason: "Bei Namen auf s, ß, x oder z steht im Genitiv nur der Apostroph.")
            }
            return SpellingHint(range: match.range, word: word, suggestion: base + "s",
                                reason: "Im Deutschen steht beim Genitiv kein Apostroph.")
        }
    }

    func guesses(for word: String) -> [String] {
        checker.guesses(forWordRange: NSRange(location: 0, length: (word as NSString).length), in: word,
                        language: language, inSpellDocumentWithTag: tag) ?? []
    }

    /// Into the user's macOS dictionary (all apps).
    func learn(_ word: String) {
        checker.learnWord(word)
    }

    func close() {
        checker.closeSpellDocument(withTag: tag)
    }
}

/// Not a spelling mistake, a usage one: the English-style possessive apostrophe in German.
struct SpellingHint: Equatable {
    let range: NSRange
    let word: String
    let suggestion: String
    let reason: String
}

/// A word the dictionary doesn't know (or a hint), everywhere it occurs in the book.
struct SpellingIssue: Identifiable, Equatable {
    struct Occurrence: Identifiable, Equatable {
        let sceneID: String
        let range: NSRange
        let before: String
        let after: String
        var id: String { "\(sceneID)-\(range.location)" }
    }

    let word: String
    var occurrences: [Occurrence]
    /// For hints: the replacement and why.
    var suggestion: String?
    var reason: String?
    var id: String { word }
}

extension BookSession {
    // MARK: While writing

    /// Single words of wiki names and the book's words: the bases the apostrophe hint looks at.
    var spellingNames: Set<String> {
        Set((wiki.flatMap(\.names) + (manifest.words ?? [])).flatMap { $0.components(separatedBy: CharacterSet.letters.union(.decimalDigits).inverted) }
            .filter { !$0.isEmpty })
    }

    /// Words the writer kept on purpose (book's list, "ignorieren").
    var keptWords: Set<String> { Set((manifest.words ?? []) + ignoredWords) }

    func hints(in text: String) -> [SpellingHint] {
        spelling?.apostropheHints(in: text, names: spellingNames, allowed: keptWords) ?? []
    }

    func refreshSpellingVocabulary() {
        guard let spelling else { return }
        spelling.setLanguage(manifest.language)
        spelling.setAllowed((manifest.words ?? []) + wiki.flatMap(\.names) + Array(ignoredWords))
        scheduleSpellCheck(after: .zero)
    }

    /// Checks the open scene a moment after typing stops (and right away after loading one).
    func scheduleSpellCheck(after delay: Duration = .milliseconds(700)) {
        spellCheckTask?.cancel()
        spellCheckTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.checkSpellingNow()
        }
    }

    @discardableResult
    func checkSpellingNow() async -> Int {
        guard let spelling, editor.isReady else { return 0 }
        guard editor.settings.checkSpelling, selectedSceneID != nil, let text = try? await editor.text() else {
            currentHints = []
            return await editor.setMisspellings([])
        }
        currentHints = hints(in: text)
        return await editor.setMisspellings(spelling.misspellings(in: text), hints: currentHints.map { ($0.range, $0.word) })
    }

    /// Right-click: suggestions for a misspelled word, then the wiki items.
    func menuItems(text: String, range: NSRange, wikiID: String?) -> [NSMenuItem] {
        let spellingItems = hintMenuItems(at: range) + spellingMenuItems(word: text, range: range)
        let wikiItems = contextMenuItems(text: text, wikiID: wikiID)
        let groups = [spellingItems, wikiItems, formatMenuItems(range: range)].filter { !$0.isEmpty }
        return groups.enumerated().flatMap { index, items in (index == 0 ? [] : [NSMenuItem.separator()]) + items }
    }

    func spellingMenuItems(word: String, range: NSRange) -> [NSMenuItem] {
        guard editor.settings.checkSpelling, let spelling, range.length > 0, !word.contains(where: \.isWhitespace),
              spelling.isMisspelled(word)
        else { return [] }
        var items: [NSMenuItem] = []
        let guesses = spelling.guesses(for: word).prefix(5)
        if guesses.isEmpty {
            items.append(NSMenuItem(title: "Keine Vorschläge", action: nil, keyEquivalent: ""))
        }
        let bold = NSFontManager.shared.convert(NSFont.menuFont(ofSize: 0), toHaveTrait: .boldFontMask)
        for guess in guesses {
            let item = ActionMenuItem(guess) { [weak self] in
                Task { await self?.replace(word, at: range, with: guess) }
            }
            item.attributedTitle = NSAttributedString(string: guess, attributes: [.font: bold])
            items.append(item)
        }
        items.append(.separator())
        items.append(ActionMenuItem("„\(word)“ für dieses Buch erlauben") { [weak self] in self?.allowWord(word) })
        items.append(ActionMenuItem("„\(word)“ ignorieren") { [weak self] in self?.ignoreWord(word) })
        return items
    }

    /// Right-click on "Gabriela's": the German form and why.
    func hintMenuItems(at range: NSRange) -> [NSMenuItem] {
        guard editor.settings.checkSpelling,
              let hint = currentHints.first(where: { NSLocationInRange(range.location, $0.range) || NSIntersectionRange($0.range, range).length > 0 })
        else { return [] }
        let bold = NSFontManager.shared.convert(NSFont.menuFont(ofSize: 0), toHaveTrait: .boldFontMask)
        let replace = ActionMenuItem(hint.suggestion) { [weak self] in
            Task { await self?.replace(hint.word, at: hint.range, with: hint.suggestion) }
        }
        replace.attributedTitle = NSAttributedString(string: hint.suggestion, attributes: [.font: bold])
        let why = NSMenuItem(title: hint.reason, action: nil, keyEquivalent: "")
        return [replace, why, .separator(), ActionMenuItem("„\(hint.word)“ so lassen") { [weak self] in self?.ignoreWord(hint.word) }]
    }

    /// Replaces a word in the open scene (one undoable edit), if it's still there.
    func replace(_ word: String, at range: NSRange, with replacement: String) async {
        guard let text = try? await editor.text(), NSMaxRange(range) <= (text as NSString).length,
              (text as NSString).substring(with: range) == word
        else { return }
        try? await editor.replaceRange(from: range.location, to: NSMaxRange(range), with: replacement)
    }

    // MARK: Word lists

    /// Into the book's word list: right in this book, on every Mac (it travels with the book).
    func allowWord(_ word: String) {
        changeStructure { try book.allowWord(word) }
        dropFromReview(word)
        refreshSpellingVocabulary()
    }

    /// Until the book is closed.
    func ignoreWord(_ word: String) {
        ignoredWords.insert(word)
        dropFromReview(word)
        refreshSpellingVocabulary()
    }

    /// Into macOS's dictionary (all apps on this Mac).
    func learnWord(_ word: String) {
        spelling?.learn(word)
        dropFromReview(word)
        refreshSpellingVocabulary()
    }

    func disallowWord(_ word: String) {
        changeStructure { try book.disallowWord(word) }
        refreshSpellingVocabulary()
    }

    private func dropFromReview(_ word: String) {
        spellingIssues.removeAll { $0.word == word }
    }

    // MARK: The whole book

    /// Every unknown word of the book, most frequent first.
    func reviewSpelling() async {
        guard let spelling, !isReviewingSpelling else { return }
        isReviewingSpelling = true
        defer { isReviewingSpelling = false }
        await persist()
        var issues: [String: SpellingIssue] = [:]
        for id in manifest.sceneIDs {
            guard let body = try? book.readScene(id).body else { continue }
            let ns = body as NSString
            for (range, word) in spelling.misspellings(in: body) {
                let occurrence = SpellingIssue.Occurrence(sceneID: id, range: range,
                                                          before: Self.context(ns, before: range), after: Self.context(ns, after: range))
                issues[word, default: SpellingIssue(word: word, occurrences: [])].occurrences.append(occurrence)
            }
            for hint in hints(in: body) {
                let occurrence = SpellingIssue.Occurrence(sceneID: id, range: hint.range,
                                                          before: Self.context(ns, before: hint.range), after: Self.context(ns, after: hint.range))
                issues[hint.word, default: SpellingIssue(word: hint.word, occurrences: [], suggestion: hint.suggestion, reason: hint.reason)]
                    .occurrences.append(occurrence)
            }
            await Task.yield()
        }
        spellingIssues = issues.values.sorted {
            $0.occurrences.count != $1.occurrences.count
                ? $0.occurrences.count > $1.occurrences.count
                : $0.word.localizedCaseInsensitiveCompare($1.word) == .orderedAscending
        }
        spellingReviewed = Date()
    }

    private static func context(_ text: NSString, before range: NSRange) -> String {
        let start = max(0, range.location - 40)
        let piece = text.substring(with: NSRange(location: start, length: range.location - start))
        let line = piece.components(separatedBy: "\n").last ?? piece
        return (start > 0 && line == piece ? "…" : "") + line
    }

    private static func context(_ text: NSString, after range: NSRange) -> String {
        let end = min(text.length, NSMaxRange(range) + 40)
        let piece = text.substring(with: NSRange(location: NSMaxRange(range), length: end - NSMaxRange(range)))
        let line = piece.components(separatedBy: "\n").first ?? piece
        return line + (end < text.length && line == piece ? "…" : "")
    }

    /// Opens the scene in the main window and selects the word.
    func show(_ occurrence: SpellingIssue.Occurrence, of issue: SpellingIssue) async {
        AppModel.shared.openWindowAction?(id: "main")
        await select(occurrence.sceneID)
        guard let text = try? await editor.text(), NSMaxRange(occurrence.range) <= (text as NSString).length,
              (text as NSString).substring(with: occurrence.range) == issue.word
        else { return }
        await editor.select(from: occurrence.range.location, to: NSMaxRange(occurrence.range))
    }

    /// Replaces the word everywhere it was found. The open scene changes in the editor (undoable),
    /// the others on disk (the previous text stays in the history).
    func replaceEverywhere(_ issue: SpellingIssue, with replacement: String) async {
        await persist()
        var replaced = 0
        for (sceneID, occurrences) in Dictionary(grouping: issue.occurrences, by: \.sceneID) {
            let backwards = occurrences.sorted { $0.range.location > $1.range.location }
            if sceneID == selectedSceneID {
                guard let text = try? await editor.text() else { continue }
                let ns = text as NSString
                for occurrence in backwards where NSMaxRange(occurrence.range) <= ns.length && ns.substring(with: occurrence.range) == issue.word {
                    try? await editor.replaceRange(from: occurrence.range.location, to: NSMaxRange(occurrence.range), with: replacement)
                    replaced += 1
                }
            } else if var scene = try? book.readScene(sceneID) {
                let body = NSMutableString(string: scene.body)
                for occurrence in backwards where NSMaxRange(occurrence.range) <= body.length && body.substring(with: occurrence.range) == issue.word {
                    body.replaceCharacters(in: occurrence.range, with: replacement)
                    replaced += 1
                }
                scene.body = body as String
                changeStructure { try book.writeScene(scene) }
            }
        }
        await persist()
        dropFromReview(issue.word)
        showToast(Toast(message: "„\(issue.word)“ an \(replaced) \(replaced == 1 ? "Stelle" : "Stellen") durch „\(replacement)“ ersetzt"))
    }
}

// MARK: - The spelling window

struct SpellingWindow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if let session = model.session {
                SpellingReview(session: session)
            } else {
                ContentUnavailableView("Kein Buch geöffnet", systemImage: "textformat.abc",
                                       description: Text("Die Rechtschreibung prüft Zadur für ein Buch. Öffne zuerst ein Buch."))
            }
        }
        .frame(minWidth: 640, minHeight: 440)
    }
}

private struct SpellingReview: View {
    @ObservedObject var session: BookSession
    @State private var selection: String?

    var body: some View {
        NavigationSplitView {
            List(session.spellingIssues, selection: $selection) { issue in
                HStack {
                    Text(issue.word)
                    if issue.reason != nil {
                        Image(systemName: "info.circle").foregroundStyle(.secondary).help(issue.reason ?? "")
                    }
                    Spacer()
                    Text("\(issue.occurrences.count)×").foregroundStyle(.secondary).monospacedDigit()
                }
                .tag(issue.word)
            }
            .overlay {
                if session.spellingIssues.isEmpty {
                    if session.isReviewingSpelling {
                        ProgressView("Prüft das ganze Buch …")
                    } else {
                        ContentUnavailableView("Keine unbekannten Wörter", systemImage: "checkmark.circle",
                                               description: Text("Namen aus dem Wiki und die Wörter dieses Buchs gelten als richtig."))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .toolbar {
                Button {
                    Task { await session.reviewSpelling() }
                } label: {
                    Label("Neu prüfen", systemImage: "arrow.clockwise")
                }
                .help("Das ganze Buch neu prüfen")
                .disabled(session.isReviewingSpelling)
            }
        } detail: {
            if let issue = session.spellingIssues.first(where: { $0.word == selection }) {
                SpellingIssueDetail(session: session, issue: issue).id(issue.word)
            } else {
                ContentUnavailableView("Kein Wort ausgewählt", systemImage: "textformat.abc",
                                       description: Text("Links stehen alle Wörter, die das Wörterbuch nicht kennt – die häufigsten oben."))
            }
        }
        .navigationTitle("Rechtschreibung – \(session.manifest.title)")
        .task {
            if session.spellingReviewed == nil { await session.reviewSpelling() }
            if selection == nil { selection = session.spellingIssues.first?.word }
        }
        .onChange(of: session.spellingIssues) {
            if !session.spellingIssues.contains(where: { $0.word == selection }) { selection = session.spellingIssues.first?.word }
        }
    }
}

private struct SpellingIssueDetail: View {
    @ObservedObject var session: BookSession
    let issue: SpellingIssue
    @State private var guesses: [String] = []

    var body: some View {
        Form {
            Section {
                Text(issue.word).font(.title2)
                Text(issue.occurrences.count == 1 ? "Kommt einmal vor." : "Kommt \(issue.occurrences.count)-mal vor.")
                    .foregroundStyle(.secondary)
                if let reason = issue.reason {
                    Label(reason, systemImage: "info.circle").foregroundStyle(.secondary)
                }
            }
            Section("Vorschläge") {
                if guesses.isEmpty {
                    Text("Keine Vorschläge").foregroundStyle(.secondary)
                }
                ForEach(guesses, id: \.self) { guess in
                    HStack {
                        Text(guess)
                        Spacer()
                        Button(issue.occurrences.count == 1 ? "Ersetzen" : "Überall ersetzen") {
                            Task { await session.replaceEverywhere(issue, with: guess) }
                        }
                    }
                }
            }
            Section {
                HStack {
                    Button("Für dieses Buch erlauben") { session.allowWord(issue.word) }
                        .help("Gilt in diesem Buch als richtig – auf allen Macs, das Wort reist mit dem Buch.")
                    Button("Ignorieren") { session.ignoreWord(issue.word) }
                        .help("Bis das Buch geschlossen wird.")
                    Spacer()
                    Button("Ins macOS-Wörterbuch") { session.learnWord(issue.word) }
                        .help("Gilt dann in allen Programmen dieses Macs als richtig.")
                }
            } footer: {
                Text("Namen aus dem Wiki gelten automatisch als richtig, auch mit Genitiv-s.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Fundstellen") {
                ForEach(issue.occurrences) { occurrence in
                    Button {
                        Task { await session.show(occurrence, of: issue) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.titles[occurrence.sceneID] ?? occurrence.sceneID)
                                .font(.caption).foregroundStyle(.secondary)
                            Text(occurrence.before) + Text(issue.word).bold().foregroundColor(.red) + Text(occurrence.after)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            if let suggestion = issue.suggestion {
                guesses = [suggestion]
            } else {
                guesses = Array((session.spelling?.guesses(for: issue.word) ?? []).prefix(6))
            }
        }
    }
}
