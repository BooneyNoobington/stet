import AppKit
import ZadurCore
import SwiftUI

/// `Zadur --selftest-typing`: types into the inspector's details and a wiki entry's facts with
/// real key events, the way a person does, and watches the window meanwhile. Nothing may move
/// (the window, the editor, the fields, the inspector's scroll position), and the field being
/// typed in must keep the keyboard focus and get every character. Also: a new wiki entry from the
/// ＋ below its list, chapters as headings in the navigator, the inspector's tabs staying at the
/// top, the cover, find and replace. Uses a small test book of its own, deleted afterwards.
extension SelfTest {
    @MainActor
    static func runTyping() async {
        var report: [String: Any] = [:]
        var failures: [String] = []
        func check(_ ok: Bool, _ name: String) {
            report[name] = ok
            if !ok { failures.append(name) }
        }
        let work = temporaryFolder("ZadurTypingTest")
        let model = AppModel.shared
        await model.editor.waitUntilReady()
        try? await Task.sleep(for: .seconds(0.5))
        do {
            let book = try await Book.create(at: work.appendingPathComponent("Tipptest.crea"), title: "Tipptest", author: "Test")
            if let first = book.manifest.sceneIDs.first, var scene = try? book.readScene(first) {
                scene.body = "Der Regen hatte am Morgen aufgehört. Mara kam spät, niemand wartete auf MARA.\n"
                _ = try book.writeScene(scene)
            }
            let chapter = try book.addChapter(title: "Zweites Kapitel", after: book.manifest.chapters.last?.id)
            let last = try book.addScene(toChapter: chapter.id, after: chapter.sceneIDs.first)
            if var scene = try? book.readScene(last.id) {
                scene.body = "Am Abend las mara den Brief. Mara schwieg.\n"
                _ = try book.writeScene(scene)
            }
            try await book.saveVersion()
            await model.open(book.url)
        } catch {
            finish(["error": error.localizedDescription], failures: ["setup"])
        }
        try? await Task.sleep(for: .seconds(1.5))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title.contains("Tipptest") }),
              let session = model.session
        else {
            finish(report, failures: ["no window"])
        }
        window.makeKeyAndOrderFront(nil)
        // Not in full screen (where the toolbar hides): e.g. left so by an earlier window test.
        report["startedInFullScreen"] = window.styleMask.contains(.fullScreen)
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
            for _ in 0..<40 where window.styleMask.contains(.fullScreen) { try? await Task.sleep(for: .milliseconds(250)) }
            try? await Task.sleep(for: .seconds(1))
        }

        // MARK: Details


        let editorRight = model.editor.webView.convert(model.editor.webView.bounds, to: nil).maxX
        func inspectorFields() -> [NSTextField] {
            allViews(in: window).compactMap { $0 as? NSTextField }
                .filter { $0.isEditable && !$0.isHiddenOrHasHiddenAncestor && frameInWindow($0).minX >= editorRight - 1 }
                .sorted { frameInWindow($0).maxY > frameInWindow($1).maxY }
        }
        let fields = inspectorFields()
        report["inspectorFields"] = fields.count
        let chapterTitle = session.manifest.chapter(containing: session.selectedSceneID ?? "")?.title ?? ""
        var targets: [(String, NSView)] = []
        if let title = fields.first { targets.append(("sceneTitle", title)) }
        if let fact = fields.first(where: { $0.placeholderString == "–" }) { targets.append(("sceneFact", fact)) }
        if let synopsis = allViews(in: window).compactMap({ $0 as? NSTextView })
            .first(where: { $0.isEditable && !$0.isFieldEditor && frameInWindow($0).minX >= editorRight - 1 })
        {
            targets.append(("synopsis", synopsis))
        }
        if let chapter = fields.first(where: { $0.stringValue == chapterTitle && !chapterTitle.isEmpty }) {
            targets.append(("chapterTitle", chapter))
            if let index = fields.firstIndex(of: chapter),
               let fact = fields[(index + 1)...].first(where: { $0.placeholderString == "–" })
            {
                targets.append(("chapterFact", fact))
            }
        }
        if let bookTitle = fields.first(where: { $0.stringValue == "Tipptest" }) { targets.append(("bookTitle", bookTitle)) }
        report["detailTargets"] = targets.map(\.0)

        // The inspector is wide enough for its German tab names; the toolbar has no second
        // way into the history; Apple's writing tools only work in their own panel.
        if let tabs = allViews(in: window).compactMap({ $0 as? NSSegmentedControl }).first(where: { frameInWindow($0).minX >= editorRight - 1 }) {
            report["inspectorTabs"] = (0..<tabs.segmentCount).compactMap { tabs.label(forSegment: $0) }
            report["tabsWidth"] = "\(Int(tabs.frame.width)) of \(Int(tabs.intrinsicContentSize.width)) needed"
            check(tabs.frame.width >= tabs.intrinsicContentSize.width - 1, "inspectorTabsFit")
        }
        let toolbar = window.toolbar?.items.map { $0.label.isEmpty ? $0.paletteLabel : $0.label } ?? []
        report["toolbar"] = toolbar
        check(!toolbar.contains("Verlauf"), "historyOnlyInInspector")
        if #available(macOS 15.0, *) {
            check(model.editor.webView.configuration.writingToolsBehavior == .limited, "writingToolsInOwnPanel")
        }
        check(targets.count >= 6, "foundDetailFields")

        var movement: [String: Any] = [:]
        for (name, view) in targets {
            let result = await typeAndWatch("Abc", into: view, in: window)
            movement[name] = result.moved.isEmpty ? "still" : result.moved
            check(result.moved.isEmpty, "\(name)Still")
            check(result.kept, "\(name)KeepsFocus")
        }
        report["detailMovement"] = movement

        // The inspector stays resizable by hand, and keeps the width it was given.
        if let split = allViews(in: window).compactMap({ $0 as? NSSplitView })
            .first(where: { $0.arrangedSubviews.count >= 2 && abs(($0.arrangedSubviews.last?.frame.width ?? 0) - InspectorView.idealWidth) < 80 }),
           let inspector = split.arrangedSubviews.last, let chapter = targets.first(where: { $0.0 == "chapterTitle" })?.1
        {
            let wider = inspector.frame.width + 60
            split.setPosition(split.bounds.width - wider - split.dividerThickness, ofDividerAt: split.arrangedSubviews.count - 2)
            try? await Task.sleep(for: .milliseconds(300))
            report["inspectorWidthByHand"] = inspector.frame.width
            check(abs(inspector.frame.width - wider) < 2, "inspectorResizable")
            let result = await typeAndWatch("d", into: chapter, in: window)
            check(result.moved.isEmpty && abs(inspector.frame.width - wider) < 2, "inspectorKeepsWidthWhileTyping")
        } else {
            failures.append("inspectorSplitView")
        }

        // MARK: Wiki facts

        if var entry = session.createWiki(title: "Mara Kessler", kind: .character) {
            entry.facts = [Fact("Geboren", "1921"), Fact("Augen", "grau")]
            session.saveWiki(entry)
            model.openWiki(entry.id)
            try? await Task.sleep(for: .seconds(1.5))
            if let wiki = NSApp.windows.first(where: { $0.isVisible && $0.title.hasPrefix("Wiki") }) {
                wiki.makeKeyAndOrderFront(nil)
                let key = allViews(in: wiki).compactMap { $0 as? NSTextField }.first { $0.isEditable && $0.stringValue == "Geboren" }
                if let key {
                    let result = await typeAndWatch("jahr", into: key, in: wiki)
                    check(result.kept, "wikiFactNameKeepsFocus")
                    report["wikiFactNameValue"] = result.value
                    check(result.value == "Geborenjahr", "wikiFactNameGetsAllCharacters")
                    check(result.moved.isEmpty, "wikiFactNameStill")
                } else {
                    failures.append("wikiFactNameField")
                }
                let added = await wikiNewEntryChecks(session: session, model: model, wiki: wiki)
                report.merge(added.report) { _, new in new }
                failures += added.failures
            } else {
                failures.append("wikiWindow")
            }
        }
        let covered = await coverChecks(session: session, window: window, folder: work)
        report.merge(covered.report) { _, new in new }
        failures += covered.failures
        let found = await findChecks(session: session, window: window)
        report.merge(found.report) { _, new in new }
        failures += found.failures
        let laidOut = await layoutChecks(session: session, window: window)
        report.merge(laidOut.report) { _, new in new }
        failures += laidOut.failures
        let quoted = await quoteChecks(session: session, window: window)
        report.merge(quoted.report) { _, new in new }
        failures += quoted.failures
        let formatted = await formatChecks(session: session, window: window)
        report.merge(formatted.report) { _, new in new }
        failures += formatted.failures
        let received = await receivedBookChecks(work: work)
        report.merge(received.report) { _, new in new }
        failures += received.failures
        let savedAs = await saveAsChecks(work: work)
        report.merge(savedAs.report) { _, new in new }
        failures += savedAs.failures
        finish(report, failures: failures)
    }

    // MARK: Books from before, and from others

    /// A book ending in .stet opens, offers its new name and keeps everything when renamed; a
    /// book that brings git settings and a server along runs nothing and is asked about.
    @MainActor
    private static func receivedBookChecks(work: URL) async -> (report: [String: Any], failures: [String]) {
        var report: [String: Any] = [:]
        var failures: [String] = []
        func check(_ ok: Bool, _ name: String) {
            report[name] = ok
            if !ok { failures.append(name) }
        }
        let model = AppModel.shared
        let old = work.appendingPathComponent("Alter Name.stet")
        let trap = work.appendingPathComponent("RAN")
        guard let made = try? await Book.create(at: old, title: "Alter Name", author: "Test") else { return (report, ["oldBook"]) }
        var scene = try? made.readScene(made.manifest.sceneIDs[0])
        scene?.body = "Ein Satz.\n"
        if let scene { _ = try? made.writeScene(scene) }
        _ = try? await made.saveVersion()
        // As if it came from someone else.
        let plain = Git(directory: old)
        _ = try? await plain.run(["config", "filter.x.clean", "touch '\(trap.path)'; cat"])
        _ = try? await plain.run(["config", "remote.origin.url", work.appendingPathComponent("fremd.git").path])
        try? Data("*.md filter=x\n".utf8).write(to: old.appendingPathComponent(".gitattributes"))

        await model.open(old)
        try? await Task.sleep(for: .seconds(1))
        check(model.session?.book.url.lastPathComponent == "Alter Name.stet" && model.session?.offersNewExtension == true, "oldExtensionOpensAndOffers")
        check(model.session?.removedSettings == ["filter.x.clean"], "foreignSettingsReported")
        if case .untrusted = model.session?.syncState { check(true, "foreignServerAsked") } else { check(false, "foreignServerAsked") }
        await model.session?.saveVersion()
        let versions = (try? await model.session?.book.git.log().count) ?? 0
        check(!FileManager.default.fileExists(atPath: trap.path), "foreignBookRunsNothing")
        await model.session?.disconnectServer()

        let renamed = await model.renameToCrea(old)
        try? await Task.sleep(for: .seconds(1))
        let session = model.session
        check(renamed && session?.book.url.lastPathComponent == "Alter Name.crea" && session?.offersNewExtension == false, "renamedToCrea")
        let after = (try? await session?.book.git.log().count) ?? 0
        check(versions >= 3 && after >= versions && !FileManager.default.fileExists(atPath: old.path), "renamedKeepsHistory")
        let text = try? await model.editor.text()
        check(text == "Ein Satz.\n", "renamedKeepsText")
        if let folder = pictureFolder, let window = NSApp.windows.first(where: { $0.isVisible && $0.title.contains("Alter Name") }) {
            await render(window, to: folder.appendingPathComponent("renamed.png"))
        }
        return (report, failures)
    }

    // MARK: Formatting

    /// The format buttons in the toolbar (lit in italic text and a quote, and working), the
    /// Format menu with its shortcuts (each once in the menu bar), ⌘I as a key, a shortcut in
    /// another field leaving the text alone, and the right-click menu's format items.
    @MainActor
    private static func formatChecks(session: BookSession, window: NSWindow) async -> (report: [String: Any], failures: [String]) {
        var report: [String: Any] = [:]
        var failures: [String] = []
        func check(_ ok: Bool, _ name: String) {
            report[name] = ok
            if !ok { failures.append(name) }
        }
        for other in NSApp.windows where other !== window && other.isVisible { other.close() }
        window.makeKeyAndOrderFront(nil)
        await session.select(session.manifest.sceneIDs[0])
        try? await Task.sleep(for: .milliseconds(300))
        let editor = AppModel.shared.editor
        let demo = "Der Regen hatte am Morgen aufgehört. Auf dem Tisch lag ein Zettel:\n\n> Bin beim Boot. *Vergiss den Schlüssel nicht.*\n\nMara steckte ihn ein."
        try? await editor.replaceText(demo)
        func text() async -> String { (try? await editor.text()) ?? "" }
        func select(_ part: String, length: Int? = nil) async {
            let range = (await text() as NSString).range(of: part)
            await editor.select(from: range.location, to: range.location + (length ?? range.length))
            try? await Task.sleep(for: .milliseconds(250))
        }

        // The toolbar's group: Kursiv, Fett, Zitat, Kommentar (SwiftUI buttons in a toolbar item group).
        func click(_ view: NSView) async {
            let frame = frameInWindow(view)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: frame.midX, y: frame.midY), modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                  context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        /// How each button looks: its average colour, as numbers to compare.
        func looks(_ views: [NSView]) -> [[Double]] {
            views.map { view in
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return [] }
                view.cacheDisplay(in: view.bounds, to: rep)
                var sum = [0.0, 0.0, 0.0]
                var count = 0.0
                for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                    for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                        sum[0] += c.redComponent; sum[1] += c.greenComponent; sum[2] += c.blueComponent
                        count += 1
                    }
                }
                return sum.map { count > 0 ? ($0 / count * 1000).rounded() / 1000 : 0 }
            }
        }
        func difference(_ a: [Double], _ b: [Double]) -> Double {
            guard a.count == 3, b.count == 3 else { return 0 }
            return zip(a, b).map { abs($0 - $1) }.reduce(0, +)
        }
        let groups = allViews(in: window).filter { String(describing: type(of: $0)) == "NSToolbarItemGroupView" && !$0.isHiddenOrHasHiddenAncestor }
        let buttons = groups.first.map { group in
            allViews(in: window).filter { String(describing: type(of: $0)) == "NSToolbarItemGroupLayoutWrapper" && $0.isDescendant(of: group) }
                .sorted { frameInWindow($0).minX < frameInWindow($1).minX }
        } ?? []
        let labels = window.toolbar?.items.compactMap { $0 as? NSToolbarItemGroup }.first { $0.subitems.count == 4 }?.subitems.map(\.label) ?? []
        report["formatButtons"] = ["groups": groups.count, "buttons": buttons.count, "labels": labels]
        check(groups.count == 1 && buttons.count == 4, "formatButtonsInToolbar")
        if buttons.count == 4 {
            await select("Regen", length: 0)
            let plain = looks(buttons)
            await select("Vergiss", length: 0)
            let italicQuote = looks(buttons)
            let changed = zip(plain, italicQuote).map { (difference($0, $1) * 1000).rounded() / 1000 }
            report["buttonsLit"] = ["state": ["italic": editor.formatState.italic, "bold": editor.formatState.bold, "quote": editor.formatState.quote],
                                    "change": changed]
            check(editor.formatState == FormatState(italic: true, bold: false, quote: true), "formatStateFollowsCursor")
            check(changed[0] > 0.03 && changed[2] > 0.03 && changed[1] < 0.01 && changed[3] < 0.01, "buttonsShowFormat")
            if let folder = pictureFolder { await render(window, to: folder.appendingPathComponent("format.png")) }
            // A click on Fett, with the mouse: on, and off again.
            await select("Morgen")
            await click(buttons[1])
            check(await text().contains("am **Morgen** aufgehört"), "boldButtonWorks")
            check(editor.formatState.bold, "boldButtonLit")
            await click(buttons[1])
            check(await text() == demo, "boldButtonUndoes")
        }

        // The Format menu: its items, and each shortcut once in the whole menu bar.
        let format = NSApp.mainMenu?.items.filter { $0.title == "Format" } ?? []
        report["formatMenu"] = format.first?.submenu?.items.map { $0.isSeparatorItem ? "—" : $0.title } ?? []
        check(format.count == 1 && (format.first?.submenu?.items.map { $0.isSeparatorItem ? "—" : $0.title } ?? [])
              == ["Kursiv", "Fett", "Zitat", "—", "Kommentar einfügen", "TODO einfügen"], "formatMenu")
        var shortcuts: [String: [String]] = [:]
        func collect(_ menu: NSMenu) {
            for item in menu.items {
                if !item.keyEquivalent.isEmpty {
                    let mods = item.keyEquivalentModifierMask.intersection([.command, .option, .shift, .control])
                    let key = (mods.contains(.control) ? "⌃" : "") + (mods.contains(.option) ? "⌥" : "") + (mods.contains(.shift) ? "⇧" : "")
                        + (mods.contains(.command) ? "⌘" : "") + item.keyEquivalent.uppercased()
                    shortcuts[key, default: []].append(item.title)
                }
                if let sub = item.submenu { collect(sub) }
            }
        }
        NSApp.mainMenu.map(collect)
        report["formatShortcuts"] = ["⌘I": shortcuts["⌘I"] ?? [], "⌘B": shortcuts["⌘B"] ?? [], "⌥⌘M": shortcuts["⌥⌘M"] ?? [], "⌥⌘T": shortcuts["⌥⌘T"] ?? []]
        check(shortcuts["⌘I"] == ["Kursiv"] && shortcuts["⌘B"] == ["Fett"] && shortcuts["⌥⌘M"] == ["Kommentar einfügen"], "formatShortcutsOnce")

        // ⌘I as a real key through the app: once on, once off.
        func commandKey(_ character: String, code: UInt16) async {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, characters: character,
                                                charactersIgnoringModifiers: character, isARepeat: false, keyCode: code) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        await select("Tisch")
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor.webView)
        try? await Task.sleep(for: .milliseconds(300))
        // A shortcut reaches only the active app's key window. macOS may keep a test started from
        // a terminal in the background (while someone works in another app): then this can't run.
        let canTakeKeys = NSApp.isActive && NSApp.keyWindow === window
        await commandKey("i", code: 34)
        let once = await text()
        await commandKey("i", code: 34)
        let twice = await text()
        report["commandI"] = ["once": once.contains("dem *Tisch* lag"), "twice": twice == demo, "active": NSApp.isActive,
                              "keyWindow": NSApp.keyWindow === window]
        if canTakeKeys {
            check(once.contains("dem *Tisch* lag") && twice == demo, "commandIOnceOnOnceOff")
        } else {
            report["commandIOnceOnOnceOff"] = "skipped: Zadur not the active app"
        }

        // Enter in a quote, with real keys: a new paragraph stays in it, one more Enter leaves it.
        let quoteEnd = NSMaxRange((await text() as NSString).range(of: "nicht.*"))
        await editor.select(from: quoteEnd, to: quoteEnd)
        window.makeFirstResponder(editor.webView)
        for character in "\r\rNoch etwas.\r\r\rWeiter." {
            let code: UInt16 = character == "\r" ? 36 : character == " " ? 49 : 0
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, characters: String(character),
                                                charactersIgnoringModifiers: String(character), isARepeat: false, keyCode: code) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        try? await Task.sleep(for: .milliseconds(300))
        let continued = await text()
        let expected = demo.replacingOccurrences(of: "nicht.*\n\nMara", with: "nicht.*\n>\n> Noch etwas.\n\nWeiter.\n\nMara")
        report["enterInQuote"] = continued == expected ? true : continued
        if continued != expected { failures.append("enterInQuote") }
        try? await editor.replaceText(demo)

        // ⌘B while typing in the inspector: the text stays as it is.
        if let field = allViews(in: window).compactMap({ $0 as? NSTextField })
            .first(where: { $0.isEditable && frameInWindow($0).minX >= frameInWindow(editor.webView).maxX - 1 })
        {
            window.makeFirstResponder(field)
            try? await Task.sleep(for: .milliseconds(200))
            await commandKey("b", code: 11)
            check(await text() == demo, "shortcutInOtherFieldLeavesText")
        }

        // The real right-click menu on the first word: Zadur's format items, and Fett works.
        let point = (try? await editor.call("""
            const r = document.querySelector('.cm-line').getBoundingClientRect(); return [r.left + 6, r.top + r.height / 2]
            """)) as? [Double]
        if let point, point.count == 2 {
            window.makeFirstResponder(editor.webView)
            let location = editor.webView.convert(NSPoint(x: point[0], y: point[1]), to: nil)
            for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
            var menu: NSMenu?
            for _ in 0..<40 where menu == nil {
                try? await Task.sleep(for: .milliseconds(100))
                menu = editor.webView.openMenu
            }
            let titles = menu?.items.map { $0.isSeparatorItem ? "—" : $0.title } ?? []
            report["contextMenu"] = titles
            let bold = menu?.items.first { $0.title == "Fett" }
            menu?.cancelTracking()
            try? await Task.sleep(for: .milliseconds(300))
            check(["Kursiv", "Fett", "Zitat", "Kommentar einfügen", "TODO einfügen"].allSatisfy(titles.contains), "contextMenuFormats")
            check(!titles.contains("Schrift") && titles.contains("Ausschneiden"), "webKitFontMenuGone")
            check(titles.first == "„Der“ ins Wiki aufnehmen", "rightClickMeansWordUnderMouse")
            if let bold, let action = bold.action {
                NSApp.sendAction(action, to: bold.target, from: bold)
                try? await Task.sleep(for: .milliseconds(400))
            }
            check(await text().hasPrefix("**Der** Regen"), "contextMenuBold")
        } else {
            check(false, "contextMenuPoint")
        }
        return (report, failures)
    }

    // MARK: Quotes

    /// The book's quotation marks: chevrons for a German book; typed quotes (with the keys of a
    /// German keyboard, ⇧2 and ⇧#) become typographic ones in each style; changing the style
    /// offers to convert the book's existing ones, and converting changes every scene.
    @MainActor
    private static func quoteChecks(session: BookSession, window: NSWindow) async -> (report: [String: Any], failures: [String]) {
        var report: [String: Any] = [:]
        var failures: [String] = []
        func check(_ ok: Bool, _ name: String) {
            report[name] = ok
            if !ok { failures.append(name) }
        }
        for other in NSApp.windows where other !== window && other.isVisible { other.close() }
        window.makeKeyAndOrderFront(nil)
        let scenes = session.manifest.sceneIDs
        await session.select(scenes[0])
        try? await Task.sleep(for: .milliseconds(300))
        let editor = AppModel.shared.editor
        check(session.manifest.quotes == nil && session.manifest.quoteStyle == .guillemets && editor.settings.quotes == .guillemets,
              "germanBookUsesChevrons")

        func type(_ text: String) async {
            for character in text {
                // ⇧2 and ⇧# on a German keyboard; letters and the rest as plain keys.
                let (code, shift): (UInt16, Bool) = switch character {
                case "\"": (19, true)
                case "'": (42, true)
                case " ": (49, false)
                default: (0, false)
                }
                // Through the app's event queue, like a real key: the menus see it first.
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: shift ? .shift : [],
                                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                       context: nil, characters: String(character), charactersIgnoringModifiers: String(character),
                                                       isARepeat: false, keyCode: code)
                    else { continue }
                    NSApp.postEvent(event, atStart: false)
                }
                try? await Task.sleep(for: .milliseconds(40))
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        // Ends in emphasis: a quote right after the opening star opens.
        let typed = "\"Ja\", sagte sie. 'Nein' Maras Hund's *\"so\"*"
        var results: [String: String] = [:]
        var offers: [String: String] = [:]
        for style in QuoteStyle.allCases {
            // As in the inspector: the book gets the style, and the text has marks of another one.
            session.setQuoteStyle(style)
            try? await Task.sleep(for: .milliseconds(600))
            if let offer = session.quoteConversion {
                offers[style.rawValue] = "\(offer.marks) in \(offer.scenes), sheet \(window.attachedSheet != nil)"
                if let sheet = window.attachedSheet, let folder = pictureFolder, offers.count == 1 {
                    await render(sheet, to: folder.appendingPathComponent("quotes.png"))
                }
                session.quoteConversion = nil  // "Nur beim Tippen"
                try? await Task.sleep(for: .milliseconds(500))
            }
            check(session.manifest.quoteStyle == style && editor.settings.quotes == style, "quoteStyle\(style.rawValue)Set")
            let length = ((try? await editor.text()) ?? "" as String).utf16.count
            await editor.select(from: length, to: length)
            window.makeFirstResponder(editor.webView)
            await type("\n" + typed)
            let text = (try? await editor.text()) ?? ""
            results[style.rawValue] = String(text.split(separator: "\n").last ?? "")
        }
        report["typedQuotes"] = results
        report["quoteOffers"] = offers
        check(results["guillemets"] == "»Ja«, sagte sie. ›Nein‹ Maras Hund’s *»so«*", "quotesChevrons")
        check(results["de"] == "„Ja“, sagte sie. ‚Nein‘ Maras Hund’s *„so“*", "quotesGerman")
        check(results["en"] == "“Ja”, sagte sie. ‘Nein’ Maras Hund’s *“so”*", "quotesEnglish")
        // No offer while the text has no other marks; then one for the line typed before.
        check(offers["guillemets"] == nil && offers["de"] == "6 in 1, sheet true" && offers["en"] == "12 in 1, sheet true", "styleChangeOffersConversion")
        check(window.attachedSheet == nil, "offerDeclined")
        check((try? Manifest.parse(String(contentsOf: session.book.url.appendingPathComponent(Manifest.fileName), encoding: .utf8)))?.quotes == .en,
              "quoteStyleInManifest")

        // Straight quotes in another scene, as after pasting or importing; then back to chevrons.
        if var other = try? session.book.readScene(scenes[1]) {
            other.body += "\"Ja\", sagte sie. 'Nein.' Geht's?\n"
            _ = try? session.book.writeScene(other)
            session.sceneFilesChanged()
        }
        session.setQuoteStyle(.guillemets)
        try? await Task.sleep(for: .milliseconds(600))
        let offer = session.quoteConversion
        report["quoteOffer"] = offer.map { "\($0.marks) in \($0.scenes)" } ?? "none"
        // 12 in the lines typed in the other styles, 5 in the other scene (the apostrophe in Geht's too).
        check(offer?.marks == 17 && offer?.scenes == 2 && offer?.afterChange == true, "conversionCountsEveryScene")
        await session.convertQuotes()
        try? await Task.sleep(for: .milliseconds(500))
        let shown = ((try? await editor.text()) ?? "").split(separator: "\n").suffix(3).map(String.init)
        let other = (try? session.book.readScene(scenes[1]).body) ?? ""
        report["quotesConverted"] = ["shown": shown, "other": other.split(separator: "\n").last.map(String.init) ?? ""]
        check(shown == Array(repeating: "»Ja«, sagte sie. ›Nein‹ Maras Hund’s *»so«*", count: 3), "conversionInShownScene")
        check(other.hasSuffix("»Ja«, sagte sie. ›Nein.‹ Geht’s?\n"), "conversionInOtherScene")
        check(session.toast?.message.hasPrefix("17 Anführungszeichen in 2 Szenen") == true, "conversionToast")
        await session.persist()
        check((try? session.book.readScene(scenes[0]).body)?.contains("„") == false, "conversionSaved")

        // From the menu, with nothing left to change: no question, a note instead.
        await session.offerQuoteConversion()
        check(session.quoteConversion == nil && session.toast?.message.contains("schon »…«") == true, "nothingLeftToConvert")
        return (report, failures)
    }

    /// The folder given after `--selftest-typing`, for pictures of the windows.
    static var pictureFolder: URL? {
        guard let flag = CommandLine.arguments.firstIndex(of: "--selftest-typing"), CommandLine.arguments.indices.contains(flag + 1) else { return nil }
        return URL(fileURLWithPath: CommandLine.arguments[flag + 1])
    }

    // MARK: New wiki entry

    /// The ＋ below the wiki's list: choose a kind, type the name, Return; the entry is there
    /// under that name (and its file named after it), selected. No second way in the toolbar.
    @MainActor
    private static func wikiNewEntryChecks(session: BookSession, model: AppModel, wiki: NSWindow) async -> (report: [String: Any], failures: [String]) {
        var report: [String: Any] = [:]
        var failures: [String] = []
        func check(_ ok: Bool, _ name: String) {
            report[name] = ok
            if !ok { failures.append(name) }
        }
        let toolbar = wiki.toolbar?.items.map { $0.label.isEmpty ? $0.paletteLabel : $0.label } ?? []
        report["wikiToolbar"] = toolbar
        check(!toolbar.contains("Neu"), "wikiNewOnlyBelowList")
        // The ＋: a pop-up button at the bottom of the list.
        let sidebarRight = allViews(in: wiki).compactMap { $0 as? NSTableView }.map { frameInWindow($0).maxX }.min() ?? wiki.frame.width / 2
        let plus = allViews(in: wiki).compactMap { $0 as? NSPopUpButton }.first { frameInWindow($0).maxX <= sidebarRight + 1 && frameInWindow($0).minY < 60 }
        report["wikiPlusAt"] = plus.map { "x \(Int(frameInWindow($0).minX)), y \(Int(frameInWindow($0).minY)) from the bottom left" } ?? "none"
        check(plus != nil, "wikiPlusBottomLeft")
        if let folder = pictureFolder { await render(wiki, to: folder.appendingPathComponent("wiki.png")) }

        /// Chooses a kind in the ＋ menu (what its items do; SwiftUI fills that menu only when it's
        /// clicked), types the name into the dialog with key events, then Return. Returns what
        /// the name field held when the dialog opened, nil without a dialog.
        func addCharacter(named name: String) async -> String? {
            model.newWikiKind = .character
            try? await Task.sleep(for: .milliseconds(700))
            guard let sheet = wiki.attachedSheet else { return nil }
            if ((sheet.firstResponder as? NSTextView)?.delegate as? NSTextField) == nil,
               let field = allViews(in: sheet).compactMap({ $0 as? NSTextField }).first(where: \.isEditable)
            {
                sheet.makeFirstResponder(field)
            }
            let initial = allViews(in: sheet).compactMap { $0 as? NSTextField }.first(where: \.isEditable)?.stringValue ?? ""
            for character in name + "\r" {
                let code: UInt16 = character == " " ? 49 : character == "\r" ? 36 : 0
                guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: sheet.windowNumber, context: nil, characters: String(character),
                                                   charactersIgnoringModifiers: String(character), isARepeat: false, keyCode: code)
                else { continue }
                // Like NSApplication: the key window's key equivalents (Return = default button) first.
                if !sheet.performKeyEquivalent(with: event) { sheet.sendEvent(event) }
                try? await Task.sleep(for: .milliseconds(40))
            }
            try? await Task.sleep(for: .milliseconds(800))
            return initial
        }

        check(await addCharacter(named: "Jonas Brand") != nil, "wikiNameDialog")
        let created = session.wiki.first { $0.title == "Jonas Brand" }
        report["wikiNewEntry"] = created.map { "\($0.id) (\($0.kind.label))" } ?? "none"
        check(created?.id == "Jonas-Brand" && created?.kind == .character, "wikiNewEntryNamed")
        check(created != nil && model.wikiSelection == created?.id, "wikiNewEntrySelected")
        check(wiki.attachedSheet == nil, "wikiNameDialogCloses")

        // A name that's already in the wiki opens that entry instead of making a second one.
        let count = session.wiki.count
        check(await addCharacter(named: "mara kessler") == "", "wikiNameDialogStartsEmpty")
        let mara = session.wiki.first { $0.title == "Mara Kessler" }
        check(session.wiki.count == count && mara != nil && model.wikiSelection == mara?.id, "wikiKnownNameOpensEntry")
        return (report, failures)
    }

    // MARK: Navigator and inspector layout

    /// Every chapter is a heading in the navigator, also a new one with a single scene; the
    /// inspector's tabs stay at the top whichever tab is shown.
    @MainActor
    private static func layoutChecks(session: BookSession, window: NSWindow) async -> (report: [String: Any], failures: [String]) {
        var report: [String: Any] = [:]
        var failures: [String] = []
        func check(_ ok: Bool, _ name: String) {
            report[name] = ok
            if !ok { failures.append(name) }
        }
        window.makeKeyAndOrderFront(nil)
        let editor = frameInWindow(session.editor.webView)

        func headings() -> Int {
            guard let table = allViews(in: window).compactMap({ $0 as? NSTableView }).first(where: { frameInWindow($0).maxX <= editor.minX + 1 }) else { return -1 }
            return (0..<table.numberOfRows).filter { table.rowView(atRow: $0, makeIfNecessary: true)?.isGroupRowStyle == true }.count
        }
        let chapters = session.manifest.chapters.count
        report["navigatorHeadings"] = "\(headings()) for \(chapters) chapters"
        check(headings() == chapters, "everyChapterIsAHeading")
        session.addChapter(after: session.manifest.chapters.last?.id)
        try? await Task.sleep(for: .milliseconds(800))
        report["navigatorHeadingsAfterNewChapter"] = "\(headings()) for \(session.manifest.chapters.count) chapters"
        check(session.manifest.chapters.count == chapters + 1 && headings() == chapters + 1, "newChapterIsAHeading")
        if let folder = pictureFolder { await render(window, to: folder.appendingPathComponent("navigator.png")) }

        guard let tabs = allViews(in: window).compactMap({ $0 as? NSSegmentedControl })
            .filter({ $0.segmentCount == 4 && frameInWindow($0).minX >= editor.maxX - 1 })
            .max(by: { frameInWindow($0).maxY < frameInWindow($1).maxY })
        else {
            failures.append("inspectorTabs")
            return (report, failures)
        }
        var tops: [String: Int] = [:]
        for index in 0..<tabs.segmentCount {
            tabs.selectedSegment = index
            tabs.sendAction(tabs.action, to: tabs.target)
            try? await Task.sleep(for: .milliseconds(600))
            tops[tabs.label(forSegment: index) ?? "\(index)"] = Int((window.contentView!.frame.height - frameInWindow(tabs).maxY).rounded())
            if tabs.label(forSegment: index) == "Feedback", let folder = pictureFolder {
                await render(window, to: folder.appendingPathComponent("feedback.png"))
            }
        }
        report["inspectorTabsFromTop"] = tops
        check(Set(tops.values).count == 1, "inspectorTabsStayAtTop")
        tabs.selectedSegment = 0
        tabs.sendAction(tabs.action, to: tabs.target)
        return (report, failures)
    }

    // MARK: Cover

    /// Setting a cover from the inspector's code path, seeing it there, removing it.
    @MainActor
    private static func coverChecks(session: BookSession, window: NSWindow, folder: URL) async -> (report: [String: Any], failures: [String]) {
        var report: [String: Any] = [:]
        var failures: [String] = []
        func check(_ ok: Bool, _ name: String) {
            report[name] = ok
            if !ok { failures.append(name) }
        }
        // A plain picture, made here (nothing from outside).
        let picture = folder.appendingPathComponent("titel.png")
        if let context = CGContext(data: nil, width: 400, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        {
            context.setFillColor(CGColor(red: 0.16, green: 0.3, blue: 0.5, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 600))
            context.setFillColor(CGColor(red: 0.95, green: 0.8, blue: 0.4, alpha: 1))
            context.fillEllipse(in: CGRect(x: 120, y: 330, width: 160, height: 160))
            if let image = context.makeImage() {
                let rep = NSBitmapImageRep(cgImage: image)
                try? rep.representation(using: .png, properties: [:])?.write(to: picture)
            }
        }
        let revision = session.coverRevision
        session.setCover(from: picture)
        try? await Task.sleep(for: .milliseconds(500))
        check(session.manifest.cover == "assets/cover.png" && session.book.coverURL != nil, "coverSet")
        check(session.coverRevision == revision + 1 && session.hasChangesSinceVersion, "coverMarksChange")
        if let flag = CommandLine.arguments.firstIndex(of: "--selftest-typing"), CommandLine.arguments.indices.contains(flag + 1) {
            // Scroll the inspector to the book's section and draw the window.
            for scroll in allViews(in: window).compactMap({ $0 as? NSScrollView }) where frameInWindow(scroll).minX > window.frame.width / 2 {
                if let document = scroll.documentView, document.frame.height > scroll.frame.height {
                    document.scroll(NSPoint(x: 0, y: document.isFlipped ? document.frame.height : 0))
                }
            }
            try? await Task.sleep(for: .milliseconds(400))
            await render(window, to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]).appendingPathComponent("cover.png"))
        }
        session.removeCover()
        try? await Task.sleep(for: .milliseconds(300))
        check(session.manifest.cover == nil && session.book.coverURL == nil, "coverRemoved")
        return (report, failures)
    }

    // MARK: Find and replace

    /// ⌘F, typing, Enter and ⌘G through the scenes, Esc; replacing one match and all of them.
    @MainActor
    private static func findChecks(session: BookSession, window: NSWindow) async -> (report: [String: Any], failures: [String]) {
        var report: [String: Any] = [:]
        var failures: [String] = []
        func check(_ ok: Bool, _ name: String) {
            report[name] = ok
            if !ok { failures.append(name) }
        }
        for other in NSApp.windows where other !== window && other.isVisible && other.title.hasPrefix("Wiki") { other.close() }
        window.makeKeyAndOrderFront(nil)
        let scenes = session.manifest.sceneIDs
        await session.select(scenes[0])
        try? await Task.sleep(for: .milliseconds(300))
        let find = session.find

        // The menu has exactly one ⌘F (no second one from the system's Find menu).
        var commandF: [String] = []
        func collect(_ menu: NSMenu) {
            for item in menu.items {
                if item.keyEquivalent == "f", item.keyEquivalentModifierMask == .command { commandF.append(item.title) }
                if let sub = item.submenu { collect(sub) }
            }
        }
        NSApp.mainMenu.map(collect)
        report["commandFItems"] = commandF
        check(commandF == ["Suchen …"], "oneFindCommand")

        func key(_ characters: String, code: UInt16 = 0) async {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: characters,
                                               charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
            else { return }
            window.sendEvent(event)
            try? await Task.sleep(for: .milliseconds(250))
        }
        func searchFieldFocused() -> Bool {
            ((window.firstResponder as? NSTextView)?.delegate as? NSTextField)?.placeholderString == "Im ganzen Buch suchen"
        }
        func highlighted() async -> Int {
            ((try? await session.editor.call("return document.querySelectorAll('.zadur-search-match').length")) as? NSNumber)?.intValue ?? -1
        }

        // Menu shortcuts (⌘F, ⌘G, ⇧⌘G) run what their menu items run: SwiftUI resolves them only
        // for real keyboard events, which a test can't send. Keys inside the bar are real events.
        await find.show()
        try? await Task.sleep(for: .milliseconds(300))
        check(find.isVisible, "findOpens")
        check(searchFieldFocused(), "findFieldHasFocus")
        for character in "mara" { await key(String(character)) }
        try? await Task.sleep(for: .milliseconds(300))
        report["findMatches"] = find.matches.count
        check(find.matches.count == 4, "findIgnoresCaseInWholeBook")
        check(find.current == 0, "findStartsInThisScene")
        let highlightedHere = await highlighted()
        check(highlightedHere == 2, "findHighlightsThisScene")
        check(searchFieldFocused(), "findFieldKeepsFocusWhileTyping")

        await key("\r", code: 36)
        check(find.current == 1, "enterGoesToNext")
        await key("\r", code: 36)
        try? await Task.sleep(for: .milliseconds(300))
        check(find.current == 2 && session.selectedSceneID == scenes.last, "enterJumpsToNextScene")
        check(searchFieldFocused(), "findFieldFocusedAfterJump")
        let highlightedThere = await highlighted()
        check(highlightedThere == 2, "highlightsInOtherScene")
        await find.next()
        await find.next()
        try? await Task.sleep(for: .milliseconds(300))
        check(find.current == 0 && session.selectedSceneID == scenes[0], "commandGWrapsAround")
        await find.previous()
        try? await Task.sleep(for: .milliseconds(300))
        check(find.current == 3 && session.selectedSceneID == scenes.last, "shiftCommandGGoesBack")

        // Replacing: exact matches only.
        find.showsReplace = true
        find.query = "Mara"
        find.replacement = "Lena"
        await find.searchNow()
        report["exactMatches"] = find.matches.count
        check(find.matches.count == 2, "replaceCountsCase")
        await session.select(scenes[0])
        await find.searchNow()
        if let flag = CommandLine.arguments.firstIndex(of: "--selftest-typing"), CommandLine.arguments.indices.contains(flag + 1) {
            await render(window, to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]).appendingPathComponent("find.png"))
        }
        await find.replaceCurrent()
        let first = (try? await session.editor.text()) ?? ""
        check(first.contains("Lena kam spät") && first.contains("MARA"), "replaceOne")
        let snapshotRef = Book.snapshotRef(device: DeviceID.current)
        let before = await session.book.git.resolve(snapshotRef)
        await find.replaceAll()
        let last = (try? session.book.readScene(scenes.last ?? "").body) ?? ""
        check(last.contains("Lena schwieg") && last.contains("las mara"), "replaceAllInOtherScenes")
        let after = await session.book.git.resolve(snapshotRef)
        check(after != nil && after != before, "replaceAllTakesSnapshot")
        check(find.matches.isEmpty, "nothingLeftAfterReplaceAll")

        if let field = allViews(in: window).compactMap({ $0 as? NSTextField }).first(where: { $0.placeholderString == "Im ganzen Buch suchen" }) {
            window.makeFirstResponder(field)
            try? await Task.sleep(for: .milliseconds(200))
        }
        await key("\u{1b}", code: 53)
        let highlightedAfter = await highlighted()
        check(!find.isVisible && highlightedAfter == 0, "escapeClosesFind")

        // Esc while writing closes it too.
        await find.show()
        try? await Task.sleep(for: .milliseconds(300))
        session.editor.focus()
        try? await Task.sleep(for: .milliseconds(300))
        await key("\u{1b}", code: 53)
        try? await Task.sleep(for: .milliseconds(300))
        check(!find.isVisible, "escapeInTextClosesFind")
        return (report, failures)
    }

    private static func allViews(in window: NSWindow) -> [NSView] {
        var result: [NSView] = []
        func collect(_ view: NSView) {
            result.append(view)
            view.subviews.forEach(collect)
        }
        (window.contentView?.superview ?? window.contentView).map(collect)
        return result
    }

    private static func frameInWindow(_ view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }

    /// Types `text` at the end of a field with key events, sampling the window's geometry after
    /// every key and for a while after the last one (autosave included). Returns what moved
    /// (more than half a point), whether the field kept the focus, and its text afterwards.
    @MainActor
    private static func typeAndWatch(_ text: String, into view: NSView, in window: NSWindow) async -> (moved: [String: Double], kept: Bool, value: String) {
        window.makeFirstResponder(view)
        try? await Task.sleep(for: .milliseconds(200))
        let textView = (view as? NSTextView) ?? ((view as? NSTextField)?.currentEditor() as? NSTextView)
        textView?.setSelectedRange(NSRange(location: (textView?.string as NSString?)?.length ?? 0, length: 0))

        // Everything that could visibly shake.
        func geometry() -> [String: NSRect] {
            var shapes: [String: NSRect] = ["window": window.frame, "contentLayoutRect": window.contentLayoutRect]
            for view in allViews(in: window) {
                // Keyed by identity: views that come and go don't shift the others' keys.
                let id = String(UInt(bitPattern: ObjectIdentifier(view).hashValue), radix: 36)
                switch view {
                case let scroll as NSScrollView:
                    shapes["scroll-\(id).frame"] = frameInWindow(scroll)
                    shapes["scroll-\(id).position"] = NSRect(origin: scroll.contentView.bounds.origin, size: .zero)
                case let field as NSTextField where field.isEditable:
                    shapes["field[\(field.placeholderString ?? "")]-\(id)"] = frameInWindow(field)
                case let web as NSView where String(describing: type(of: web)).contains("WebView"):
                    shapes["webView-\(id)"] = frameInWindow(web)
                // The window title grows with the book title being typed: that's meant to move.
                case let bar as NSView where ["Titlebar", "Toolbar"].contains(where: String(describing: type(of: bar)).contains)
                    && !String(describing: type(of: bar)).contains("TitleField"):
                    shapes["\(type(of: bar))-\(id)"] = frameInWindow(bar)
                default:
                    break
                }
            }
            return shapes
        }
        let start = geometry()
        var moved: [String: Double] = [:]
        func sample() {
            for (key, now) in geometry() {
                guard let before = start[key] else { continue }
                let delta = max(abs(now.minX - before.minX), abs(now.minY - before.minY), abs(now.width - before.width), abs(now.height - before.height))
                if delta > 0.5 { moved[key] = max(moved[key] ?? 0, (delta * 10).rounded() / 10) }
            }
        }
        for character in text {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, characters: String(character),
                                         charactersIgnoringModifiers: String(character), isARepeat: false, keyCode: 0)
            if let event { window.sendEvent(event) }
            for _ in 0..<15 {
                try? await Task.sleep(for: .milliseconds(10))
                sample()
            }
        }
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(25))
            sample()
        }
        let editor = window.firstResponder as? NSTextView
        let kept = view.window != nil && (editor === view || (editor?.delegate as? NSView) === view)
        let value = (view as? NSTextField)?.stringValue ?? (view as? NSTextView)?.string ?? ""
        return (moved, kept, value)
    }
}
