import AppKit
import StetCore
import SwiftUI

/// Find and replace (⌘F) in the whole book, in reading order. Finding ignores case; replacing
/// only touches exact matches (case counts), so while the replace row is open the bar finds
/// only those. "Ersetzen" is undoable with ⌘Z; "Alle ersetzen" saves a snapshot first.
@MainActor
final class FindController: ObservableObject {
    struct Match: Equatable {
        let sceneID: String
        let range: NSRange
    }

    @Published var isVisible = false
    @Published var showsReplace = false {
        didSet { if oldValue != showsReplace { scheduleSearch(reveal: false) } }
    }
    @Published var query = "" {
        didSet { if oldValue != query { scheduleSearch(reveal: true) } }
    }
    @Published var replacement = ""
    @Published private(set) var matches: [Match] = []
    @Published private(set) var current: Int?
    /// Changes when the search field should get the keyboard focus.
    @Published private(set) var focusRequest = 0
    /// Set by the bar: whether its search field has the focus (it gets it back after a jump to
    /// another scene, which focuses the editor).
    var searchFieldHasFocus = false

    private weak var session: BookSession?
    private var searchTask: Task<Void, Never>?
    /// A search is scheduled but hasn't run yet.
    private var searchPending = false
    private var isJumping = false

    init(session: BookSession) {
        self.session = session
    }

    var sceneCount: Int { Set(matches.map(\.sceneID)).count }

    var status: String {
        guard !query.isEmpty else { return "" }
        if matches.isEmpty { return "Nicht gefunden" }
        if let current { return "\(current + 1) von \(matches.count)" }
        return matches.count == 1 ? "1 Treffer" : "\(matches.count) Treffer"
    }

    // MARK: Showing

    /// Opens the bar; a short selection in the text becomes the search.
    func show(replace: Bool = false) async {
        if replace { showsReplace = true }
        isVisible = true
        focusRequest += 1
        guard let session else { return }
        let selected = await session.editor.selectedText()
        if !selected.isEmpty, selected.count <= 100, !selected.contains(where: \.isNewline), selected != query {
            query = selected
        } else if !query.isEmpty {
            scheduleSearch(reveal: false, delay: .zero)
        }
    }

    func hide() async {
        isVisible = false
        searchTask?.cancel()
        matches = []
        current = nil
        await session?.editor.setSearchMatches([], current: nil)
        session?.editor.focus()
    }

    // MARK: Searching

