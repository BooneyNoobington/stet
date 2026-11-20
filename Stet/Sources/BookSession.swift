import AppKit
import StetCore

/// One open book in the window: structure, the scene in the editor, saving, history and safety.
@MainActor
final class BookSession: ObservableObject {
    let book: Book
    let editor: EditorController

    @Published private(set) var manifest: Manifest
    @Published private(set) var selectedSceneID: String?
    @Published private(set) var currentScene: SceneFile?
    @Published private(set) var titles: [String: String] = [:]
    @Published private(set) var statuses: [String: SceneStatus] = [:]
    @Published private(set) var synopses: [String: String] = [:]
    @Published private(set) var wordCounts: [String: Int] = [:]
    @Published private(set) var unplacedSceneIDs: [String] = []

    /// Editor text not yet written to disk.
    @Published var isWritingPending = false
    /// Changes on disk that aren't in a saved version yet.
    @Published var hasChangesSinceVersion = false
    @Published var lastVersion: Git.Commit?

    @Published var toast: Toast?
    @Published var errorMessage: String?
    @Published private(set) var syncFinding: SyncLocation.Finding?
    @Published private(set) var health: HealthCheck.Report?

    // Versions: main version, experiments, milestones (see BookSession+Versions.swift)
    @Published var mainBranch = "main"
    @Published var branch = "main"
    @Published var branchName = "Hauptfassung"
    @Published var experiments: [Experiment] = []
    @Published var milestones: [Milestone] = []
    @Published var sheet: Sheet?
    @Published var adoption: Adoption?
    @Published var isBusy = false

    // Server (see BookSession+Server.swift)
    @Published var serverURL: String?
    @Published var stetKey: SSHKey?
    @Published var syncState: SyncState = .off
    var syncTask: Task<Void, Never>?

    // Notes and feedback (see BookSession+Feedback.swift)
    @Published var notes: [NoteItem] = []
    @Published var feedback: [FeedbackEntry] = []
    @Published var backupWarning: String?
    @Published var wiki: [WikiEntry] = []
    @Published private(set) var sceneFacts: [String: [Fact]] = [:]
    // Signatures and timestamps
    @Published var stamps: [String: [StampRecord]] = [:]
    @Published var signatures: [String: SignatureInfo] = [:]
    @Published var signerLabels: [String: String] = [:]
    @Published var pendingStampCount = 0
    @Published var isStamping = false
    @Published var stampProblem: String?
    @Published var signingProblem: String?
    @Published var proofMessage: String?

    @Published private(set) var history: [Book.SceneVersion] = []
    @Published private(set) var isLoadingHistory = false
    @Published var comparison: Comparison?

    struct Toast: Equatable {
        var message: String
        var commit: String?
        var id = UUID()
    }

    struct Comparison: Equatable {
        let version: Book.SceneVersion
        let oldText: String
        let segments: [WordDiff.Segment]
        let summary: WordDiff.Summary
    }

    private var autosaveTask: Task<Void, Never>?
    private var persistChain: Task<Void, Never>?
    private var snapshotTimer: Timer?
    private var activeMinutes = Set<Int>()
    private var observers: [NSObjectProtocol] = []

    private static let autosaveDelay: Duration = .milliseconds(1500)
    private static let snapshotInterval: TimeInterval = 10 * 60

    init(book: Book, editor: EditorController) {
        self.book = book
        self.editor = editor
        self.manifest = book.manifest
    }

    // MARK: - Lifecycle

