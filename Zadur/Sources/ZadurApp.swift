import AppKit
import ZadurCore
import SwiftUI

@main
struct ZadurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    init() {
        SettingsMigration.run()
    }

    var body: some Scene {
        Window("Zadur", id: "main") {
            RootView(model: model, editor: model.editor)
        }
        .defaultSize(width: 1280, height: 820)
        .commands { ZadurCommands(model: model, editor: model.editor) }

        Window("Wiki", id: "wiki") {
            WikiWindow(model: model)
        }
        .defaultSize(width: 860, height: 620)

        Window("Zadur-Hilfe", id: "help") {
            HelpWindow()
        }
        .defaultSize(width: 860, height: 620)

        Window("Verlauf", id: "graph") {
            HistoryGraphWindow(model: model)
        }
        .defaultSize(width: 760, height: 620)

        Window("Zeitleiste", id: "timeline") {
            TimelineWindow(model: model)
        }
        .defaultSize(width: 820, height: 640)

        Window("Statistik", id: "stats") {
            StatsWindow(model: model)
        }
        .defaultSize(width: 760, height: 720)

        Window("Rechtschreibung", id: "spelling") {
            SpellingWindow(model: model)
        }
        .defaultSize(width: 760, height: 560)

        Settings {
            ZadurSettingsView()
        }
    }
}

