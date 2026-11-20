import AppKit
import QuickLookThumbnailing
import StetCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Notes: all comments and TODOs

struct NotesList: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "Alle", todos = "TODOs", comments = "Kommentare"
        var id: String { rawValue }
    }

    @ObservedObject var session: BookSession
    @State private var filter = Filter.all

    private var shown: [NoteItem] {
        session.notes.filter {
            switch filter {
            case .all: true
            case .todos: $0.kind == .todo
            case .comments: $0.kind == .comment
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            if shown.isEmpty {
                ContentUnavailableView(
                    filter == .todos ? "Keine TODOs" : "Keine Notizen",
                    systemImage: "text.bubble",
                    description: Text("⌥⌘M fügt einen Kommentar ein, ⌥⌘T ein TODO.")
                )
            } else {
                List {
                    ForEach(groups, id: \.sceneID) { group in
                        Section(group.title) {
                            ForEach(group.notes) { NoteRow(session: session, note: $0) }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .task { await session.loadNotes() }
        .onChange(of: session.selectedSceneID) { Task { await session.loadNotes() } }
        .onChange(of: session.isWritingPending) { _, pending in
            if !pending { Task { await session.loadNotes() } }
        }
    }

    private var groups: [(sceneID: String, title: String, notes: [NoteItem])] {
        var result: [(String, String, [NoteItem])] = []
        for note in shown {
            if let last = result.last, last.0 == note.sceneID {
                result[result.count - 1].2.append(note)
            } else {
                result.append((note.sceneID, note.sceneTitle, [note]))
            }
        }
        return result.map { (sceneID: $0.0, title: $0.1, notes: $0.2) }
    }
}

private struct NoteRow: View {
    @ObservedObject var session: BookSession
    let note: NoteItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: note.kind == .todo ? "checklist" : "text.bubble")
                .foregroundStyle(note.kind == .todo ? Color.red.opacity(0.8) : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                if let author = note.author {
                    Text(author).font(.caption.weight(.semibold))
                }
                Text(note.text.isEmpty ? "…" : note.text).font(.callout)
                if let passage = note.highlighted, !passage.isEmpty {
                    Text("„\(passage)“").font(.caption).italic().foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            if note.kind == .todo {
                Button {
                    Task { await session.resolve(note) }
                } label: {
                    Image(systemName: "checkmark.circle")
                }
                .buttonStyle(.borderless)
                .help("Erledigt – das TODO verschwindet aus dem Text (im Verlauf bleibt es)")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { Task { await session.jump(to: note) } }
        .contextMenu {
            Button("Zur Stelle") { Task { await session.jump(to: note) } }
            Button(note.kind == .todo ? "Erledigt – aus dem Text entfernen" : "Kommentar entfernen") {
                Task { await session.resolve(note) }
            }
        }
    }
}

// MARK: - Feedback inbox

struct FeedbackPanel: View {
    @ObservedObject var session: BookSession
    @State private var selectedID: String?
    @State private var showNew = false
    @State private var wordFile: IdentifiedURL?

    var body: some View {
        Group {
            if let id = selectedID, let entry = session.feedback.first(where: { $0.id == id }) {
                FeedbackDetail(session: session, entry: entry) { selectedID = nil }
            } else {
                list
            }
        }
        .onAppear { session.loadFeedback() }
        .sheet(isPresented: $showNew) {
            NewFeedbackSheet(session: session) { selectedID = $0?.id }
        }
        .sheet(item: $wordFile) { file in
            ImportWordSheet(session: session, url: file.url) { selectedID = $0?.id }
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Neue Rückmeldung …") { showNew = true }
                Button("Word-Datei …") { chooseWordFile() }
                    .help("Eine zurückgeschickte .docx mit Kommentaren einlesen")
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            if session.feedback.isEmpty {
                ContentUnavailableView(
                    "Noch keine Rückmeldungen",
                    systemImage: "tray",
                    description: Text("Halte hier fest, was dir Leserinnen und Leser zurückgeben – als Text, Foto vom Ausdruck oder Word-Datei mit Kommentaren.")
                )
            } else {
                List {
                    let open = session.feedback.filter { !$0.isDone }
                    let done = session.feedback.filter(\.isDone)
                    if !open.isEmpty {
                        Section("Offen") { ForEach(open) { row($0) } }
                    }
                    if !done.isEmpty {
                        Section("Erledigt") { ForEach(done) { row($0) } }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func row(_ entry: FeedbackEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(entry.from.isEmpty ? "Ohne Namen" : entry.from).font(.callout.weight(.semibold))
                Spacer()
                Text(entry.received.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
            }
            if !entry.text.isEmpty {
                Text(entry.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 8) {
                if !entry.attachments.isEmpty {
                    Label("\(entry.attachments.count)", systemImage: "paperclip")
                }
                if !entry.wordComments.isEmpty {
                    let open = entry.wordComments.filter { !$0.placed }.count
                    Label(open == 0 ? "alle eingefügt" : "\(open) offen", systemImage: "text.bubble")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { selectedID = entry.id }
    }

    private func chooseWordFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "docx") ?? .data]
        panel.message = "Die Word-Datei mit den Kommentaren, z. B. eine zurückgeschickte Fassung aus dem Export."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        wordFile = IdentifiedURL(url: url)
    }
}

struct IdentifiedURL: Identifiable {
    let url: URL
    var id: String { url.path }
}

private struct FeedbackDetail: View {
    @ObservedObject var session: BookSession
    let entry: FeedbackEntry
    let back: () -> Void
    @State private var selection = ""
    @State private var confirmDelete = false
    @State private var notFound: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Button { back() } label: { Label("Alle Rückmeldungen", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.from.isEmpty ? "Ohne Namen" : entry.from).font(.title3.weight(.semibold))
                    Text("Erhalten am \(entry.received.formatted(date: .long, time: .omitted))")
                        .font(.caption).foregroundStyle(.secondary)
                    if entry.refersTo != nil {
                        Text("Zu: \(session.milestoneLabel(entry.refersTo))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if entry.refersTo != nil {
                    Button("Diese Szene mit jener Fassung vergleichen") {
                        Task { await session.compareWithFeedbackVersion(entry) }
                    }
                    .controlSize(.small)
                    .disabled(session.selectedSceneID == nil)
                    .help("Zeigt, was sich in der geöffneten Szene seit der Fassung geändert hat, die gelesen wurde.")
                }

                Toggle("Erledigt", isOn: Binding(
                    get: { entry.isDone },
                    set: { done in
                        var changed = entry
                        changed.isDone = done
                        session.save(changed)
                    }
                ))

                if !entry.text.isEmpty {
                    SelectableText(text: entry.text, selection: $selection)
                        .frame(height: 170)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.background.secondary))
                    Button("Markiertes als Kommentar einfügen") {
                        Task { await session.insertFeedbackComment(selection, from: entry.from) }
                    }
                    .controlSize(.small)
                    .disabled(selection.trimmingCharacters(in: .whitespaces).isEmpty || session.selectedSceneID == nil)
                    .help("Fügt den markierten Text als Kommentar „@\(entry.from): …“ an der Cursorstelle ein – oder um den im Editor markierten Text.")
                }

                if !entry.attachments.isEmpty {
                    Text("Anhänge").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(entry.attachments, id: \.self) { path in
                        AttachmentRow(url: session.attachmentURL(path))
                    }
                }

                if !entry.wordComments.isEmpty {
                    HStack {
                        Text("Kommentare aus Word").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Alle an ihre Stelle") {
                            Task {
                                for comment in entry.wordComments where !comment.placed {
                                    if !(await session.place(comment, of: currentEntry)) { notFound.insert(comment.id) }
                                }
                            }
                        }
                        .controlSize(.small)
                        .disabled(entry.wordComments.allSatisfy(\.placed))
                    }
                    ForEach(entry.wordComments) { comment in
                        wordCommentRow(comment)
                    }
                }

                Divider()
                Button("Rückmeldung löschen …", role: .destructive) { confirmDelete = true }
                    .controlSize(.small)
            }
            .padding(12)
        }
        .confirmationDialog("Rückmeldung löschen?", isPresented: $confirmDelete) {
            Button("Löschen", role: .destructive) {
                session.delete(entry)
                back()
            }
        } message: {
            Text("Die Rückmeldung und ihre Anhänge verschwinden aus dem Buch; im Verlauf bleiben sie erhalten.")
        }
    }

    /// The entry as it is on disk now (placing comments updates it).
    private var currentEntry: FeedbackEntry {
        session.feedback.first { $0.id == entry.id } ?? entry
    }

    private func wordCommentRow(_ comment: WordComment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(comment.author).font(.caption.weight(.semibold))
            Text(comment.text).font(.callout)
            if !comment.anchor.isEmpty {
                Text("„\(comment.anchor)“").font(.caption).italic().foregroundStyle(.secondary).lineLimit(3)
            }
            HStack {
                if comment.placed {
                    Label("Eingefügt", systemImage: "checkmark").font(.caption).foregroundStyle(.green)
                } else {
                    if !comment.anchor.isEmpty {
                        Button("An die Stelle") {
                            Task {
                                if !(await session.place(comment, of: currentEntry)) { notFound.insert(comment.id) }
                            }
                        }
                    }
                    Button("An den Cursor") { Task { await session.placeAtCursor(comment, of: currentEntry) } }
                        .disabled(session.selectedSceneID == nil)
                }
            }
            .controlSize(.small)
            if notFound.contains(comment.id) && !comment.placed {
                Text("Die Stelle steht so nicht mehr im Text – setz den Kommentar an den Cursor.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(.background.secondary))
    }
}

private struct AttachmentRow: View {
    let url: URL
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFit()
                } else {
                    Image(systemName: "doc")
                }
            }
            .frame(width: 44, height: 44)
            Text(displayName).font(.caption).lineLimit(2)
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { NSWorkspace.shared.open(url) }
        .help("Öffnen")
        .task {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 88, height: 88), scale: 2, representationTypes: .thumbnail)
            thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }
    }

    /// Without the "<entry id>-" prefix Stet adds when copying.
    private var displayName: String {
        let name = url.lastPathComponent
        let parts = name.split(separator: "-", maxSplits: 4)
        return parts.count == 5 ? String(parts[4]) : name
    }
}

/// Read-only text whose selection can be used (SwiftUI's Text doesn't expose it).
struct SelectableText: NSViewRepresentable {
    let text: String
    @Binding var selection: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.font = NSFont(name: "Iowan Old Style", size: 14) ?? .systemFont(ofSize: 13)
        view.textContainerInset = NSSize(width: 6, height: 6)
        view.delegate = context.coordinator
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let view = scroll.documentView as! NSTextView
        if view.string != text { view.string = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: SelectableText
        init(_ parent: SelectableText) { self.parent = parent }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.selection = (view.string as NSString).substring(with: view.selectedRange())
        }
    }
}

// MARK: - New feedback

struct NewFeedbackSheet: View {
    @ObservedObject var session: BookSession
    let created: (FeedbackEntry?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var from = ""
    @State private var received = Date()
    @State private var refersTo: String?
    @State private var text = ""
    @State private var attachments: [URL] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Neue Rückmeldung").font(.title2)
            Form {
                HStack {
                    TextField("Von", text: $from, prompt: Text("Name"))
                    if !session.feedbackNames.isEmpty {
                        Menu("Bekannt") {
                            ForEach(session.feedbackNames, id: \.self) { name in Button(name) { from = name } }
                        }
                        .fixedSize()
                    }
                }
                DatePicker("Erhalten am", selection: $received, displayedComponents: .date)
                ReferencePicker(session: session, selection: $refersTo)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Was sie oder er zurückgegeben hat").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $text)
                        .font(.system(size: 14, design: .serif))
                        .frame(minHeight: 150)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Anhänge").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Hinzufügen …") { addAttachments() }.controlSize(.small)
                    }
                    ForEach(attachments, id: \.self) { url in
                        HStack {
                            Image(systemName: "paperclip")
                            Text(url.lastPathComponent).lineLimit(1)
                            Spacer()
                            Button { attachments.removeAll { $0 == url } } label: { Image(systemName: "xmark.circle") }
                                .buttonStyle(.borderless)
                        }
                        .font(.caption)
                    }
                    if attachments.isEmpty {
                        Text("z. B. ein Foto vom angemerkten Ausdruck – oder hierher ziehen.").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            .formStyle(.grouped)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let url { DispatchQueue.main.async { attachments.append(url) } }
                    }
                }
                return true
            }
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                Button("Sichern") {
                    let entry = session.addFeedback(from: from.trimmingCharacters(in: .whitespaces), received: received,
                                                    refersTo: refersTo, text: text, attachments: attachments)
                    dismiss()
                    created(entry)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 540, height: 600)
        .onAppear { refersTo = session.latestExportTag }
    }

    private func addAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        attachments += panel.urls
    }
}