    func start() async {
        reloadSceneInfo()
        editor.onChange = { [weak self] in self?.editorChanged() }
        editor.onActivity = { [weak self] in self?.activeMinutes.insert(Int(Date().timeIntervalSince1970 / 60)) }
        editor.onOpenWiki = { id in AppModel.shared.openWiki(id) }
        editor.contextMenuProvider = { [weak self] text, wikiID in self?.contextMenuItems(text: text, wikiID: wikiID) ?? [] }
        loadWiki()
        editor.settings.language = manifest.language
        editor.settings.quotes = EditorSettings.quotes(forLanguage: manifest.language)

        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.persistAndSnapshot() }
        })
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: Self.snapshotInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.persistAndSnapshot() }
        }

        await editor.waitUntilReady()
        await editor.applySettings()
        await pushWikiTerms()
        let localState = LocalState.load(for: book)
        let first = localState.lastSceneID.flatMap { manifest.sceneIDs.contains($0) ? $0 : nil } ?? manifest.sceneIDs.first
        if let first { await select(first) }

        syncFinding = localState.keepInSyncedFolder ? nil : SyncLocation.detect(book.url)
        lastVersion = try? await book.git.log(limit: 1).first
        hasChangesSinceVersion = !((try? await book.git.changedPaths()) ?? []).isEmpty
        let report = await HealthCheck.run(book)
        health = report.isHealthy ? nil : report
        await refreshVersions()
        await resumeAdoptionIfNeeded()
        await loadServer()
        if isConnected && adoption == nil { await syncNow() }
        await maybeAutoBackup()
        await startProofs()
    }

    /// Writes everything to disk and takes a snapshot. Called before closing or quitting.
    func close() async {
        await persistAndSnapshot()
        snapshotTimer?.invalidate()
        syncTask?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        editor.onChange = nil
        editor.onActivity = nil
        editor.onOpenWiki = nil
        editor.contextMenuProvider = nil
        await editor.setWikiTerms([])
    }

    // MARK: - Scene info for the navigator

    func reloadSceneInfo() {
        manifest = book.manifest
        unplacedSceneIDs = book.unplacedSceneIDs()
        for id in manifest.sceneIDs + unplacedSceneIDs {
            guard let scene = try? book.readScene(id) else {
                titles[id] = "Fehlende Datei"
                continue
            }
            cache(scene)
        }
    }

    private func cache(_ scene: SceneFile) {
        titles[scene.id] = scene.displayTitle
        statuses[scene.id] = scene.status
        synopses[scene.id] = scene.synopsis
        sceneFacts[scene.id] = scene.factList
        wordCounts[scene.id] = TextStats.words(in: scene.body)
    }

    var totalWords: Int {
        manifest.sceneIDs.reduce(0) { sum, id in
            sum + (id == selectedSceneID ? editor.words : (wordCounts[id] ?? 0))
        }
    }

    // MARK: - Selecting and editing scenes

    func select(_ id: String?, force: Bool = false) async {
        guard let id, force || id != selectedSceneID else { return }
        if !force { await persist() }
        do {
            let scene = try book.readScene(id)
            comparison = nil
            selectedSceneID = id
            currentScene = scene
            try await editor.load(scene.body)
            editor.focus()
            var state = LocalState.load(for: book)
            state.lastSceneID = id
            state.save(for: book)
            await loadHistory()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func editorChanged() {
        isWritingPending = true
        hasChangesSinceVersion = true
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.autosaveDelay)
            guard !Task.isCancelled else { return }
            await self?.persist()
        }
    }

    /// Writes the editor's text (and metadata) of the current scene to disk, in order.
    func persist() async {
        let previous = persistChain
        let task = Task { [weak self] in
            await previous?.value
            await self?.writeCurrentScene()
        }
        persistChain = task
        await task.value
    }

    private func writeCurrentScene() async {
        // During an adoption the files hold merge results; the editor must not overwrite them.
        guard adoption == nil, var scene = currentScene else { return }
        if isWritingPending {
            guard let text = try? await editor.text() else { return }
            scene.body = text
            isWritingPending = false
        }
        do {
            if try book.writeScene(scene) { hasChangesSinceVersion = true }
            currentScene = scene
            cache(scene)
        } catch {
            errorMessage = "Die Szene konnte nicht gesichert werden: \(error.localizedDescription)"
        }
    }

    func updateCurrentScene(_ change: (inout SceneFile) -> Void) {
        guard var scene = currentScene else { return }
        change(&scene)
        currentScene = scene
        Task { await persist() }
    }

    func setStatus(_ status: SceneStatus?, ofScene id: String) {
        if id == selectedSceneID {
            updateCurrentScene { $0.status = status }
            return
        }
        guard var scene = try? book.readScene(id) else { return }
        scene.status = status
        try? book.writeScene(scene)
        cache(scene)
        hasChangesSinceVersion = true
    }

    // MARK: - Structure

    private func changeStructure(_ change: () throws -> Void) {
        do {
            try change()
            reloadSceneInfo()
            hasChangesSinceVersion = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addScene(after sceneID: String?) {
        let chapterID = sceneID.flatMap { manifest.chapter(containing: $0)?.id } ?? manifest.chapters.last?.id
        guard let chapterID else { return }
        var newID: String?
        changeStructure { newID = try book.addScene(toChapter: chapterID, after: sceneID).id }
        if let newID { Task { await select(newID) } }
    }

    func addChapter(after chapterID: String?) {
        let number = manifest.chapters.count + 1
        var newScene: String?
        changeStructure {
            let chapter = try book.addChapter(title: "Kapitel \(number)", after: chapterID)
            newScene = chapter.sceneIDs.first
        }
        if let newScene { Task { await select(newScene) } }
    }

    func renameChapter(_ chapterID: String, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        changeStructure { try book.updateManifest { $0.updateChapter(chapterID) { $0.title = trimmed } } }
    }

    func moveScenes(inChapter chapterID: String, from offsets: IndexSet, to destination: Int) {
        changeStructure {
            try book.updateManifest { manifest in
                manifest.updateChapter(chapterID) { $0.sceneIDs.move(fromOffsets: offsets, toOffset: destination) }
            }
        }
    }

    func moveScene(_ sceneID: String, toChapter chapterID: String) {
        changeStructure { try book.updateManifest { $0.moveScene(sceneID, toChapter: chapterID, at: .max) } }
    }

    func moveChapter(_ chapterID: String, by offset: Int) {
        changeStructure { try book.updateManifest { $0.moveStructureNode(containingChapter: chapterID, by: offset) } }
    }

    func removeChapter(_ chapterID: String) {
        changeStructure { try book.updateManifest { $0.removeChapter(chapterID) } }
    }

    func deleteScene(_ id: String) async {
        if id == selectedSceneID {
            await persist()
            let order = manifest.sceneIDs
            let next = order.firstIndex(of: id).flatMap { i in order.indices.contains(i + 1) ? order[i + 1] : (i > 0 ? order[i - 1] : nil) }
            selectedSceneID = nil
            currentScene = nil
            changeStructure { try book.deleteScene(id) }
            if let next { await select(next) } else { try? await editor.load("") }
        } else {
            changeStructure { try book.deleteScene(id) }
        }
    }

    func updateBook(_ change: (inout Manifest) -> Void) {
        changeStructure { try book.updateManifest(change) }
    }

    // MARK: - Versions

    func saveVersion() async {
        await persist()
        do {
            guard let result = try await book.saveVersion(activeMinutes: activeMinutes.count) else {
                showToast(Toast(message: "Keine Änderungen seit der letzten Version"))
                return
            }
            activeMinutes.removeAll()
            hasChangesSinceVersion = false
            lastVersion = try? await book.git.log(limit: 1).first
            scheduleSync()
            Task { await maybeAutoBackup() }
            Task { await versionSaved() }
            let delta = result.wordsDelta == 0 ? "" : " · \(result.wordsDelta > 0 ? "+" : "")\(result.wordsDelta.formatted()) Wörter"
            showToast(Toast(message: "Version gesichert" + delta, commit: result.commit))
            await loadHistory()
        } catch {
            errorMessage = "Die Version konnte nicht gesichert werden: \(error.localizedDescription)"
        }
    }

    func addNote(_ text: String, to commit: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await book.git.addNote(trimmed, to: commit)
            showToast(Toast(message: "Notiz gespeichert"))
            await loadHistory()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func showToast(_ toast: Toast) {
        self.toast = toast
        let shown = toast
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(shown.commit == nil ? 2.5 : 6))
            if self?.toast == shown { self?.toast = nil }
        }
    }

    /// Keeps the toast up (e.g. while a note is being typed).
    func pinToast() {
        toast?.id = UUID()
    }

    func persistAndSnapshot() async {
        guard adoption == nil else { return }
        await persist()
        _ = try? await book.snapshot(device: DeviceID.current)
    }

    // MARK: - History

    func loadHistory() async {
        guard let id = selectedSceneID else { history = []; return }
        isLoadingHistory = true
        history = (try? await book.history(ofScene: id, device: DeviceID.current)) ?? []
        isLoadingHistory = false
        await loadSignatures(for: history.filter { !$0.isSnapshot }.map(\.commit.hash))
    }

    func compare(with version: Book.SceneVersion) async {
        await persist()
        guard let oldText = await book.text(of: version), let current = currentScene?.body else { return }
        let segments = WordDiff.diff(old: oldText, new: current)
        comparison = Comparison(version: version, oldText: oldText, segments: segments, summary: WordDiff.summary(of: segments))
    }

    /// Puts an older version's text into the editor as one undoable edit.
    func restore(_ comparison: Comparison) async {
        do {
            try await editor.replaceText(comparison.oldText)
            self.comparison = nil
            await persist()
            showToast(Toast(message: "Fassung wiederhergestellt – ⌘Z macht es rückgängig"))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Safety

    func keepInSyncedFolder() {
        var state = LocalState.load(for: book)
        state.keepInSyncedFolder = true
        state.save(for: book)
        syncFinding = nil
    }

    func dismissHealthWarning() {
        health = nil
    }
}

/// Per-device state stored in the book's git-ignored `.local/` folder.
struct LocalState: Codable {
    var lastSceneID: String?
    var keepInSyncedFolder = false
    // Optional, so state files written before these existed still decode.
    var autoBackup: Bool?
    var backupFolder: String?
    var backupKeep: Int?
    var lastAutoBackup: Date?

    private static func url(for book: Book) -> URL {
        book.url.appendingPathComponent(Book.localFolder).appendingPathComponent("state.json")
    }

    static func load(for book: Book) -> LocalState {
        guard let data = try? Data(contentsOf: url(for: book)),
              let state = try? JSONDecoder().decode(LocalState.self, from: data)
        else { return LocalState() }
        return state
    }

    func save(for book: Book) {
        let url = Self.url(for: book)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: url, options: .atomic) }
    }
}

/// A short random ID for this Mac, used to name its snapshot ref.
enum DeviceID {
    static var current: String {
        if let id = UserDefaults.standard.string(forKey: "StetDeviceID") { return id }
        let id = StetID.make()
        UserDefaults.standard.set(id, forKey: "StetDeviceID")
        return id
    }
}