struct ZadurCommands: Commands {
    @ObservedObject var model: AppModel
    @ObservedObject var editor: EditorController

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Neues Buch …") { model.showNewBookPanel() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Buch öffnen …") { model.showOpenPanel() }
                .keyboardShortcut("o")
            Menu("Zuletzt geöffnet") {
                ForEach(model.recentBooks, id: \.self) { url in
                    Button(url.deletingPathExtension().lastPathComponent) { Task { await model.open(url) } }
                }
            }
            .disabled(model.recentBooks.isEmpty)
            Divider()
            Button("Ordner importieren …") { model.showImportPanel() }
            Button("Buch vom Server holen …") { model.showCloneSheet = true }
            Button("Backup wiederherstellen …") { model.showRestorePanel() }
            Divider()
            Button("Buch schließen") { Task { await model.closeBook() } }
                .disabled(model.session == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Version sichern") { Task { await model.session?.saveVersion() } }
                .keyboardShortcut("s")
                .disabled(model.session == nil)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Suchen …") { Task { await model.session?.find.show() } }
                .keyboardShortcut("f")
                .disabled(model.session == nil)
            Button("Suchen und ersetzen …") { Task { await model.session?.find.show(replace: true) } }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(model.session == nil)
            Button("Weitersuchen") { Task { await model.session?.find.next() } }
                .keyboardShortcut("g")
                .disabled(model.session == nil)
            Button("Rückwärts suchen") { Task { await model.session?.find.previous() } }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(model.session == nil)
        }
        CommandGroup(replacing: .importExport) {
            Button("Exportieren …") { model.session?.sheet = .export }
                .keyboardShortcut("e")
                .disabled(model.session == nil)
            Button("Backup sichern …") { model.showBackupPanel() }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .disabled(model.session == nil)
            Button("Backups einstellen …") { model.session?.sheet = .backup }
                .disabled(model.session == nil)
        }
        CommandMenu("Format") {
            FormatMenu(model: model, editor: editor)
        }
        CommandMenu("Buch") {
            Button("Wiki öffnen") { model.openWiki() }
                .keyboardShortcut("w", modifiers: [.command, .option])
                .disabled(model.session == nil)
            Button("Wiki-Eintrag aus Auswahl") {
                Task {
                    if let entry = await model.session?.wikiEntryFromSelection() { model.openWiki(entry.id) }
                }
            }
            .keyboardShortcut("w", modifiers: [.command, .control])
            .disabled(model.session == nil)
            Button("Wiki aus anderem Buch übernehmen …") {
                model.openWiki()
                model.session?.chooseWikiToImport()
            }
            .disabled(model.session == nil)
            Button("Wiki exportieren …") { model.session?.exportWiki() }
                .disabled(model.session?.wiki.isEmpty != false)
            Divider()
            Button("Zeitleiste") { model.openWindowAction?(id: "timeline") }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(model.session == nil)
            Button("Statistik") { model.openWindowAction?(id: "stats") }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(model.session == nil)
            Button("Rechtschreibung prüfen …") {
                model.openWindowAction?(id: "spelling")
                Task { await model.session?.reviewSpelling() }
            }
            .keyboardShortcut(";", modifiers: [.command, .shift])
            .disabled(model.session == nil)
            Button("Anführungszeichen angleichen …") { Task { await model.session?.offerQuoteConversion() } }
                .disabled(model.session == nil)
            Divider()
            Button("Mit dem Server abgleichen") { Task { await model.session?.syncNow() } }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .disabled(model.session?.isConnected != true)
            Button("Server …") { model.session?.sheet = .server }
                .disabled(model.session == nil)
            Divider()
            Button("Zeitstempel jetzt holen") { Task { await model.session?.stampNow() } }
                .disabled(model.session == nil)
            Button("Nachweis für die letzte Version …") {
                if let session = model.session, let head = session.lastVersion?.hash { session.saveProof(for: head) }
            }
            .disabled(model.session?.lastVersion == nil)
            Button("Datei prüfen …") { model.session?.chooseFileToCheck() }
                .disabled(model.session == nil)
            Divider()
            Button("Neue Szene") { model.session?.addScene(after: model.session?.selectedSceneID) }
                .keyboardShortcut("n")
                .disabled(model.session == nil)
            Button("Neues Kapitel") {
                let chapter = model.session?.selectedSceneID.flatMap { model.session?.manifest.chapter(containing: $0)?.id }
                model.session?.addChapter(after: chapter)
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            .disabled(model.session == nil)
        }
        CommandMenu("Fassung") {
            Button("Neues Experiment …") { model.session?.sheet = .startExperiment }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.session == nil)
            Button("Zur Hauptfassung") {
                if let session = model.session { Task { await session.switchTo(session.mainBranch) } }
            }
            .disabled(model.session?.isOnExperiment != true)
            Button("Experiment übernehmen …") {
                if let current = model.session?.currentExperiment { model.session?.sheet = .adopt(current) }
            }
            .disabled(model.session?.currentExperiment == nil)
            Button("Experiment ablegen") {
                if let session = model.session, let current = session.currentExperiment { Task { await session.shelve(current) } }
            }
            .disabled(model.session?.currentExperiment == nil)
            Divider()
            Button("Meilenstein setzen …") { model.session?.sheet = .milestone }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(model.session == nil)
            Divider()
            Button("Verlauf zeigen") { model.openWindowAction?(id: "graph") }
                .keyboardShortcut("y", modifiers: [.command, .option])
                .disabled(model.session == nil)
        }
        CommandGroup(replacing: .appInfo) {
            Button("Über Zadur") {
                let style = NSMutableParagraphStyle()
                style.alignment = .center
                NSApp.orderFrontStandardAboutPanel(options: [.credits: NSAttributedString(string: AppModel.tagline, attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .paragraphStyle: style, .foregroundColor: NSColor.secondaryLabelColor,
                ])])
            }
        }
        CommandGroup(after: .appInfo) {
            Button("Nach Updates suchen …") { model.updater?.checkForUpdates(nil) }
                .disabled(model.updater == nil)
        }
        CommandGroup(replacing: .help) {
            Button("Zadur-Hilfe") { model.openWindowAction?(id: "help") }
                .keyboardShortcut("?", modifiers: [.command])
            Button("Einführung …") { model.showWelcome = true }
            Button("Beispielbuch öffnen") { Task { await model.openSampleBook() } }
            Divider()
            Button("Problem melden …") { model.showProblemReport = true }
        }
        CommandGroup(after: .toolbar) {
            Picker("Schrift", selection: $editor.settings.font) {
                ForEach(EditorSettings.Font.allCases) { Text($0.label).tag($0) }
            }
            Button("Größer") { editor.settings.fontSize = min(32, editor.settings.fontSize + 1) }
                .keyboardShortcut("+")
            Button("Kleiner") { editor.settings.fontSize = max(12, editor.settings.fontSize - 1) }
                .keyboardShortcut("-")
            Toggle("Kommentare zeigen", isOn: $editor.settings.showComments)
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Toggle("Fokusmodus", isOn: $editor.settings.focusMode)
                .keyboardShortcut("f", modifiers: [.command, .option])
            Toggle("Wiki-Namen unterstreichen", isOn: $editor.settings.showWikiTerms)
            Toggle("Rechtschreibfehler markieren", isOn: $editor.settings.checkSpelling)
            Divider()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        SelfTest.startIfRequested()
        if !SelfTest.isRunning {
            AppModel.shared.startUpdater()
            if !UserDefaults.standard.bool(forKey: AppModel.welcomeShownKey) { AppModel.shared.showWelcome = true }
        }
    }

    /// Double-clicking a .crea (or .crea) book in Finder.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { Book.readableExtensions.contains($0.pathExtension.lowercased()) }) else { return }
        Task { @MainActor in await AppModel.shared.open(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Writes the open scene to disk and takes a snapshot before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppModel.shared.session != nil else { return .terminateNow }
        Task { @MainActor in
            await AppModel.shared.closeBook()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
