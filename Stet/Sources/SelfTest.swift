import AppKit
import PDFKit
import Foundation
import StetCore
import SwiftUI

/// Automated checks against the real app, WebKit and git. Both print a JSON report and exit
/// (0 = all checks passed). Neither prints any manuscript text.
///
///   Stet --selftest                     editor bridge: byte-exact round trips, settings, large texts
///   Stet --selftest-window [<folder>]   full-screen capability, navigator rows after zooming and in
///                                       full screen; optional snapshots of Stet's own windows
///   Stet --selftest-book <folder>       imports <folder> into a temporary book and drives the whole
///                                       flow: scenes, edit, version, note, snapshot, history, restore,
///                                       structure, health. The temporary book is deleted afterwards;
///                                       <folder> is only read.
enum SelfTest {
    /// True while a self-test runs; its temporary books stay out of "recently opened".
    private(set) static var isRunning = false

    static func startIfRequested() {
        let args = CommandLine.arguments
        isRunning = args.contains("--selftest") || args.contains("--selftest-book") || args.contains("--selftest-window")
        if isRunning {
            // Never the user's key or the real timestamp services in a self-test (memory only).
            MainActor.assumeIsolated {
                ProofSettings.shared.beginTemporary(signing: nil, timestamps: false, authorities: [], client: TimestampClient(transport: { _, _ in
                    throw URLError(.cancelled)
                }))
            }
        }
        if args.contains("--selftest") {
            armWatchdog()
            Task { @MainActor in
                await AppModel.shared.editor.waitUntilReady()
                await runBridge(editor: AppModel.shared.editor)
            }
        } else if let flag = args.firstIndex(of: "--preview-html"), args.indices.contains(flag + 2) {
            // Writes the Quick Look preview page of a book to a file (for checking it in a browser).
            let book = URL(fileURLWithPath: args[flag + 1])
            do {
                let summary = try BookSummary.read(book)
                let html = BookPreviewHTML.render(summary, coverSource: summary.coverURL?.absoluteString)
                try Data(html.utf8).write(to: URL(fileURLWithPath: args[flag + 2]))
                exit(0)
            } catch {
                print(error.localizedDescription)
                exit(1)
            }
        } else if let flag = args.firstIndex(of: "--selftest-window") {
            armWatchdog(seconds: 90)
            let next = args.indices.contains(flag + 1) ? args[flag + 1] : nil
            let output = next.flatMap { $0.hasPrefix("--") ? nil : URL(fileURLWithPath: $0) }
            let experiment = args.contains("--experiment")
            Task { @MainActor in await runWindow(snapshots: output, inExperiment: experiment) }
        } else if let flag = args.firstIndex(of: "--selftest-book"), args.indices.contains(flag + 1) {
            armWatchdog(seconds: 120)
            let source = URL(fileURLWithPath: args[flag + 1])
            Task { @MainActor in await runBookFlow(source: source) }
        }
    }

