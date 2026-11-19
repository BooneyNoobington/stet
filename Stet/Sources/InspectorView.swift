import StetCore
import SwiftUI

struct InspectorView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case scene = "Details"
        case history = "Verlauf"
        var id: String { rawValue }
    }

    @ObservedObject var session: BookSession
    @Binding var tab: Tab

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            switch tab {
            case .scene: DetailsForm(session: session)
            case .history: HistoryList(session: session)
            }
        }
    }
}

// MARK: - Details

private struct DetailsForm: View {
    @ObservedObject var session: BookSession

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
                    ForEach(scene.facts, id: \.key) { fact in
                        LabeledContent(fact.key, value: fact.value)
                    }
                }
                if let chapter = session.manifest.chapter(containing: scene.id) {
                    Section("Kapitel") {
                        TextField("Titel", text: Binding(
                            get: { chapter.title },
                            set: { session.renameChapter(chapter.id, to: $0) }
                        ))
                        LabeledContent("Szenen", value: "\(chapter.sceneIDs.count)")
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
                LabeledContent("Wörter", value: session.totalWords.formatted())
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
                    HistoryRow(version: version).tag(version.id)
                }
                .listStyle(.inset)
            }
        }
    }
}

private struct HistoryRow: View {
    let version: Book.SceneVersion

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
                if let delta = version.commit.trailers["Stet-Words-Delta"], delta != "0" {
                    Text(delta).font(.caption).monospacedDigit().foregroundStyle(.secondary)
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
