import AppKit
import Sparkle
import SwiftUI
import ZadurCore
import UniformTypeIdentifiers

extension UTType {
    /// Books in the open Crea format (.crea).
    static let creaBook = UTType(exportedAs: "io.github.crea-format.book", conformingTo: .package)
    /// Books from when Zadur was called Stet (.stet).
    static let stetBook = UTType(exportedAs: "io.github.booneynoobington.stet.book", conformingTo: .package)
}

/// App-wide state: the open book (one at a time), recent books, and the open/create/import flows.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let editor = EditorController()
    @Published private(set) var session: BookSession?
    @Published private(set) var recentBooks: [URL] = []
    @Published var busyMessage: String?
    @Published var errorMessage: String? {
        didSet { if let errorMessage { DiagnosticsLog.record(errorMessage) } }
    }
    @Published var showWelcome = false
    /// Sparkle's updater (not in self-tests: they never go online on their own).
    private(set) var updater: SPUStandardUpdaterController?

    func startUpdater() {
        guard updater == nil else { return }
        updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }
    @Published var showProblemReport = false
    @Published var importReport: Importer.Report?
    @Published var showCloneSheet = false
    @Published var wikiSelection: String?
    /// The kind of wiki entry being named in the dialog of the wiki's ＋ menu.
    @Published var newWikiKind: WikiKind?
    /// Set by the main window, so menu commands and the editor can open the wiki window.
    var openWindowAction: OpenWindowAction?

    /// "Keep writing!" is what the name says: Turkish *yazadur*.
    static var tagline: String {
        Locale.preferredLanguages.first?.hasPrefix("de") == true ? "Schreib weiter!" : "Keep writing!"
    }

    private static let recentKey = "RecentBooks"

    private init() {
        _ = ProofSettings.shared  // signing setup in place before any book opens
        recentBooks = (UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: Opening

    func open(_ url: URL) async {
        if session?.book.url.standardizedFileURL == url.standardizedFileURL { return }
        await closeBook()
        await rememberKnownServers()
        do {
            let book = try Book(url: url)
            try RepositoryGuard.secure(url)
            let session = BookSession(book: book, editor: editor)
            self.session = session
            remember(url)
            await session.start()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Once, after updating from a version that didn't ask about servers: those of the books
    /// opened here before were set up here.
    private func rememberKnownServers() async {
        guard let store = ServerTrust.store as? DefaultsServerTrust, !store.hasRecords else { return }
        store.begin(with: await Book.serverAddresses(in: recentBooks))
    }

    func closeBook() async {
        await session?.close()
        session = nil
    }

    private func remember(_ url: URL) {
        guard !SelfTest.isRunning else { return }
        recentBooks.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        recentBooks.insert(url, at: 0)
        recentBooks = Array(recentBooks.prefix(8))
        UserDefaults.standard.set(recentBooks.map(\.path), forKey: Self.recentKey)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    private func forget(_ url: URL) {
        recentBooks.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        guard !SelfTest.isRunning else { return }
        UserDefaults.standard.set(recentBooks.map(\.path), forKey: Self.recentKey)
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.creaBook, .stetBook]
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Öffnen"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await open(url) }
    }

    // MARK: Creating

    func showNewBookPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.creaBook]
        panel.nameFieldStringValue = "Neues Buch"
        panel.message = "Wähle einen Ordner, den kein Sync-Dienst (Nextcloud, Dropbox, iCloud …) verwaltet."
        panel.prompt = "Anlegen"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            busyMessage = "Buch wird angelegt …"
            defer { busyMessage = nil }
            do {
                let title = url.deletingPathExtension().lastPathComponent
                let book = try await Book.create(at: url, title: title, author: await defaultAuthor())
                await open(book.url)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func defaultAuthor() async -> String {
        let name = try? await Git(directory: FileManager.default.homeDirectoryForCurrentUser)
            .run(["config", "--global", "user.name"], allowedStatus: [0, 1])
        let configured = name?.string.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return configured.isEmpty ? NSFullUserName() : configured
    }

    // MARK: Importing

    func showImportPanel() {
        let source = NSOpenPanel()
        source.canChooseDirectories = true
        source.canChooseFiles = false
        source.message = "Wähle den Ordner mit deinen Markdown-Szenen (z. B. mit einer book.yaml). Er wird nicht verändert."
        source.prompt = "Importieren"
        guard source.runModal() == .OK, let folder = source.url else { return }

        let target = NSSavePanel()
        target.allowedContentTypes = [.creaBook]
        target.nameFieldStringValue = folder.lastPathComponent
        target.message = "Wohin soll das neue Zadur-Buch? Am besten in einen Ordner, den kein Sync-Dienst verwaltet."
        target.prompt = "Buch anlegen"
        guard target.runModal() == .OK, let destination = target.url else { return }

        Task { await importFolder(folder, to: destination) }
    }

    @discardableResult
    func importFolder(_ folder: URL, to destination: URL) async -> Importer.Report? {
        busyMessage = "„\(folder.lastPathComponent)“ wird importiert …"
        defer { busyMessage = nil }
        do {
            let report = try await Importer.importFolder(folder, to: destination)
            await open(destination)
            importReport = report
            return report
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: Fetching a book from a server

    func showCloneDestinationPanel(for url: String, key: SSHKey? = nil, login: ServerLogin? = nil) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.creaBook]
        let name = URL(fileURLWithPath: url.replacingOccurrences(of: ":", with: "/")).deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = name.isEmpty ? "Buch" : name
        panel.message = "Wohin soll das Buch? Am besten in einen Ordner, den kein Sync-Dienst verwaltet."
        panel.prompt = "Holen"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task {
            busyMessage = "Buch wird vom Server geholt …"
            defer { busyMessage = nil }
            do {
                let book = try await Book.clone(from: url, to: destination, key: key, login: login)
                await open(book.url)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Saving a book in another place

    /// "Sichern unter …": where the copy goes and, for a book with a server, whether the copy
    /// stays connected. The window then continues in the copy.
    func showSaveAsPanel() {
        guard let session else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.creaBook]
        panel.nameFieldStringValue = session.book.url.deletingPathExtension().lastPathComponent
        panel.message = "Eine vollständige Kopie mit allen Versionen. Danach schreibst du in der Kopie weiter; das Original bleibt, wie es jetzt ist."
        panel.prompt = "Sichern"
        panel.canCreateDirectories = true
        let check = CopyDestinationCheck(book: session.book)
        panel.delegate = check
        var serverBox: NSButton?
        if session.isConnected {
            let accessory = Self.saveAsAccessory()
            panel.accessoryView = accessory.view
            serverBox = accessory.box
        }
        let answer = panel.runModal()
        withExtendedLifetime(check) {}
        guard answer == .OK, let url = panel.url else { return }
        let keepServer = serverBox.map { $0.state == .on } ?? true
        Task { await saveCurrentBook(as: url, keepServer: keepServer) }
    }

    static func saveAsAccessory() -> (view: NSView, box: NSButton) {
        let box = NSButton(checkboxWithTitle: "Mit dem Server verbunden bleiben", target: nil, action: nil)
        box.state = .on
        let note = NSTextField(wrappingLabelWithString: "An: dasselbe Buch an einem zweiten Ort; es gleicht sich mit dem Server ab wie ein zweiter Mac. Aus: eine unabhängige Kopie, die du später mit einem anderen Server verbinden kannst.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 400
        let stack = NSStackView(views: [box, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        stack.frame.size = stack.fittingSize
        return (stack, box)
    }

    /// Copies the open book to `destination` and continues there. The original keeps everything
    /// up to this moment, unsaved text included.
    @discardableResult
    func saveCurrentBook(as destination: URL, keepServer: Bool) async -> Bool {
        guard let session else { return false }
        let book = session.book
        do {
            try book.checkCopyDestination(destination)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        busyMessage = "Buch wird gesichert …"
        defer { busyMessage = nil }
        await closeBook()  // writes the editor's text, takes a snapshot, stops syncing
        do {
            let copy = try Book(url: try await book.copy(to: destination, keepServer: keepServer))
            // The new place gets its own check for sync services.
            var state = LocalState.load(for: copy)
            state.keepInSyncedFolder = false
            state.save(for: copy)
        } catch {
            errorMessage = "Das Buch ließ sich nicht sichern: \(error.localizedDescription) Das Original ist unverändert."
            await open(book.url)
            return false
        }
        await open(destination)
        self.session?.showToast(BookSession.Toast(message: "Gesichert als „\(destination.deletingPathExtension().lastPathComponent)“. Das Original bleibt, wie es war."))
        return true
    }

    // MARK: Renaming a book from when Zadur was called Stet

    /// `.stet` → `.crea`: only the name of the book's folder changes.
    func renameCurrentBookToCrea() {
        guard let source = session?.book.url, source.pathExtension == Book.legacyFileExtension else { return }
        Task { await renameToCrea(source) }
    }

    @discardableResult
    func renameToCrea(_ source: URL) async -> Bool {
        let target = source.deletingPathExtension().appendingPathExtension(Book.fileExtension)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            errorMessage = "Neben diesem Buch liegt schon eins namens „\(target.lastPathComponent)“. Es bleibt alles, wie es ist."
            return false
        }
        await closeBook()
        do {
            try FileManager.default.moveItem(at: source, to: target)
        } catch {
            errorMessage = "Das Buch ließ sich nicht umbenennen: \(error.localizedDescription)"
            await open(source)
            return false
        }
        forget(source)
        await open(target)
        return true
    }

    // MARK: Moving a book out of a synced folder

    func moveCurrentBook() {
        guard let session else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Wähle einen Ordner außerhalb von Nextcloud, Dropbox, iCloud & Co."
        panel.prompt = "Hierher verschieben"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let source = session.book.url
        let target = folder.appendingPathComponent(source.lastPathComponent)
        Task {
            await closeBook()
            do {
                try FileManager.default.moveItem(at: source, to: target)
                await open(target)
                if let finding = SyncLocation.detect(target) {
                    errorMessage = "Auch dieser Ordner wird von \(finding.service) synchronisiert."
                }
            } catch {
                errorMessage = error.localizedDescription
                await open(source)
            }
        }
    }
}

/// Keeps the save panel open with a reason when the copy can't go there (another book, or
/// inside the book itself).
final class CopyDestinationCheck: NSObject, NSOpenSavePanelDelegate {
    let book: Book
    init(book: Book) { self.book = book }

    func panel(_ sender: Any, validate url: URL) throws {
        try book.checkCopyDestination(url)
    }
}