    func scheduleSearch(reveal: Bool, delay: Duration = .milliseconds(120)) {
        searchTask?.cancel()
        guard isVisible else { return }
        searchPending = true
        searchTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.search(reveal: reveal)
        }
    }

    /// Searches now (for the self-tests).
    func searchNow() async { await search(reveal: false) }

    /// The scene's text changed: the highlights follow.
    func textChanged() {
        if isVisible, !query.isEmpty { scheduleSearch(reveal: false, delay: .milliseconds(300)) }
    }

    /// Another scene is shown: its matches get highlighted.
    func sceneChanged() async {
        if isVisible, !isJumping, !query.isEmpty { await search(reveal: false) }
    }

    /// Searches every scene; the current match becomes the first one at or after `from` (the
    /// cursor, by default) in the scene being shown.
    private func search(reveal: Bool, from: Int? = nil) async {
        guard let session else { return }
        searchPending = false
        let query = self.query
        guard isVisible, !query.isEmpty else {
            matches = []
            current = nil
            await session.editor.setSearchMatches([], current: nil)
            return
        }
        let caseSensitive = showsReplace
        var found: [Match] = []
        for id in session.manifest.sceneIDs + session.unplacedSceneIDs {
            let text = id == session.selectedSceneID
                ? ((try? await session.editor.text()) ?? "")
                : ((try? session.book.readScene(id).body) ?? "")
            found += TextSearch.ranges(of: query, in: text, caseSensitive: caseSensitive).map { Match(sceneID: id, range: $0) }
        }
        guard query == self.query, caseSensitive == showsReplace else { return }
        let cursor: Int
        if let from { cursor = from } else { cursor = await session.editor.selection().location }
        matches = found
        let here = found.indices.filter { found[$0].sceneID == session.selectedSceneID }
        current = here.first { found[$0].range.location >= cursor } ?? here.first
        await highlight()
        if reveal, let current { await session.editor.reveal(found[current].range) }
    }

    private func highlight() async {
        guard let session else { return }
        let here = matches.indices.filter { matches[$0].sceneID == session.selectedSceneID }
        await session.editor.setSearchMatches(here.map { matches[$0].range }, current: current.flatMap { here.firstIndex(of: $0) })
    }

    // MARK: Moving

    func next() async { await move(forward: true) }
    func previous() async { await move(forward: false) }

    private func move(forward: Bool) async {
        if !isVisible {
            await show()
            if query.isEmpty { return }
        }
        // A search still waiting (Enter right after typing) runs first.
        if searchPending {
            searchTask?.cancel()
            await search(reveal: false)
        }
        guard let session, !matches.isEmpty else {
            NSSound.beep()
            return
        }
        let index: Int
        if let current {
            index = (current + (forward ? 1 : matches.count - 1)) % matches.count
        } else {
            // Nothing in this scene: the next scene with a match, in reading order (and round).
            let order = session.manifest.sceneIDs + session.unplacedSceneIDs
            let here = order.firstIndex(of: session.selectedSceneID ?? "") ?? -1
            let position = { (match: Match) in order.firstIndex(of: match.sceneID) ?? 0 }
            if forward {
                index = matches.firstIndex { position($0) > here } ?? 0
            } else {
                index = matches.lastIndex { position($0) < here } ?? matches.count - 1
            }
        }
        await go(to: index)
    }

    private func go(to index: Int) async {
        guard let session, matches.indices.contains(index) else { return }
        let match = matches[index]
        // The scene was deleted meanwhile: search again instead of jumping into nothing.
        guard (session.manifest.sceneIDs + session.unplacedSceneIDs).contains(match.sceneID) else {
            await search(reveal: true)
            return
        }
        if match.sceneID != session.selectedSceneID {
            let refocus = searchFieldHasFocus
            isJumping = true
            await session.select(match.sceneID)
            isJumping = false
            if refocus { focusRequest += 1 }
        }
        current = index
        await highlight()
        await session.editor.reveal(match.range)
    }

    // MARK: Replacing

    var canReplace: Bool { session?.adoption == nil }

    /// Replaces the current match (undoable) and moves on to the next one.
    func replaceCurrent() async {
        guard let session, showsReplace, canReplace, let current, matches.indices.contains(current),
              matches[current].sceneID == session.selectedSceneID
        else {
            NSSound.beep()
            return
        }
        searchTask?.cancel()
        let range = matches[current].range
        try? await session.editor.replaceRange(from: range.location, to: range.location + range.length, with: replacement)
        // Go on after the new text (it may contain the search text itself).
        await search(reveal: true, from: range.location + (replacement as NSString).length)
    }

    /// Replaces every exact match in the book. The state before is saved as a snapshot (each
    /// scene's history can bring it back); in the scene being shown, ⌘Z undoes it too.
    func replaceAll() async {
        guard let session, showsReplace, canReplace, !query.isEmpty else { return }
        searchTask?.cancel()
        await search(reveal: false)
        guard !matches.isEmpty else { return }
        await session.persistAndSnapshot()
        let query = self.query
        var total = 0
        var scenes = 0
        var seen = Set<String>()
        for id in matches.map(\.sceneID) where seen.insert(id).inserted {
            if id == session.selectedSceneID {
                let ranges = matches.filter { $0.sceneID == id }.map(\.range)
                try? await session.editor.replaceRanges(ranges, with: replacement)
                total += ranges.count
                scenes += 1
            } else if var scene = try? session.book.readScene(id) {
                let result = TextSearch.replacingAll(query, with: replacement, in: scene.body)
                guard result.count > 0 else { continue }
                scene.body = result.text
                do {
                    _ = try session.book.writeScene(scene)
                    total += result.count
                    scenes += 1
                } catch {
                    session.errorMessage = "Eine Szene konnte nicht geändert werden: \(error.localizedDescription)"
                }
            }
        }
        await session.persist()
        session.sceneFilesChanged()
        session.showToast(.init(message: "\(total)-mal ersetzt, in \(scenes == 1 ? "einer Szene" : "\(scenes) Szenen"). Der Stand davor ist als Schnappschuss im Verlauf."))
        await search(reveal: false)
    }
}

