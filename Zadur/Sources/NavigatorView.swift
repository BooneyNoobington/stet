import ZadurCore
import SwiftUI

/// The book's structure: parts (optional), chapters and scenes. Every chapter is a heading
/// with its scenes below, also when it has only one, so a new chapter looks like a chapter.
struct NavigatorView: View {
    @ObservedObject var session: BookSession
    @State private var renaming: Chapter?
    @State private var renameText = ""
    @State private var deleting: String?

    var body: some View {
        List(selection: Binding(get: { session.selectedSceneID }, set: { id in Task { await session.select(id) } })) {
            ForEach(Array(session.manifest.structure.enumerated()), id: \.offset) { _, node in
                switch node {
                case .chapter(let chapter):
                    chapterSection(chapter)
                case .part(let part):
                    Section {
                        EmptyView()
                    } header: {
                        Text(part.title.uppercased())
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                    ForEach(part.chapters) { chapterSection($0) }
                }
            }
            if !session.unplacedSceneIDs.isEmpty {
                Section("Nicht zugeordnet") {
                    ForEach(session.unplacedSceneIDs, id: \.self) { sceneRow($0) }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .alert("Kapitel umbenennen", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Titel", text: $renameText)
            Button("Umbenennen") {
                if let chapter = renaming { session.renameChapter(chapter.id, to: renameText) }
                renaming = nil
            }
            Button("Abbrechen", role: .cancel) { renaming = nil }
        }
        .confirmationDialog(
            "„\(deleting.flatMap { session.titles[$0] } ?? "")“ löschen?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button("Szene löschen", role: .destructive) {
                if let id = deleting { Task { await session.deleteScene(id) } }
                deleting = nil
            }
        } message: {
            Text("Die Szene verschwindet aus dem Buch. Alle gesicherten Versionen bleiben im Verlauf erhalten.")
        }
    }

    private func chapterSection(_ chapter: Chapter) -> some View {
        Section {
            ForEach(chapter.sceneIDs, id: \.self) { sceneRow($0, chapter: chapter) }
                .onMove { session.moveScenes(inChapter: chapter.id, from: $0, to: $1) }
        } header: {
            Text(chapter.title)
                .contextMenu { chapterMenu(chapter) }
        }
    }

    private func sceneRow(_ id: String, chapter: Chapter? = nil) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor(session.statuses[id] ?? nil))
                .frame(width: 7, height: 7)
            Text(session.titles[id] ?? id)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text((session.wordCounts[id] ?? 0).formatted())
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .tag(id)
        .help(hoverText(id))
        .contextMenu {
            Button("Neue Szene danach") { session.addScene(after: id) }
            Menu("Status") {
                ForEach(SceneStatus.allCases) { status in
                    Button(status.label) { session.setStatus(status, ofScene: id) }
                }
                Button("Kein Status") { session.setStatus(nil, ofScene: id) }
            }
            Menu("In Kapitel verschieben") {
                ForEach(session.manifest.chapters) { target in
                    Button(target.title) { session.moveScene(id, toChapter: target.id) }
                        .disabled(target.id == chapter?.id)
                }
            }
            if let chapter {
                Divider()
                chapterMenu(chapter)
            }
            Divider()
            Button("Szene löschen …", role: .destructive) { deleting = id }
        }
    }

    @ViewBuilder
    private func chapterMenu(_ chapter: Chapter) -> some View {
        Button("Kapitel umbenennen …") {
            renameText = chapter.title
            renaming = chapter
        }
        Button("Neue Szene in diesem Kapitel") { session.addScene(after: chapter.sceneIDs.last) }
        Button("Neues Kapitel danach") { session.addChapter(after: chapter.id) }
        Button("Kapitel nach oben") { session.moveChapter(chapter.id, by: -1) }
        Button("Kapitel nach unten") { session.moveChapter(chapter.id, by: 1) }
        Button("Kapitel auflösen (Szenen bleiben)") { session.removeChapter(chapter.id) }
            .disabled(session.manifest.chapters.count < 2)
    }

    private var bottomBar: some View {
        HStack {
            Menu {
                Button("Neue Szene") { session.addScene(after: session.selectedSceneID) }
                Button("Neues Kapitel") {
                    session.addChapter(after: session.selectedSceneID.flatMap { session.manifest.chapter(containing: $0)?.id })
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func statusColor(_ status: SceneStatus?) -> Color {
        switch status {
        case .draft: .orange.opacity(0.8)
        case .revised: .blue.opacity(0.75)
        case .done: .green.opacity(0.8)
        case nil: .secondary.opacity(0.35)
        }
    }

    /// Tooltip: status, synopsis, quick facts.
    private func hoverText(_ id: String) -> String {
        var lines: [String] = []
        if let status = session.statuses[id] ?? nil { lines.append(status.label) }
        if let synopsis = session.synopses[id] ?? nil { lines.append(synopsis) }
        for fact in session.sceneFacts[id] ?? [] { lines.append("\(fact.key): \(fact.displayValue)") }
        return lines.joined(separator: "\n")
    }
}
