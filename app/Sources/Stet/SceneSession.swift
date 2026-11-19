import AppKit
import UniformTypeIdentifiers

/// One open scene file. In the spike this is a plain Markdown file; in Stet proper it
/// becomes a scene inside a .stet package, and Save becomes a commit.
@MainActor
final class SceneSession: ObservableObject {
    @Published private(set) var fileURL: URL?
    @Published private(set) var isDirty = false
    @Published private(set) var lastSaved: Date?
    @Published private(set) var lastError: String?

    let editor: EditorController
    private var changeCounter = 0
    private var autosaveTask: Task<Void, Never>?
    private static let autosaveDelay: Duration = .seconds(2)

    init(editor: EditorController) {
        self.editor = editor
        editor.onChange = { [weak self] in self?.didChange() }
        editor.onReady = { [weak self] in
            guard let self else { return }
            Task {
                if SelfTest.isRequested {
                    await SelfTest.run(editor: self.editor)
                } else {
                    await self.loadSample()
                }
            }
        }
    }

    var title: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? "Beispielszene"
    }

    var saveStatus: String {
        if let lastError { return "Fehler: \(lastError)" }
        if fileURL == nil { return isDirty ? "Nicht gesichert – ⌘S wählt einen Speicherort" : "Beispiel (nicht gesichert)" }
        if isDirty { return "Bearbeitet" }
        if let lastSaved { return "Gesichert \(lastSaved.formatted(date: .omitted, time: .shortened))" }
        return "Gesichert"
    }

    // MARK: Loading

    func loadSample() async {
        let text = (try? String(contentsOf: EditorResources.sampleURL, encoding: .utf8)) ?? ""
        await load(text, from: nil)
    }

    private func load(_ text: String, from url: URL?) async {
        autosaveTask?.cancel()
        await editor.applySettings()
        do {
            try await editor.load(text)
            fileURL = url
            isDirty = false
            lastError = nil
            editor.focus()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.markdownTypes
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                await load(text, from: url)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    // MARK: Saving

    private func didChange() {
        changeCounter += 1
        isDirty = true
        scheduleAutosave()
    }

    private func scheduleAutosave() {
        guard fileURL != nil else { return }
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.autosaveDelay)
            guard !Task.isCancelled else { return }
            await self?.save()
        }
    }

    func save() async {
        guard let url = fileURL else {
            saveAs()
            return
        }
        await write(to: url)
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = Self.markdownTypes
        panel.nameFieldStringValue = "\(title).md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await write(to: url) }
    }

    private func write(to url: URL) async {
        let counterAtStart = changeCounter
        do {
            let text = try await editor.text()
            try text.write(to: url, atomically: true, encoding: .utf8)
            fileURL = url
            lastSaved = Date()
            lastError = nil
            // Edits made while saving keep the document dirty.
            if changeCounter == counterAtStart { isDirty = false }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private static let markdownTypes: [UTType] = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
}