    private static func armWatchdog(seconds: Double = 30) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            print(#"{"ok": false, "failures": ["timeout"]}"#)
            removeTemporaryFolders()
            exit(2)
        }
    }

    /// Temporary folders (with a copy of the imported manuscript) to delete before exiting:
    /// `exit()` skips `defer`, so every way out removes them explicitly.
    private static var temporaryFolders: [URL] = []

    private static func temporaryFolder(_ prefix: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryFolders.append(url)
        return url
    }

    private static func removeTemporaryFolders() {
        for url in temporaryFolders { try? FileManager.default.removeItem(at: url) }
        temporaryFolders.removeAll()
    }

    /// Runs a command-line tool; stdout and stderr together (the self-test only looks for markers).
    private static func runTool(_ path: String, _ arguments: [String], input: URL? = nil, in folder: URL) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = folder
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = input.flatMap { try? FileHandle(forReadingFrom: $0) } ?? FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private static func finish(_ report: [String: Any], failures: [String]) -> Never {
        removeTemporaryFolders()
        var report = report
        report["failures"] = failures
        report["ok"] = failures.isEmpty
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8)
        {
            print(json)
        }
        exit(failures.isEmpty ? 0 : 1)
    }

    // MARK: - Editor bridge

    @MainActor
    static func runBridge(editor: EditorController) async {
        var report: [String: Any] = [:]
        var failures: [String] = []
        let savedSettings = editor.settings

        let sample = (try? String(contentsOf: EditorResources.sampleURL, encoding: .utf8)) ?? ""
        let cases: [(String, String)] = [
            ("sample", sample),
            ("nfdUmlauts", "Gru\u{0308}ße aus Mu\u{0308}nchen"),
            ("emojiAndTypography", "Ein Satz 🌊 mit Emoji, ‚Zitat‘ und »Guillemets« – …\n"),
            ("whitespace", "Zeile mit Leerzeichen   \n\tEingerückt\n\n\n"),
            ("criticEdgeCases", "{>><<} {==leer==}{>><<} {>>@A: b<<}{>>TODO<<} {== ==}"),
            ("noFinalNewline", "Ende ohne Zeilenumbruch"),
        ]
        var roundTrip: [String: Bool] = [:]
        for (name, text) in cases {
            try? await editor.load(text)
            let identical = ((try? await editor.text()) ?? "").utf8.elementsEqual(text.utf8)
            roundTrip[name] = identical
            if !identical { failures.append("round trip: \(name)") }
        }
        report["roundTrip"] = roundTrip

        try? await editor.load(sample)
        try? await Task.sleep(for: .milliseconds(400))
        report["sampleWords"] = editor.words
        if editor.words == 0 { failures.append("stats message") }

        editor.settings.font = .sans
        await editor.applySettings()
        let applied = (try? await editor.call("return window.stet.getSettings()")) as? [String: Any]
        if applied?["font"] as? String != "sans" { failures.append("settings") }
        editor.settings = savedSettings
        await editor.applySettings()

        try? await editor.load(sample)
        for words in [15_000, 60_000] {
            report["stress\(words)"] = try? await editor.stressTest(words: words)
        }
        finish(report, failures: failures)
    }

    // MARK: - Window: full screen and resizing

    /// Opens a small test book, checks that the window can go full screen and that the
    /// navigator keeps its rows when the window is zoomed. With a folder, it also writes
    /// snapshots of the window contents there (before.png, zoomed.png).
    @MainActor
    static func runWindow(snapshots folder: URL?, inExperiment: Bool = false) async {
        var report: [String: Any] = [:]
        var failures: [String] = []
        func check(_ ok: Bool, _ name: String) {
            report[name] = ok
            if !ok { failures.append(name) }
        }
        let fm = FileManager.default
        let work = temporaryFolder("StetWindowTest")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let model = AppModel.shared
        await model.editor.waitUntilReady()
        try? await Task.sleep(for: .seconds(0.5))
        if let welcome = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
            report["welcomeFullScreenPrimary"] = welcome.collectionBehavior.contains(.fullScreenPrimary)
            report["welcomeResizable"] = welcome.styleMask.contains(.resizable)
            report["welcomeZoomButtonEnabled"] = welcome.standardWindowButton(.zoomButton)?.isEnabled ?? false
        }
        do {
            let book = try await Book.create(at: work.appendingPathComponent("Fenstertest.stet"), title: "Fenstertest", author: "Test")
            for title in ["Zweites Kapitel", "Drittes Kapitel"] {
                let chapter = try book.addChapter(title: title, after: book.manifest.chapters.last?.id)
                _ = try book.addScene(toChapter: chapter.id, after: chapter.sceneIDs.first)
            }
            try await book.saveVersion()
            await model.open(book.url)
            if inExperiment {
                await model.session?.startExperiment(named: "Kapitel drei aus Maras Sicht", carryChanges: false)
                report["onExperiment"] = model.session?.isOnExperiment ?? false
            }
        } catch {
            finish(["error": error.localizedDescription], failures: ["setup"])
        }
        try? await Task.sleep(for: .seconds(1.5))

        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title.contains("Fenstertest") }) ?? NSApp.mainWindow else {
            finish(report, failures: ["no window"])
        }
        let behavior = window.collectionBehavior
        report["styleMaskResizable"] = window.styleMask.contains(.resizable)
        report["zoomButtonEnabled"] = window.standardWindowButton(.zoomButton)?.isEnabled ?? false
        report["windowClass"] = String(describing: type(of: window))
        report["fullScreenPrimary"] = behavior.contains(.fullScreenPrimary)
        report["fullScreenNone"] = behavior.contains(.fullScreenNone)
        report["fullScreenAuxiliary"] = behavior.contains(.fullScreenAuxiliary)
        report["contentMaxSize"] = "\(window.contentMaxSize)"
        report["maxSize"] = "\(window.maxSize)"
        report["frame"] = "\(window.frame)"
        report["screen"] = "\(window.screen?.visibleFrame ?? .zero)"
        check(behavior.contains(.fullScreenPrimary) && !behavior.contains(.fullScreenNone), "canGoFullScreen")

        func rows() -> [String: Any] {
            var tables: [NSTableView] = []
            func collect(_ view: NSView) {
                if let table = view as? NSTableView { tables.append(table) }
                view.subviews.forEach(collect)
            }
            window.contentView.map(collect)
            guard let table = tables.first else { return ["tables": 0] }
            let visible = table.rows(in: table.visibleRect)
            return [
                "tables": tables.count,
                "rows": table.numberOfRows,
                "visibleRows": visible.length,
                "tableFrame": "\(table.frame)",
                "clipBounds": "\(table.enclosingScrollView?.contentView.bounds ?? .zero)",
                "scrollFrame": "\(table.enclosingScrollView?.frame ?? .zero)",
            ]
        }
        /// The window's real pixels (an app may capture its own windows).
        func snapshot(_ name: String) {
            guard let folder,
                  let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .nominalResolution])
            else { return }
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name).png"))
        }

        // Optional: snapshot a sheet (e.g. --sheet server), then close it.
        var standalone: NSWindow?
        if let flag = CommandLine.arguments.firstIndex(of: "--sheet"), CommandLine.arguments.indices.contains(flag + 1),
           let session = model.session
        {
            switch CommandLine.arguments[flag + 1] {
            case "server": session.sheet = .server
            case "backup": session.sheet = .backup
            case "wiki":
                var mara = session.createWiki(title: "Mara Kessler", kind: .character)
                mara?.aliases = ["Mara", "die Kapitänin"]
                mara?.facts = [Fact("Geboren", "1921"), Fact("Augen", "grau"), Fact("Herkunft", "[[Hamburg]]")]
                mara?.body = "Kam 1953 als Leuchtturmwärterin auf die Insel."
                if let mara { session.saveWiki(mara) }
                _ = session.createWiki(title: "Hamburg", kind: .place)
                _ = session.createWiki(title: "Leuchtfeuer", kind: .term)
                model.openWiki(mara?.id)
            case "export": session.sheet = .export
            case "spelling-review":
                // Sample text (never the manuscript).
                try? await model.editor.replaceText("Ein ganz normaler Satzz mit Feler.\n\nDas Fensterr stand offen, und das Fensterr klapperte.\n")
                try? await Task.sleep(for: .milliseconds(300))
                await session.persist()
                model.openWindowAction?(id: "spelling")
                await session.reviewSpelling()
                try? await Task.sleep(for: .seconds(1))
                standalone = NSApp.windows.first { $0.isVisible && $0.title.hasPrefix("Rechtschreibung") }
            case "spelling":
                // Sample text (never the manuscript): mistakes in every paragraph, a wiki name, a comment.
                _ = session.createWiki(title: "Xyzzyblub Kessler", kind: .character)
                for name in ["Gabriela", "Andrea", "Andreas", "Hans"] { _ = session.createWiki(title: name, kind: .character) }
                if var andrea = session.wiki.first(where: { $0.title == "Andrea" }) {
                    andrea.notMeant = ["Andreas"]
                    session.saveWiki(andrea)
                }
                await session.pushWikiTerms()
                try? await model.editor.load("Ein ganz normaler Satzz mit Feler.\n\nHier steht Xyzzyblub und Xyzzyblubs Boot.{>>Komentar von Gisela<<}\n\nGabriela's Auto, Andreas's Laden, Andrea's Blumenladen, Andreas' Restaurant und Hansens Hut.\n")
                report["spellingMarks"] = await session.checkSpellingNow()
                report["hints"] = session.currentHints.map { "\($0.word) → \($0.suggestion)" }
                report["wikiTerms"] = ((try? await model.editor.call("return [...document.querySelectorAll('.stet-wiki-term')].map(e => e.textContent)")) as? [String]) ?? []
                window.makeFirstResponder(model.editor.webView)
                try? await Task.sleep(for: .seconds(1))
                snapshot("spelling")
                report["editMenu"] = NSApp.mainMenu?.items.first { $0.submenu?.items.contains { $0.action == #selector(NSText.copy(_:)) } == true }?
                    .submenu?.items.map { $0.title } ?? []
                try? await Task.sleep(for: .seconds(1))
                snapshot("spelling")
            case "settings", "signing":
                // Example values only (never this Mac's keys or certificates on a picture).
                let example = SigningSetup(method: .stetKey(path: "/dev/null"), label: "Stet-Schlüssel dieses Macs",
                                           fingerprint: "SHA256:k3PqBeispielFingerabdruck0123456789abcdefXYZ")
                ProofSettings.shared.beginTemporary(signing: example, timestamps: true, authorities: TimestampAuthority.defaults,
                                                    client: TimestampClient(transport: { _, _ in throw URLError(.cancelled) }))
                let discovery = SigningDiscovery(options: [
                    SigningOption(kind: .stetKey, title: "Stet-Schlüssel für diesen Mac", detail: "wird beim Einrichten angelegt (MacBook)", setup: nil),
                    SigningOption(kind: .smime, title: "S/MIME: Erika Mustermann (erika@example.com)", detail: "ausgestellt von Beispiel CA · gültig bis 01.06.27",
                                  setup: SigningSetup(method: .smime(program: "/x", certificateID: "1"), label: "S/MIME: Erika", fingerprint: "1", email: "erika@example.com")),
                    SigningOption(kind: .sshAgent, title: "Secretive: Schreibtisch-Mac", detail: "SHA256:Beispiel0123456789",
                                  setup: SigningSetup(method: .sshAgent(socket: "/x", publicKey: "x"), label: "Secretive", fingerprint: "2")),
                ], hasSmimesign: true)
                let root: AnyView = CommandLine.arguments[flag + 1] == "settings"
                    ? AnyView(ProofSettingsView(settings: .shared).frame(width: 600, height: 640))
                    : AnyView(SigningSetupSheet(settings: .shared, preview: discovery))
                let extra = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 640), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                extra.title = "Stet-Selbsttest"
                extra.isReleasedWhenClosed = false
                extra.contentView = NSHostingView(rootView: root)
                extra.setContentSize(extra.contentView?.fittingSize ?? NSSize(width: 600, height: 640))
                extra.center()
                extra.makeKeyAndOrderFront(nil)
                standalone = extra
            case "server-key":
                _ = await session.createKey()
                session.sheet = .server
            default: break
            }
            try? await Task.sleep(for: .seconds(1.5))
            if let folder, let sheetWindow = standalone ?? window.attachedSheet ?? NSApp.windows.first(where: { $0.isVisible && $0.title.hasPrefix("Wiki") }),
               let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(sheetWindow.windowNumber), [.boundsIgnoreFraming, .nominalResolution])
            {
                try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("sheet.png"))
            }
            standalone?.close()
            await session.removeKey()
            session.sheet = nil
            try? await Task.sleep(for: .seconds(0.5))
        }
        report["contentMinSize"] = "\(window.contentMinSize)"
        report["minSize"] = "\(window.minSize)"

        // Start from a smaller window, like a user would before clicking the green button.
        if let visible = window.screen?.visibleFrame {
            window.setFrame(CGRect(x: visible.minX + 60, y: visible.minY + 60, width: 1100, height: 720), display: true)
            try? await Task.sleep(for: .seconds(1))
        }
        report["frameSmall"] = "\(window.frame)"
        report["minSizeSmall"] = "\(window.minSize) / content \(window.contentMinSize)"
        report["maxSizeSmall"] = "\(window.maxSize) / content \(window.contentMaxSize)"
        report["fullScreenPrimarySmall"] = window.collectionBehavior.contains(.fullScreenPrimary)
        let before = rows()
        report["navigatorBefore"] = before
        snapshot("before")

        window.zoom(nil)
        try? await Task.sleep(for: .seconds(1.5))
        let zoomed = rows()
        report["navigatorZoomed"] = zoomed
        report["frameZoomed"] = "\(window.frame)"
        snapshot("zoomed")
        report["fullScreenPrimaryZoomed"] = window.collectionBehavior.contains(.fullScreenPrimary)
        report["maxSizeZoomed"] = "\(window.maxSize) / content \(window.contentMaxSize)"
        check((zoomed["visibleRows"] as? Int ?? 0) > 0 && (zoomed["visibleRows"] as? Int) == (before["visibleRows"] as? Int), "navigatorSurvivesZoom")

        window.zoom(nil)
        try? await Task.sleep(for: .seconds(1))

        // What the green button does: full screen. The window must be key, as it is when clicked.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .seconds(1))
        window.toggleFullScreen(nil)
        try? await Task.sleep(for: .seconds(5))
        // Informational: macOS only lets a frontmost app enter full screen, and a test started from
        // a terminal may not be allowed to come to the front.
        report["enteredFullScreen"] = window.styleMask.contains(.fullScreen)
        report["navigatorFullScreen"] = rows()
        report["frameFullScreen"] = "\(window.frame)"
        snapshot("fullscreen")
        report["windowsFullScreen"] = NSApp.windows.map {
            "\(type(of: $0)) visible=\($0.isVisible) alpha=\($0.alphaValue) level=\($0.level.rawValue) frame=\($0.frame)"
        }
        let options = NSApp.currentSystemPresentationOptions
        report["autoHideToolbar"] = options.contains(.autoHideToolbar)
        report["autoHideMenuBar"] = options.contains(.autoHideMenuBar)
        report["fullScreenToolbarFrame"] = NSApp.windows.first { String(describing: type(of: $0)).contains("ToolbarFullScreen") }.map { "\($0.frame) visible=\($0.isVisible)" } ?? "none"
        report["mainContentLayoutRect"] = "\(window.contentLayoutRect)"
        report["toolbarVisible"] = window.toolbar?.isVisible ?? false
        report["toolbarItems"] = window.toolbar?.items.count ?? -1
        // In full screen the toolbar lives in its own window; capture that one too (only Stet's own windows).
        if let folder, let toolbarWindow = NSApp.windows.first(where: { String(describing: type(of: $0)).contains("ToolbarFullScreen") }),
           let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(toolbarWindow.windowNumber), [.boundsIgnoreFraming, .nominalResolution])
        {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("fullscreen-toolbar.png"))
        }
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
            try? await Task.sleep(for: .seconds(2))
        }
        snapshot("after")
        await model.closeBook()
        finish(report, failures: failures)
    }

    // MARK: - Whole book flow

    @MainActor
    static func runBookFlow(source: URL) async {
        let model = AppModel.shared
        let editor = model.editor
        var report: [String: Any] = [:]
        var failures: [String] = []
        func check(_ ok: Bool, _ name: String) {
            report[name] = ok
            if !ok { failures.append(name) }
        }

        let fm = FileManager.default
        let work = temporaryFolder("StetSelfTest")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        let destination = work.appendingPathComponent("Selbsttest.stet")
        defer { try? fm.removeItem(at: work) }

        // Signatures and timestamps only ever with a throwaway key and a local authority: nothing
        // derived from the manuscript reaches a real service, and the user's settings stay as they are.
        SSHKey.folder = work.appendingPathComponent("Keys")
        let localTSA = try? LocalTestTSA(in: work.appendingPathComponent("TSA"))
        check(localTSA != nil, "localTimestampAuthority")
        let offline = TimestampClient(transport: { _, _ in throw URLError(.cancelled) })
        let testAuthorities = [TimestampAuthority(name: "Test A", url: "http://a.test"), TimestampAuthority(name: "Test B", url: "http://b.test")]
        ProofSettings.shared.beginTemporary(signing: nil, timestamps: localTSA != nil, authorities: testAuthorities, client: localTSA?.client ?? offline)

        await editor.waitUntilReady()
        let sourceGit = Git(directory: source)
        let sourceHeadBefore = await sourceGit.headCommit()
        let sourceStatusBefore = (try? await sourceGit.run(["status", "--porcelain"]).string) ?? "?"

        // Import
        let start = Date()
        guard let imported = await model.importFolder(source, to: destination), let session = model.session else {
            failures.append("import: \(model.errorMessage ?? "unknown")")
            finish(report, failures: failures)
        }
        model.importReport = nil
        let book = session.book
        report["importSeconds"] = (Date().timeIntervalSince(start) * 10).rounded() / 10
        report["import"] = [
            "chapters": imported.chapters, "scenes": imported.scenes, "words": imported.words,
            "commitsKept": imported.commitsKept, "experiments": imported.experiments.count,
            "shelvedExperiments": imported.shelvedExperiments.count,
            "moved": imported.moved.count, "removed": imported.removed.count, "warnings": imported.warnings.count,
        ]
        report["sourceSyncService"] = SyncLocation.detect(source)?.service ?? "none"

        // Every scene loads into the editor byte for byte, and browsing changes nothing.
        let ids = session.manifest.sceneIDs
        check(session.selectedSceneID == ids.first, "firstSceneSelected")
        var roundTrips = 0
        var wordMismatch: [Int] = []
        for id in ids {
            await session.select(id)
            let inEditor = (try? await editor.text()) ?? ""
            let onDisk = (try? book.readScene(id).body) ?? "-"
            if inEditor.utf8.elementsEqual(onDisk.utf8) { roundTrips += 1 }
            let js = ((try? await editor.call("return window.stet.stats()")) as? [String: Any])?["words"] as? NSNumber
            let swift = TextStats.words(in: onDisk)
            if let js, js.intValue != swift { wordMismatch.append(js.intValue - swift) }
        }
        check(roundTrips == ids.count, "allScenesRoundTrip")
        report["wordCountDifferencesJsMinusSwift"] = wordMismatch
        let browsingChanges = (try? await book.git.changedPaths()) ?? ["?"]
        check(browsingChanges.isEmpty, "browsingLeavesNoChanges")

        // Edit, save a version, add a note.
        guard let first = ids.first else { finish(report, failures: failures + ["no scenes"]) }
        await session.select(first)
        let original = (try? await editor.text()) ?? ""
        try? await editor.replaceText(original + "\n\nEin Satz aus dem Selbsttest.")
        try? await Task.sleep(for: .milliseconds(300))
        await session.saveVersion()
        let head = try? await book.git.log(limit: 1).first
        check(head?.subject.hasPrefix("Bearbeitet: ") == true, "versionSubject")
        check(head?.trailers["Stet-Words-Delta"] == "+5", "versionWordsDelta")
        check(head?.trailers["Stet-Scenes"] == first, "versionScenes")
        if let head {
            await session.addNote("Selbsttest-Notiz", to: head.hash)
            let noted = try? await book.git.log(limit: 1).first
            check(noted?.note == "Selbsttest-Notiz", "note")
        }
        await session.saveVersion()
        check(session.toast?.message == "Keine Änderungen seit der letzten Version", "noEmptyVersions")

        // Snapshot of unsaved work, without moving the branch.
        try? await editor.replaceText(original + "\n\nNoch nicht als Version gesichert.")
        await session.persistAndSnapshot()
        check(await book.git.resolve(Book.snapshotRef(device: DeviceID.current)) != nil, "snapshot")
        check(await book.git.headCommit() == head?.hash, "snapshotLeavesBranch")

        // History follows the import back into the original repository.
        await session.loadHistory()
        let history = session.history
        report["historyEntries"] = history.count
        check(history.contains(where: \.isSnapshot), "historyHasSnapshot")
        if imported.commitsKept > 0 {
            check(history.contains { !$0.path.hasPrefix(Book.scenesFolder + "/") }, "historyReachesPreImport")
        }

        // Compare with the oldest version and restore it.
        if let oldest = history.last {
            await session.compare(with: oldest)
            if let comparison = session.comparison {
                report["oldestDiffWords"] = ["inserted": comparison.summary.insertedWords, "removed": comparison.summary.removedWords]
                await session.restore(comparison)
                let restored = (try? await editor.text()) ?? ""
                check(restored == comparison.oldText, "restoreInEditor")
                check(((try? book.readScene(first).body) ?? "") == comparison.oldText, "restoreOnDisk")
            } else {
                check(false, "comparison")
            }
        }

        // Structure: add a chapter and a scene, move, remove.
        let chaptersBefore = session.manifest.chapters.count
        let scenesBefore = session.manifest.sceneIDs.count
        session.addChapter(after: session.manifest.chapters.last?.id)
        check(session.manifest.chapters.count == chaptersBefore + 1, "addChapter")
        session.addScene(after: first)
        try? await Task.sleep(for: .milliseconds(300))
        check(session.manifest.sceneIDs.count == scenesBefore + 2, "addScene")
        if let added = session.selectedSceneID, let target = session.manifest.chapters.last?.id {
            session.moveScene(added, toChapter: target)
            check(session.manifest.chapter(containing: added)?.id == target, "moveScene")
            await session.deleteScene(added)
            check(!session.manifest.sceneIDs.contains(added), "deleteScene")
        }
        if let last = session.manifest.chapters.last?.id {
            session.removeChapter(last)
            check(session.manifest.chapters.count == chaptersBefore, "removeChapter")
        }
        await session.saveVersion()
        let structureVersion = try? await book.git.log(limit: 1).first
        check(structureVersion?.subject.contains("Struktur geändert") == true, "structureVersion")

        // Experiments: start one, edit the same paragraph there and in the main version,
        // adopt it with a decision, set a milestone, shelve the experiment.
        func editFirstParagraph(_ addition: String) async {
            let text = (try? await editor.text()) ?? ""
            let changed = text.range(of: "\n").map { text[..<$0.lowerBound] + addition + text[$0.lowerBound...] } ?? Substring(text + addition)
            try? await editor.replaceText(String(changed))
            try? await Task.sleep(for: .milliseconds(300))
        }
        await session.select(first)
        let mainText = (try? await editor.text()) ?? ""
        await session.startExperiment(named: "Selbsttest Experiment", carryChanges: false)
        check(session.isOnExperiment, "experimentStarted")
        await editFirstParagraph(" (Experiment)")
        await session.saveVersion()
        await session.switchTo(session.mainBranch)
        check(!session.isOnExperiment, "backOnMain")
        check(((try? await editor.text()) ?? "") == mainText, "mainUntouchedByExperiment")
        await editFirstParagraph(" (Hauptfassung)")
        await session.saveVersion()

        if let experiment = session.activeExperiments.first(where: { $0.name == "Selbsttest Experiment" }) {
            await session.adoptAll(experiment)
            check(session.adoption?.conflicts.count == 1, "adoptionHasOneConflict")
            if let conflict = session.adoption?.conflicts.first, case .text(let segments) = conflict.kind {
                for (index, segment) in segments.enumerated() {
                    if case .conflict = segment { session.choose(.experiment, for: conflict, passage: index) }
                }
            }
            if let open = session.adoption {
                report["adoptionOpenBeforeFinish"] = open.openCount
                report["adoptionConflictKinds"] = open.conflicts.map { conflict -> String in
                    if case .text = conflict.kind { return "text \(conflict.path)" }
                    return "\(conflict.kind)".prefix(60).description + " " + conflict.path
                }
            }
            await session.finishAdoption()
            if session.adoption != nil { report["adoptionError"] = String((session.errorMessage ?? "none").prefix(200)) }
            check(session.adoption == nil, "adoptionFinished")
            let adopted = (try? await editor.text()) ?? ""
            check(adopted.contains("(Experiment)") && !adopted.contains("(Hauptfassung)"), "decisionApplied")
            check(!adopted.contains("<<<<<<<") && !adopted.contains(">>>>>>>"), "noConflictMarkers")
            check(((try? await book.git.log(limit: 1).first)?.parents.count) == 2, "adoptionIsMerge")
        } else {
            check(false, "experimentListed")
        }
        await session.setMilestone(name: "Selbsttest Meilenstein", note: "")
        check(session.milestones.contains { $0.name == "Selbsttest Meilenstein" }, "milestone")
        if let experiment = session.activeExperiments.first(where: { $0.name == "Selbsttest Experiment" }) {
            await session.shelve(experiment)
        }
        check(session.shelvedExperiments.contains { $0.name == "Selbsttest Experiment" }, "shelved")

        // Export every format (only file facts are reported, never text).
        var exports: [String: Any] = [:]
        for format in ExportFormat.allCases where Exporter.missingTools(for: format).isEmpty {
            let target = work.appendingPathComponent("Export/Buch.\(format.fileExtension)")
            var options = ExportOptions(format: format, quotes: session.defaultExportQuotes)
            options.commentsAsAnnotations = format == .docx
            if let result = await session.export(options, to: target) {
                let size = ((try? fm.attributesOfItem(atPath: result.file.path)[.size]) as? NSNumber)?.intValue ?? 0
                var entry: [String: Any] = ["bytes": size, "tag": result.tag]
                if format == .pdfBook || format == .pdfManuscript, let pdf = PDFDocument(url: result.file) {
                    entry["pages"] = pdf.pageCount
                    entry["stampOnPages"] = (pdf.string ?? "").components(separatedBy: "Fassung \(result.stamp.shortCommit)").count - 1
                }
                exports[format.rawValue] = entry
                check(size > 0, "export-\(format.rawValue)")
            } else {
                check(false, "export-\(format.rawValue): \(session.errorMessage ?? "")")
                session.errorMessage = nil
            }
        }
        report["exports"] = exports
        check(session.milestones.filter(\.isExport).count == exports.count, "exportsMarkedInHistory")

        // Notes and feedback: comment + TODO, finish the TODO, round trip through Word, place the
        // comment again, a feedback entry with an attachment, compare with the version it refers to.
        await session.select(first)
        await session.loadNotes()
        let notesBefore = session.notes.count
        await editor.select(from: 0, to: 24)
        try? await editor.insertComment("@Gisela: Selbsttest-Kommentar")
        await editor.select(from: 0, to: 0)
        try? await editor.insertComment("TODO: Selbsttest-Aufgabe")
        await session.loadNotes()
        check(session.notes.count == notesBefore + 2, "notesFound")
        if let todo = session.notes.first(where: { $0.kind == .todo && $0.text == "Selbsttest-Aufgabe" }) {
            await session.resolve(todo)
            let textAfter = (try? await editor.text()) ?? ""
            check(!session.notes.contains { $0.text == "Selbsttest-Aufgabe" } && !textAfter.contains("Selbsttest-Aufgabe"), "todoResolved")
        } else {
            check(false, "todoListed")
        }
        var docxOptions = ExportOptions(format: .docx, quotes: session.defaultExportQuotes)
        docxOptions.commentsAsAnnotations = true
        let review = work.appendingPathComponent("Export/Zurueck.docx")
        if Exporter.missingTools(for: .docx).isEmpty, let exported = await session.export(docxOptions, to: review) {
            // Today's text without the comment, as if it had been answered in the meantime.
            if let comment = session.notes.first(where: { $0.text == "Selbsttest-Kommentar" }) { await session.resolve(comment) }
            let entry = await session.importWord(exported.file, from: "Gisela", refersTo: exported.tag, note: "")
            let wordComment = entry?.wordComments.first { $0.text == "Selbsttest-Kommentar" }
            check(wordComment != nil && wordComment?.anchor.isEmpty == false, "wordCommentRead")
            if let entry, let wordComment {
                let placed = await session.place(wordComment, of: entry)
                await session.loadNotes()
                check(placed && session.notes.contains { $0.text == "Selbsttest-Kommentar" && $0.author == "Gisela" && $0.highlighted != nil }, "wordCommentPlacedAtItsPassage")
                check(session.feedback.first { $0.id == entry.id }?.wordComments.first { $0.text == "Selbsttest-Kommentar" }?.placed == true, "wordCommentMarkedPlaced")
                await session.compareWithFeedbackVersion(entry)
                check(session.comparison != nil, "compareWithFeedbackVersion")
                session.comparison = nil
            }
        }
        let photo = work.appendingPathComponent("Foto vom Ausdruck.jpg")
        try? Data("JPEG".utf8).write(to: photo)
        let note = session.addFeedback(from: "Horst", received: Date(), refersTo: session.latestExportTag, text: "Schön!", attachments: [photo])
        check(note != nil && fm.fileExists(atPath: session.attachmentURL(note?.attachments.first ?? "-").path), "feedbackWithAttachment")
        await session.saveVersion()
        check(((try? await book.git.log(limit: 1).first)?.subject.contains("Feedback")) == true, "feedbackInVersion")
        report["notesAfter"] = session.notes.count - notesBefore
        report["feedbackEntries"] = session.feedback.count

        // Wiki: an entry from a selected name, underlined in the editor, appearances; scene facts.
        await session.select(first)
        let prose = (try? await editor.text()) ?? ""
        let nameRegex = try! NSRegularExpression(pattern: #"(?<![\p{L}])\p{Lu}\p{Ll}{3,}(?![\p{L}])"#)
        let candidates = nameRegex.matches(in: prose, range: NSRange(location: 1, length: max(0, (prose as NSString).length - 1)))
        if let name = candidates.dropFirst(2).first {
            await editor.select(from: name.range.location, to: name.range.location + name.range.length)
            let entry = await session.wikiEntryFromSelection()
            check(entry != nil, "wikiEntryFromSelection")
            if let entry {
                check(!session.appearances(of: entry).isEmpty, "wikiAppearances")
                try? await Task.sleep(for: .milliseconds(300))
                let underlined = ((try? await editor.call("return document.querySelectorAll('.stet-wiki-term').length")) as? NSNumber)?.intValue ?? 0
                check(underlined > 0, "wikiNamesUnderlined")
                var edited = entry
                edited.facts = [Fact("Rolle", "Selbsttest")]
                session.saveWiki(edited)
                check(session.wiki.first { $0.id == entry.id }?.facts == [Fact("Rolle", "Selbsttest")], "wikiEntrySaved")
            }
        } else {
            check(false, "wikiCandidateName")
        }
        if let known = session.wiki.first(where: { $0.kind == .character }) {
            let open = session.contextMenuItems(text: known.title, wikiID: nil)
            check(open.first?.title == "„\(known.title)“ im Wiki öffnen", "contextMenuOpensKnownEntry")
            let byID = session.contextMenuItems(text: "", wikiID: known.id)
            check(byID.first?.title == "„\(known.title)“ im Wiki öffnen", "contextMenuOnUnderlinedName")
        }
        // The real path: a right-click in the editor tells Swift what was clicked, then the
        // native menu opens and gets the wiki items on top.
        func rightClick(_ selector: String) async -> NSMenu {
            _ = try? await editor.call("""
                const el = document.querySelector(selector); const r = el.getBoundingClientRect();
                el.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, button: 2,
                  clientX: r.left + r.width / 2, clientY: r.top + r.height / 2 }));
                """, ["selector": selector])
            try? await Task.sleep(for: .milliseconds(200))
            let menu = NSMenu()
            menu.addItem(withTitle: "Nachschlagen", action: nil, keyEquivalent: "")
            if let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                              windowNumber: editor.webView.window?.windowNumber ?? 0, context: nil,
                                              eventNumber: 0, clickCount: 1, pressure: 1) {
                editor.webView.willOpenMenu(menu, with: event)
            }
            return menu
        }
        await editor.select(from: 0, to: 0)
        let onName = await rightClick(".stet-wiki-term")
        check(onName.items.first?.title.hasSuffix("im Wiki öffnen") == true
              && onName.items.last?.title == "Nachschlagen", "rightClickOnUnderlinedName")
        if let other = candidates.dropFirst(5).first {
            await editor.select(from: other.range.location, to: other.range.location + other.range.length)
            let onSelection = await rightClick(".cm-content")
            // (A name the dictionary doesn't know gets spelling suggestions first.)
            check(onSelection.items.contains { $0.title.hasSuffix("ins Wiki aufnehmen") || $0.title.hasSuffix("im Wiki öffnen") }, "rightClickOnSelection")
        }
        let add = session.contextMenuItems(text: "Selbsttest-Ort,", wikiID: nil)
        check(add.first?.title == "„Selbsttest-Ort“ ins Wiki aufnehmen" && add.first?.submenu?.items.count == 4, "contextMenuOffersKinds")
        if let kinds = add.first?.submenu, let index = kinds.items.firstIndex(where: { $0.title == "als Ort" }) {
            kinds.performActionForItem(at: index)
            check(session.wiki.contains { $0.title == "Selbsttest-Ort" && $0.kind == .place }, "contextMenuCreatesEntry")
        }
        report["wikiEntries"] = session.wiki.count
        session.setFact("Datum", to: "14.3.1953")
        await session.persist()
        check(((try? book.readScene(first))?.factList.contains(Fact("Datum", "14.3.1953"))) == true, "sceneFactSaved")
        check(session.sceneFacts[first]?.contains(Fact("Datum", "14.3.1953")) == true, "sceneFactForNavigator")
        await session.saveVersion()
        check(((try? await book.git.log(limit: 1).first)?.subject.contains("Wiki")) == true, "wikiInVersion")

        // Spelling (only counts are reported, never words of the manuscript).
        await editFirstParagraph(" Fensterr Zwurbelmannn")
        let marks = await session.checkSpellingNow()
        check(marks >= 2, "spellingMarksShown")
        let editorText = (try? await editor.text()) ?? ""
        if let typo = (editorText as NSString).range(of: "Fensterr").nonEmpty {
            let items = session.spellingMenuItems(word: "Fensterr", range: typo)
            check(items.contains { $0.title == "„Fensterr“ für dieses Buch erlauben" }, "spellingMenuOffersAllow")
            check(items.first?.isEnabled == true && items.first?.title != "Keine Vorschläge", "spellingMenuHasSuggestions")
        }
        if let name = session.wiki.first(where: { $0.kind == .character }) {
            check(session.spelling?.isMisspelled(name.title) == false, "wikiNamesCountAsRight")
        }
        await session.reviewSpelling()
        report["spellingUnknownWords"] = session.spellingIssues.count
        if let typo = session.spellingIssues.first(where: { $0.word == "Fensterr" }),
           let guess = session.spelling?.guesses(for: typo.word).first
        {
            await session.replaceEverywhere(typo, with: guess)
            let after = (try? await editor.text()) ?? ""
            check(!after.contains("Fensterr") && after.contains(guess), "spellingReplacedEverywhere")
        } else {
            check(false, "spellingReviewFindsTypo")
        }
        session.allowWord("Zwurbelmannn")
        check(session.manifest.words?.contains("Zwurbelmannn") == true && !session.spellingIssues.contains { $0.word == "Zwurbelmannn" }, "spellingWordAllowedForBook")
        check(session.spelling?.isMisspelled("Zwurbelmannn") == false, "allowedWordCountsAsRight")
        await session.saveVersion()

        // German genitives: -ens, "not meant", the possessive apostrophe (invented names).
        _ = session.createWiki(title: "Zorbaline", kind: .character)
        _ = session.createWiki(title: "Pelux", kind: .character)
        if var velina = session.createWiki(title: "Velina", kind: .character) {
            velina.notMeant = ["Velinas"]
            session.saveWiki(velina)
        }
        await session.pushWikiTerms()
        await editFirstParagraph(" Zorbaline's Auto, Peluxens Hut, Velinas Boot.")
        await session.checkSpellingNow()
        let hint = session.currentHints.first { $0.word == "Zorbaline's" }
        check(hint?.suggestion == "Zorbalines", "apostropheHint")
        if let hint {
            check(session.hintMenuItems(at: NSRange(location: hint.range.location + 2, length: 0)).first?.title == "Zorbalines", "apostropheHintInMenu")
        }
        check(session.spelling?.isMisspelled("Peluxens") == false, "ensGenitiveSpelledRight")
        try? await Task.sleep(for: .milliseconds(300))
        let underlined = ((try? await editor.call("return [...document.querySelectorAll('.stet-wiki-term')].map(e => e.textContent)")) as? [String]) ?? []
        check(underlined.contains("Peluxens") && underlined.contains("Zorbaline's"), "ensGenitiveRecognised")
        check(!underlined.contains("Velinas"), "notMeantNotUnderlined")

        // Taking the wiki along: from another book into this one.
        if let other = try? await Book.create(at: work.appendingPathComponent("Band 2.stet"), title: "Band 2", author: "Test") {
            _ = try? other.createWiki(title: "Selbsttest-Fortsetzung", kind: .place)
            if let existing = session.wiki.first { _ = try? other.createWiki(title: existing.title, kind: existing.kind) }
            let before = session.wiki.count
            let imported = session.importWiki(from: other.url)
            check(imported?.added == ["Selbsttest-Fortsetzung"] && imported?.skipped.count == 1 && session.wiki.count == before + 1, "wikiImportedFromOtherBook")
            session.wikiNotice = nil
            let archive = work.appendingPathComponent("Wiki.zip")
            check((try? book.exportWiki(to: archive)) != nil && ((try? Book.wikiEntries(at: archive))?.count ?? 0) == session.wiki.count, "wikiExported")
            await session.saveVersion()
        }

        // Backups: automatic (once a day), by hand, restore.
        var backupSettings = session.backupSettings
        backupSettings.automatic = true
        backupSettings.folder = work.appendingPathComponent("Backups")
        backupSettings.keep = 2
        session.save(backupSettings)
        await session.maybeAutoBackup()
        check(Backup.list(in: backupSettings.folder, for: book).count == 1, "autoBackupCreated")
        await session.maybeAutoBackup()
        check(Backup.list(in: backupSettings.folder, for: book).count == 1, "autoBackupOncePerDay")
        for _ in 0..<2 { await session.backupToFolder() }
        check(Backup.list(in: backupSettings.folder, for: book).count == 2, "backupsRotated")
        if let latest = Backup.list(in: backupSettings.folder, for: book).first,
           let restored = try? await Backup.restore(latest.url, into: work.appendingPathComponent("Wiederhergestellt")),
           let copy = try? Book(url: restored)
        {
            let originalHead = await book.git.headCommit()
            let copyHead = await copy.git.headCommit()
            let copyCount = (try? await copy.git.log().count) ?? 0
            let originalCount = (try? await book.git.log().count) ?? -1
            check(copyHead == originalHead && copyCount == originalCount && copy.manifest == book.manifest, "backupRestoredComplete")
        } else {
            check(false, "backupRestore")
        }
        report["backupBytes"] = Backup.list(in: backupSettings.folder, for: book).first?.size ?? 0

        // Server: connect to a local test server; a "second Mac" (a clone) writes, this Mac brings it
        // in; then both change the same passage and the merge goes through the decision window.
        let server = work.appendingPathComponent("server.git")
        _ = try? await Git(directory: work).run(["init", "--quiet", "--bare", "--initial-branch=main", server.path])
        let connectError = await session.connectServer(server.path)
        check(connectError == nil, "serverConnected")
        func serverMain() async -> String? {
            try? await Git(directory: server).run(["rev-parse", "main"]).string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let localHead = await book.git.headCommit()
        let remoteHead = await serverMain()
        check(remoteHead != nil && remoteHead == localHead, "serverHasTheBook")
        let secondMac = try? await Book.clone(from: server.path, to: work.appendingPathComponent("ZweiterMac/Buch.stet"))
        check(secondMac != nil, "secondMacCloned")
        if let other = secondMac {
            if var scene = try? other.readScene(first) {
                scene.body += "\n\nVom zweiten Mac geschrieben."
                try? other.writeScene(scene)
            }
            _ = try? await other.saveVersion()
            _ = try? await other.sync(device: "selftest-second")
            await session.syncNow()
            check(((try? await editor.text()) ?? "").contains("Vom zweiten Mac geschrieben."), "secondMacTextArrived")

            // Both change the same passage.
            if var scene = try? other.readScene(first), let range = scene.body.range(of: "\n") {
                scene.body.insert(contentsOf: " (zweiter Mac)", at: range.lowerBound)
                try? other.writeScene(scene)
            }
            _ = try? await other.saveVersion()
            _ = try? await other.sync(device: "selftest-second")
            await editFirstParagraph(" (dieser Mac)")
            await session.saveVersion()
            for _ in 0..<40 where session.syncState != .needsMerge { try? await Task.sleep(for: .milliseconds(150)) }
            check(session.syncState == .needsMerge, "serverMergeDetected")
            await session.mergeWithServer()
            check(session.adoption?.fromServer == true, "serverConflictWindow")
            if let conflict = session.adoption?.conflicts.first, case .text(let segments) = conflict.kind {
                for (index, segment) in segments.enumerated() {
                    if case .conflict = segment { session.choose(.main, for: conflict, passage: index) }
                }
            }
            await session.finishAdoption()
            let mergedText = (try? await editor.text()) ?? ""
            check(mergedText.contains("(dieser Mac)") && !mergedText.contains("(zweiter Mac)") && !mergedText.contains("<<<<<<<"), "serverMergeDecisionApplied")
            for _ in 0..<40 where await serverMain() != (await book.git.headCommit()) { try? await Task.sleep(for: .milliseconds(150)) }
            let mergedRemote = await serverMain()
            let mergedLocal = await book.git.headCommit()
            check(mergedRemote == mergedLocal, "mergeSentToServer")
            let afterMerge = try? await other.sync(device: "selftest-second")
            check((try? other.readScene(first).body.contains("(dieser Mac)")) == true && afterMerge?.pulledVersions ?? 0 > 0, "secondMacGotTheMerge")
        }

        // Signatures and timestamps (throwaway key, local authority).
        func stampsSettled() async {
            for _ in 0..<60 where session.isStamping || session.pendingStampCount > 0 {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        await stampsSettled()
        await session.loadProofInfo()
        let allStamps = session.stamps.values.flatMap { $0 }
        check(allStamps.contains { $0.kind == .version }, "dailyStampAfterSaving")
        let milestoneCommit = session.milestones.first { $0.name == "Selbsttest Meilenstein" }?.commit
        check(milestoneCommit.map { !session.versionStamps($0).isEmpty } == true, "milestoneStamped")
        let epub = work.appendingPathComponent("Export/Buch.epub")
        if fm.fileExists(atPath: epub.path) {
            let found = (try? await book.stamps(forFile: epub)) ?? []
            check(found.count == testAuthorities.count, "exportedFileStamped")
            await session.check(file: epub)
            check(session.proofMessage?.contains("genau die Datei") == true, "fileCheckFindsStamp")
            session.proofMessage = nil
        }
        report["stamps"] = allStamps.count

        if let setup = try? Signing.makeStetKey() {
            ProofSettings.shared.signing = setup
            await session.signingChanged()
            check(!book.signers().isEmpty, "signerRegistered")
            await editFirstParagraph(" (signiert)")
            await session.saveVersion()
            let head = await book.git.headCommit() ?? ""
            await session.loadSignatures(for: [head])
            check(session.signatures[head]?.state == .good, "versionSigned")
            check(((try? await book.git.log(limit: 1).first)?.subject.contains("Signatur-Schlüssel")) == true, "signerKeyInVersion")
            check(session.signingProblem == nil, "noSigningProblem")
            await editFirstParagraph(" (Schnappschuss)")
            await session.persist()
            let snapshot = try? await book.snapshot(device: "selftest")
            if let snapshot {
                let state = await book.signatures(of: [snapshot])[snapshot]?.state
                check(state == .unsigned, "snapshotUnsigned")
            }

            await session.stampNow()  // saves the pending change first, then stamps that version
            await stampsSettled()
            let stamped = await book.git.headCommit() ?? ""
            await session.loadSignatures(for: [stamped])
            check(session.signatures[stamped]?.state == .good && session.versionStamps(stamped).count == testAuthorities.count, "stampNowSignedAndStamped")
            let proof = await session.writeProof(for: stamped, to: work.appendingPathComponent("Nachweis"), reveal: false)
            check(proof != nil, "proofWritten")
            if let proof, let localTSA {
                let sums = runTool("/usr/bin/shasum", ["-a", "256", "-c", "../Beleg.txt"], in: proof.appendingPathComponent("Buch"))
                check(sums.status == 0, "proofFilesMatchReceipt")
                let stampFile = (try? fm.contentsOfDirectory(atPath: proof.path))?.first { $0.hasPrefix("Zeitstempel – ") && $0.hasSuffix(".tsr") }
                let certificates = stampFile.map { "Zertifikate – " + $0.dropFirst("Zeitstempel – ".count).dropLast(4) + ".pem" }
                let verify = runTool("/usr/bin/openssl", ["ts", "-verify", "-data", "Beleg.txt", "-in", stampFile ?? "-",
                                                          "-CAfile", localTSA.caPEM.path, "-untrusted", certificates ?? "-"], in: proof)
                check(verify.output.contains("Verification: OK"), "proofStampVerifies")
                let readme = (try? String(contentsOf: proof.appendingPathComponent("LIESMICH.txt"), encoding: .utf8)) ?? ""
                check(readme.contains("Test A: ") && readme.contains("ssh-keygen -Y verify"), "proofReadme")
                let signatureCheck = runTool("/usr/bin/ssh-keygen", ["-Y", "verify", "-f", "Schlüssel.allowed_signers", "-I", "autor",
                                                                    "-n", "stet-nachweis", "-s", "Beleg.txt.sig"],
                                             input: proof.appendingPathComponent("Beleg.txt"), in: proof)
                check(signatureCheck.status == 0, "proofSignatureVerifies")
            }

            // A key that has gone missing: the version is still saved, without signature, and the writer hears about it.
            ProofSettings.shared.signing = SigningSetup(method: .stetKey(path: work.appendingPathComponent("weg").path), label: "weg", fingerprint: "SHA256:weg")
            await editFirstParagraph(" (ohne Signatur)")
            let before = await book.git.headCommit()
            await session.saveVersion()
            for _ in 0..<20 where session.signingProblem == nil { try? await Task.sleep(for: .milliseconds(50)) }
            let after = await book.git.headCommit()
            check(before != after && session.signingProblem != nil, "missingKeyStillSaves")
            ProofSettings.shared.signing = nil
        } else {
            check(false, "throwawaySigningKey")
        }

        // Health and location
        check((await HealthCheck.run(book)).isHealthy, "healthy")
        check(SyncLocation.detect(destination) == nil, "tempFolderNotSynced")

        // Close (writes and snapshots), then the source must be untouched.
        await model.closeBook()
        check(await sourceGit.headCommit() == sourceHeadBefore, "sourceHeadUnchanged")
        check(((try? await sourceGit.run(["status", "--porcelain"]).string) ?? "") == sourceStatusBefore, "sourceStatusUnchanged")
        report["versionsInBook"] = (try? await Git(directory: destination).log().count) ?? 0

        finish(report, failures: failures)
    }
}

private extension NSRange {
    /// nil for "not found".
    var nonEmpty: NSRange? { location == NSNotFound || length == 0 ? nil : self }
}
