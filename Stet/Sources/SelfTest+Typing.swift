import AppKit
import StetCore
import SwiftUI

/// `Stet --selftest-typing`: types into the inspector's details and a wiki entry's facts with
/// real key events, the way a person does, and watches the window meanwhile. Nothing may move
/// (the window, the editor, the fields, the inspector's scroll position), and the field being
/// typed in must keep the keyboard focus and get every character. Uses a small test book of its
/// own, deleted afterwards.
extension SelfTest {
    @MainActor
    static func runTyping() async {
        var report: [String: Any] = [:]
        var failures: [String] = []
        func check(_ ok: Bool, _ name: String) {
            report[name] = ok
            if !ok { failures.append(name) }
        }
        let work = temporaryFolder("StetTypingTest")
        let model = AppModel.shared
        await model.editor.waitUntilReady()
        try? await Task.sleep(for: .seconds(0.5))
        do {
            let book = try await Book.create(at: work.appendingPathComponent("Tipptest.stet"), title: "Tipptest", author: "Test")
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
            .first(where: { $0.arrangedSubviews.count >= 2 && abs(($0.arrangedSubviews.last?.frame.width ?? 0) - 280) < 80 }),
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
        finish(report, failures: failures)
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
            ((try? await session.editor.call("return document.querySelectorAll('.stet-search-match').length")) as? NSNumber)?.intValue ?? -1
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
                case let bar as NSView where ["Titlebar", "Toolbar"].contains(where: String(describing: type(of: bar)).contains):
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
