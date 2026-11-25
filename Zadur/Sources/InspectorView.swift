import ZadurCore
import SwiftUI

struct InspectorView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case scene = "Details"
        case history = "Verlauf"
        case notes = "Notizen"
        case feedback = "Feedback"
        var id: String { rawValue }
    }

    @ObservedObject var session: BookSession
    @Binding var tab: Tab

    /// Wide enough for the German tab names and the details' labels.
    static let minWidth: CGFloat = 356
    static let idealWidth: CGFloat = 370

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            Group {
                switch tab {
                case .scene: DetailsForm(session: session)
                case .history: HistoryList(session: session)
                case .notes: NotesList(session: session)
                case .feedback: FeedbackPanel(session: session)
                }
            }
            // Every tab fills the rest of the column. Otherwise a short one (no notes or feedback
            // yet) was centred together with the tabs, and the tabs jumped to the middle.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        // A fixed ideal width: otherwise the column follows its content, which gets wider while
        // a text field has the focus and narrower again whenever the book's file changes, so
        // the window shook while typing chapter or book details.
        .frame(minWidth: Self.minWidth, idealWidth: Self.idealWidth, maxWidth: .infinity)
    }
}

// MARK: - Details

private struct DetailsForm: View {
    @ObservedObject var session: BookSession
    @State private var addingFact = false
    @State private var newFactKey = ""

