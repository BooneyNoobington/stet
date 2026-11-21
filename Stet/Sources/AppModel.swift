import AppKit
import Sparkle
import SwiftUI
import StetCore
import UniformTypeIdentifiers

extension UTType {
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
    /// Set by the main window, so menu commands and the editor can open the wiki window.
    var openWindowAction: OpenWindowAction?

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
        do {
            let book = try Book(url: url)
            let session = BookSession(book: book, editor: editor)
            self.session = session
            remember(url)
            await session.start()
        } catch {
            errorMessage = error.localizedDescription
        }
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

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.stetBook]
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Öffnen"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await open(url) }
    }

    // MARK: Creating

    func showNewBookPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.stetBook]
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
        target.allowedContentTypes = [.stetBook]
        target.nameFieldStringValue = folder.lastPathComponent
        target.message = "Wohin soll das neue Stet-Buch? Am besten in einen Ordner, den kein Sync-Dienst verwaltet."
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
        panel.allowedContentTypes = [.stetBook]
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