// MARK: - The bar

/// Shows the find bar while it's open.
struct FindBarHost: View {
    @ObservedObject var find: FindController

    var body: some View {
        if find.isVisible { FindBar(find: find) }
    }
}

private struct FindBar: View {
    @ObservedObject var find: FindController
    @FocusState private var focus: Field?
    @State private var confirmReplaceAll = false

    enum Field { case query, replacement }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Im ganzen Buch suchen", text: $find.query)
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .query)
                        .onSubmit { Task { await find.next() } }
                    if !find.query.isEmpty {
                        Text(find.status)
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(find.matches.isEmpty ? Color.red : Color.secondary)
                            .fixedSize()
                        Button { find.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Suche leeren")
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                .frame(maxWidth: 380)

                ControlGroup {
                    Button { Task { await find.previous() } } label: { Image(systemName: "chevron.left") }
                        .help("Vorheriger Treffer (⇧⌘G)")
                    Button { Task { await find.next() } } label: { Image(systemName: "chevron.right") }
                        .help("Nächster Treffer, auch in den nächsten Szenen (⌘G oder Zeilenschalter)")
                }
                .fixedSize()
                .disabled(find.matches.isEmpty)

                Toggle("Ersetzen", isOn: $find.showsReplace)
                    .toggleStyle(.checkbox)
                    .help("Ersetzen: dann zählt Groß- und Kleinschreibung")
                Spacer(minLength: 0)
                Button("Fertig") { Task { await find.hide() } }
            }
            if find.showsReplace {
                HStack(spacing: 8) {
                    TextField("Ersetzen durch", text: $find.replacement)
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .replacement)
                        .frame(maxWidth: 380)
                        .onSubmit { Task { await find.replaceCurrent() } }
                    Button("Ersetzen") { Task { await find.replaceCurrent() } }
                        .disabled(find.current == nil || !find.canReplace)
                        .help("Ersetzt den markierten Treffer und springt zum nächsten (mit ⌘Z rückgängig)")
                    Button("Alle ersetzen …") { confirmReplaceAll = true }
                        .disabled(find.matches.isEmpty || !find.canReplace)
                    Text("Nur genau so Geschriebenes, mit Groß- und Kleinschreibung.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onExitCommand { Task { await find.hide() } }
        .onAppear { focus = .query }
        .onChange(of: find.focusRequest) { focus = .query }
        .onChange(of: focus) { find.searchFieldHasFocus = focus == .query }
        .confirmationDialog(replaceAllTitle, isPresented: $confirmReplaceAll) {
            Button(find.replacement.isEmpty ? "Alle löschen" : "Alle ersetzen", role: find.replacement.isEmpty ? .destructive : nil) {
                Task { await find.replaceAll() }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Vorher sichert Stet einen Schnappschuss: Im Verlauf jeder Szene lässt sich der alte Stand wiederherstellen.")
        }
    }

    private var replaceAllTitle: String {
        let places = find.matches.count == 1 ? "einer Stelle" : "\(find.matches.count) Stellen"
        let scenes = find.sceneCount == 1 ? "einer Szene" : "\(find.sceneCount) Szenen"
        return find.replacement.isEmpty
            ? "„\(find.query)“ an \(places) in \(scenes) löschen?"
            : "„\(find.query)“ an \(places) in \(scenes) durch „\(find.replacement)“ ersetzen?"
    }
}
