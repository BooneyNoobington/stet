import StetCore
import SwiftUI

/// The wiki window: entries by kind on the left, the entry on the right.
struct WikiWindow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if let session = model.session {
                WikiBrowser(session: session, model: model)
            } else {
                ContentUnavailableView("Kein Buch geöffnet", systemImage: "books.vertical",
                                       description: Text("Das Wiki gehört zu einem Buch. Öffne zuerst ein Buch."))
            }
        }
        .frame(minWidth: 680, minHeight: 460)
    }
}

private struct WikiBrowser: View {
    @ObservedObject var session: BookSession
    @ObservedObject var model: AppModel
    @State private var search = ""

    var body: some View {
        NavigationSplitView {
            List(selection: $model.wikiSelection) {
                ForEach(WikiKind.allCases) { kind in
                    let entries = filtered.filter { $0.kind == kind }
                    if !entries.isEmpty {
                        Section(kind.plural) {
                            ForEach(entries) { entry in
                                Text(entry.title).tag(entry.id)
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Suchen")
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
            .toolbar {
                Menu {
                    Button("Wiki aus anderem Buch übernehmen …") { session.chooseWikiToImport() }
                    Button("Wiki exportieren …") { session.exportWiki() }
                        .disabled(session.wiki.isEmpty)
                } label: {
                    Label("Übernehmen und exportieren", systemImage: "square.and.arrow.up.on.square")
                }
                .help("Das Wiki in ein anderes Buch mitnehmen, z. B. in eine Fortsetzung")
                Menu {
                    ForEach(WikiKind.allCases) { kind in
                        Button(kind.newLabel) {
                            if let entry = session.createWiki(title: kind == .note ? "Neue Notiz" : "Neu", kind: kind) {
                                model.wikiSelection = entry.id
                            }
                        }
                    }
                } label: {
                    Label("Neu", systemImage: "plus")
                }
            }
        } detail: {
            if let id = model.wikiSelection, let entry = session.wiki.first(where: { $0.id == id }) {
                WikiEntryEditor(session: session, model: model, entry: entry).id(entry.id)
            } else {
                ContentUnavailableView {
                    Label(session.wiki.isEmpty ? "Noch kein Wiki" : "Kein Eintrag ausgewählt", systemImage: "text.book.closed")
                } description: {
                    Text("Figuren, Orte, Begriffe: Ihre Namen werden im Text dezent unterstrichen, beim Überfahren erscheinen ihre Fakten. Tipp: Namen im Text markieren und ⌃⌘W, oder im Text rechtsklicken.")
                } actions: {
                    if session.wiki.isEmpty {
                        Button("Wiki aus einem anderen Buch übernehmen …") { session.chooseWikiToImport() }
                    }
                }
            }
        }
        .navigationTitle("Wiki – \(session.manifest.title)")
        .alert("Wiki", isPresented: Binding(get: { session.wikiNotice != nil }, set: { if !$0 { session.wikiNotice = nil } })) {
            Button("OK") { session.wikiNotice = nil }
        } message: {
            Text(session.wikiNotice ?? "")
        }
        .onAppear { session.loadWiki() }
    }

    private var filtered: [WikiEntry] {
        let term = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !term.isEmpty else { return session.wiki }
        return session.wiki.filter { entry in
            entry.names.contains { $0.lowercased().contains(term) } || entry.body.lowercased().contains(term)
        }
    }
}

private struct WikiEntryEditor: View {
    @ObservedObject var session: BookSession
    @ObservedObject var model: AppModel
    @State private var draft: WikiEntry
    @State private var aliasText: String
    @State private var notMeantText: String
    @State private var saveTask: Task<Void, Never>?
    @State private var confirmDelete = false

    init(session: BookSession, model: AppModel, entry: WikiEntry) {
        self.session = session
        self.model = model
        _draft = State(initialValue: entry)
        _aliasText = State(initialValue: entry.aliases.joined(separator: ", "))
        _notMeantText = State(initialValue: entry.notMeant.joined(separator: ", "))
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.title)
                    .font(.title3)
                Picker("Art", selection: $draft.kind) {
                    ForEach(WikiKind.allCases) { Text($0.label).tag($0) }
                }
                TextField("Andere Namen", text: $aliasText, prompt: Text("z. B. Mara, die Kapitänin"))
                    .help("Durch Kommas getrennt. Alle Namen werden im Text erkannt, auch mit Genitiv-s („Maras“), Apostroph („Andreas’“) oder -ens („Hansens“).")
                TextField("Nicht gemeint", text: $notMeantText, prompt: Text("z. B. bei Andrea: Andreas"))
                    .help("Wörter, die wie dieser Name aussehen, aber jemand anderen meinen – etwa „Andreas“, wenn es neben Andrea auch einen Andreas gibt, der (noch) keinen eigenen Eintrag hat. Durch Kommas getrennt.")
            }
            Section {
                ForEach($draft.facts) { $fact in
                    HStack {
                        TextField("", text: $fact.key, prompt: Text("Feld")).frame(width: 110)
                        TextField("", text: $fact.value, prompt: Text("Wert"))
                        Button { draft.facts.removeAll { $0.id == fact.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Fakt hinzufügen") {
                    var key = "Neu"
                    var n = 2
                    while draft.facts.contains(where: { $0.key == key }) { key = "Neu \(n)"; n += 1 }
                    draft.facts.append(Fact(key, ""))
                }
            } header: {
                Text("Fakten")
            } footer: {
                Text("Erscheinen beim Überfahren des Namens im Text. Mit [[Name]] verweist ein Wert auf einen anderen Eintrag.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Kommt vor in") {
                let appearances = session.appearances(of: draft)
                if appearances.isEmpty {
                    Text("In keiner Szene.").foregroundStyle(.secondary)
                } else {
                    ForEach(appearances, id: \.sceneID) { item in
                        Button {
                            Task { await session.jump(to: draft, in: item.sceneID) }
                        } label: {
                            HStack {
                                Text(item.title)
                                Spacer()
                                Text("\(item.count)×").foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Section("Notizen") {
                TextEditor(text: $draft.body)
                    .font(.system(size: 14, design: .serif))
                    .frame(minHeight: 180)
            }
            Section {
                Button("Eintrag löschen …", role: .destructive) { confirmDelete = true }
            }
        }
        .formStyle(.grouped)
        .onChange(of: draft) { scheduleSave() }
        .onChange(of: aliasText) {
            draft.aliases = aliasText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        .onChange(of: notMeantText) {
            draft.notMeant = notMeantText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        .onDisappear { saveNow() }
        .confirmationDialog("„\(draft.title)“ löschen?", isPresented: $confirmDelete) {
            Button("Löschen", role: .destructive) {
                saveTask?.cancel()
                session.deleteWiki(draft)
                model.wikiSelection = nil
            }
        } message: {
            Text("Der Eintrag verschwindet aus dem Wiki; im Verlauf bleibt er erhalten.")
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    private func saveNow() {
        guard session.wiki.first(where: { $0.id == draft.id }) != draft,
              session.wiki.contains(where: { $0.id == draft.id })
        else { return }
        session.saveWiki(draft)
    }
}

extension WikiKind {
    var newLabel: String {
        switch self {
        case .character: "Neue Figur"
        case .place: "Neuer Ort"
        case .term: "Neuer Begriff"
        case .note: "Neue Notiz"
        }
    }
}