/// Which export or milestone a piece of feedback is about.
private struct ReferencePicker: View {
    @ObservedObject var session: BookSession
    @Binding var selection: String?

    var body: some View {
        Picker("Bezieht sich auf", selection: $selection) {
            Text("–").tag(String?.none)
            ForEach(session.milestones.sorted { $0.date > $1.date }) { milestone in
                Text("\(milestone.name) – \(milestone.date.formatted(date: .abbreviated, time: .shortened))")
                    .tag(String?.some(milestone.tag))
            }
        }
        .help("Die exportierte Fassung, die gelesen wurde. Damit lässt sich später vergleichen, was sich seitdem geändert hat.")
    }
}

// MARK: - Import a Word file

struct ImportWordSheet: View {
    @ObservedObject var session: BookSession
    let url: URL
    let created: (FeedbackEntry?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var comments: [WordComment]?
    @State private var error: String?
    @State private var from = ""
    @State private var refersTo: String?
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Word-Datei einlesen").font(.title2)
            Text(url.lastPathComponent).font(.headline)
            if let comments {
                Text(comments.isEmpty
                     ? "Die Datei enthält keine Kommentare. Sie wird trotzdem als Anhang abgelegt."
                     : "\(comments.count) Kommentar(e) von \(Set(comments.map(\.author)).sorted().joined(separator: ", ")). Danach kannst du sie einzeln oder alle auf einmal an ihre Stelle im heutigen Text setzen.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else {
                ProgressView("Kommentare werden gelesen …")
            }
            Form {
                TextField("Von", text: $from)
                ReferencePicker(session: session, selection: $refersTo)
                TextField("Notiz (optional)", text: $note, axis: .vertical).lineLimit(2...4)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                Button("Einlesen") {
                    Task {
                        let entry = await session.importWord(url, from: from, refersTo: refersTo, note: note)
                        dismiss()
                        created(entry)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(comments == nil)
            }
        }
        .padding(20)
        .frame(width: 500)
        .task {
            refersTo = session.latestExportTag
            do {
                let read = try await Book.wordComments(in: url)
                comments = read
                // The most frequent author is probably the person who sent it.
                let counts = Dictionary(read.map { ($0.author, 1) }, uniquingKeysWith: +)
                from = counts.max { $0.value < $1.value }?.key ?? ""
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