    var body: some View {
        Form {
            if let scene = session.currentScene {
                Section("Szene") {
                    TextField("Titel", text: Binding(
                        get: { scene.title ?? "" },
                        set: { value in session.updateCurrentScene { $0.title = value } }
                    ), prompt: Text(TextStats.opening(of: scene.body)))
                    Picker("Status", selection: Binding(
                        get: { scene.status },
                        set: { value in session.updateCurrentScene { $0.status = value } }
                    )) {
                        Text("–").tag(SceneStatus?.none)
                        ForEach(SceneStatus.allCases) { Text($0.label).tag(SceneStatus?.some($0)) }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Zusammenfassung").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: Binding(
                            get: { scene.synopsis ?? "" },
                            set: { value in session.updateCurrentScene { $0.synopsis = value } }
                        ))
                        .font(.body)
                        .frame(minHeight: 70)
                        .scrollContentBackground(.hidden)
                    }
                }
                Section("Fakten") {
                    ForEach(session.factRows(for: scene)) { fact in
                        HStack {
                            TextField(fact.key, text: Binding(
                                get: { fact.value },
                                set: { session.setFact(fact.key, to: $0) }
                            ), prompt: Text(session.inheritedFact(fact.key, forScene: scene.id) ?? "–"))
                            .help(session.inheritedFact(fact.key, forScene: scene.id).map { "Leer gelassen gilt „\($0)“ vom Kapitel oder Teil." } ?? "")
                            if let entry = session.wikiEntry(for: fact) {
                                Button { AppModel.shared.openWiki(entry.id) } label: { Image(systemName: "text.book.closed") }
                                    .buttonStyle(.borderless)
                                    .help("„\(entry.title)“ im Wiki öffnen")
                            }
                        }
                    }
                    Button("Feld hinzufügen …") { addingFact = true }
                        .controlSize(.small)
                }
                .alert("Neues Feld für diese Szene", isPresented: $addingFact) {
                    TextField("Name", text: $newFactKey)
                    Button("Hinzufügen") {
                        let key = newFactKey.trimmingCharacters(in: .whitespaces)
                        if !key.isEmpty { session.setFact(key, to: "…") }
                        newFactKey = ""
                    }
                    Button("Abbrechen", role: .cancel) { newFactKey = "" }
                } message: {
                    Text("Felder für alle Szenen legst du unten beim Buch fest.")
                }
                if let chapter = session.manifest.chapter(containing: scene.id) {
                    Section {
                        TextField("Titel", text: Binding(
                            get: { chapter.title },
                            set: { session.renameChapter(chapter.id, to: $0) }
                        ))
                        LabeledContent("Szenen", value: "\(chapter.sceneIDs.count)")
                        GroupFacts(fields: session.manifest.sceneFactFields, facts: chapter.facts) { key, value in
                            session.setChapterFact(chapter.id, key, to: value)
                        }
                    } header: {
                        Text("Kapitel")
                    } footer: {
                        Text("Fakten des Kapitels gelten für alle seine Szenen, die selbst keine haben.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let part = session.manifest.part(containingChapter: chapter.id) {
                        Section("Teil „\(part.title)“") {
                            GroupFacts(fields: session.manifest.sceneFactFields, facts: part.facts) { key, value in
                                session.setPartFact(part.id, key, to: value)
                            }
                        }
                    }
                }
            }
            Section("Buch") {
                TextField("Titel", text: Binding(
                    get: { session.manifest.title },
                    set: { value in session.updateBook { $0.title = value } }
                ))
                TextField("Autor:in", text: Binding(
                    get: { session.manifest.authors.joined(separator: ", ") },
                    set: { value in
                        session.updateBook {
                            $0.authors = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        }
                    }
                ))
                TextField("Sprache", text: Binding(
                    get: { session.manifest.language },
                    set: { value in session.updateBook { $0.language = value } }
                ))
                Picker("Anführungszeichen", selection: Binding(
                    get: { session.manifest.quoteStyle },
                    set: { session.setQuoteStyle($0) }
                )) {
                    ForEach(QuoteStyle.allCases) { Text($0.label).tag($0) }
                }
                .help("Getippte \" und ' werden zu diesen Zeichen, und Exporte setzen sie ebenso. Vorhandene gleicht „Buch > Anführungszeichen angleichen …“ an.")
                LabeledContent("Titelbild") { CoverControl(session: session) }
                LabeledContent("Wörter", value: session.totalWords.formatted())
                TextField("Fakten-Felder", text: Binding(
                    get: { session.manifest.sceneFactFields.joined(separator: ", ") },
                    set: { value in
                        session.updateBook {
                            $0.sceneFactFields = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        }
                    }
                ))
                .help("Die Felder, die jede Szene anbietet, durch Kommas getrennt – z. B. Datum, Uhrzeit, Ort, Perspektive, Wetter.")
                LabeledContent("Backups") {
                    HStack {
                        Text(session.backupSummary)
                            .lineLimit(1)
                            .foregroundStyle(session.backupWarning == nil ? Color.primary : Color.orange)
                            .help(session.backupWarning ?? session.backupSummary)
                        Button("Einstellen …") { session.sheet = .backup }
                            .controlSize(.small)
                    }
                }
                LabeledContent("Server") {
                    HStack {
                        Text(session.serverURL.map(shortServer) ?? "–")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(session.serverURL ?? "Kein Server eingerichtet")
                        Button(session.isConnected ? "Ändern …" : "Einrichten …") { session.sheet = .server }
                            .controlSize(.small)
                    }
                }
                ProofRow(session: session)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - History

private struct HistoryList: View {
    @ObservedObject var session: BookSession

    var body: some View {
        Group {
            if session.history.isEmpty {
                ContentUnavailableView(
                    session.isLoadingHistory ? "Lädt …" : "Noch keine Versionen",
                    systemImage: "clock",
                    description: Text("⌘S sichert eine Version des ganzen Buchs.")
                )
            } else {
                List(session.history, selection: Binding(
                    get: { session.comparison?.version.id },
                    set: { id in
                        guard let version = session.history.first(where: { $0.id == id }) else {
                            session.comparison = nil
                            return
                        }
                        Task { await session.compare(with: version) }
                    }
                )) { version in
                    HistoryRow(session: session, version: version, milestone: session.milestone(at: version.commit.hash)).tag(version.id)
                        .contextMenu {
                            if !version.isSnapshot {
                                Button("Nachweis für diese Version …") { session.saveProof(for: version.commit.hash) }
                                Button("Zeitstempel für diese Version holen") { Task { await session.stampNow(version.commit.hash) } }
                                    .disabled(!session.proofs.timestampsOn || !session.versionStamps(version.commit.hash).isEmpty)
                            }
                        }
                }
                .listStyle(.inset)
            }
        }
    }
}

private struct HistoryRow: View {
    let session: BookSession
    let version: Book.SceneVersion
    let milestone: Milestone?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(version.commit.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.callout.weight(.medium))
                if version.isSnapshot {
                    Text("Schnappschuss")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                if !version.isSnapshot { ProofBadges(session: session, commit: version.commit.hash) }
                if let delta = version.commit.trailers["Words-Delta"], delta != "0" {
                    Text(delta).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if let milestone {
                if milestone.isExport {
                    Label(milestone.name, systemImage: "square.and.arrow.up")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Label(milestone.name, systemImage: "flag.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.purple)
                }
            }
            if let note = version.commit.note {
                Text(note).font(.callout)
            }
            if !version.isSnapshot {
                Text(version.commit.subject)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Comparison (shown over the editor)

struct ComparisonView: View {
    @ObservedObject var session: BookSession
    let comparison: BookSession.Comparison

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fassung vom \(comparison.version.commit.date.formatted(date: .long, time: .shortened))")
                        .font(.headline)
                    Text("Bis heute: \(comparison.summary.insertedWords.formatted()) Wörter dazu, \(comparison.summary.removedWords.formatted()) Wörter weg")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Diese Fassung wiederherstellen") { Task { await session.restore(comparison) } }
                Button("Schließen") { session.comparison = nil }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
            Divider()
            ScrollView {
                Text(attributed)
                    .font(.system(size: 17, design: .serif))
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: 640, alignment: .leading)
                    .padding(.vertical, 40)
                    .padding(.horizontal, 32)
                    .frame(maxWidth: .infinity)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// Removed text struck through in red, inserted text highlighted in green.
    private var attributed: AttributedString {
        var result = AttributedString()
        for segment in comparison.segments {
            var piece = AttributedString(segment.text)
            switch segment.kind {
            case .same:
                break
            case .inserted:
                piece.backgroundColor = .green.opacity(0.22)
            case .removed:
                piece.foregroundColor = .red.opacity(0.85)
                piece.strikethroughStyle = .single
            }
            result += piece
        }
        return result
    }
}

/// "git@git.example.org:name/buch.git" → "git.example.org: name/buch"
private func shortServer(_ url: String) -> String {
    var text = url
    for prefix in ["ssh://", "https://", "http://"] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
    if let at = text.firstIndex(of: "@") { text = String(text[text.index(after: at)...]) }
    if text.hasSuffix(".git") { text.removeLast(4) }
    return text
}

/// Facts of a chapter or part: one row per field of the book.
private struct GroupFacts: View {
    let fields: [String]
    let facts: [Fact]
    let set: (String, String) -> Void

    var body: some View {
        ForEach(fields + facts.map(\.key).filter { !fields.contains($0) }, id: \.self) { key in
            TextField(key, text: Binding(
                get: { facts.first { $0.key == key }?.value ?? "" },
                set: { set(key, $0) }
            ), prompt: Text("–"))
        }
    }
}
