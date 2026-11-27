import AppKit
import ZadurCore

/// Part of `Zadur --selftest-typing`: "Sichern unter …". The window continues in the copy, which
/// has everything (unsaved text too); the original stays as it was; the server stays or goes as
/// chosen; another book or the book itself is never written over. The server is a folder of the
/// test.
extension SelfTest {
    @MainActor
    static func saveAsChecks(work: URL) async -> (report: [String: Any], failures: [String]) {
        var report: [String: Any] = [:]
        var failures: [String] = []
        func check(_ ok: Bool, _ name: String) {
            report[name] = ok
            if !ok { failures.append(name) }
        }
        let model = AppModel.shared
        func type(_ text: String) async {
            try? await model.editor.replaceText(text)
            try? await Task.sleep(for: .milliseconds(300))  // the editor reports the change
            await model.session?.persist()
        }
        func sceneText(_ url: URL) -> String? {
            guard let book = try? Book(url: url) else { return nil }
            return try? book.readScene(book.manifest.sceneIDs[0]).body
        }

        let original = work.appendingPathComponent("Original.crea")
        let server = work.appendingPathComponent("server.git")
        guard let book = try? await Book.create(at: original, title: "Sichertest", author: "Test"),
              (try? await Git(directory: work).run(["init", "--quiet", "--bare", "--initial-branch=main", server.path])) != nil,
              (try? await book.connect(to: server.path, device: DeviceID.current)) != nil
        else { return (report, ["saveAsSetup"]) }
        await model.open(original)
        try? await Task.sleep(for: .seconds(1))
        await type("Vor dem Sichern, noch keine Version.\n")
        let originalHead = await book.git.headCommit()

        // Taken, or inside the book: refused before anything closes.
        let other = try? await Book.create(at: work.appendingPathComponent("Anderes.crea"), title: "Anderes", author: "Test")
        let refusedTaken = await model.saveCurrentBook(as: work.appendingPathComponent("Anderes.crea"), keepServer: true)
        let refusedInside = await model.saveCurrentBook(as: original.appendingPathComponent("scenes/Kopie.crea"), keepServer: true)
        check(!refusedTaken && !refusedInside && model.session?.book.url == original, "saveAsRefusesTakenOrInside")
        model.errorMessage = nil
        check(other.map { sceneText($0.url) == "" } ?? false, "saveAsLeavesOtherBook")

        // A copy that stays connected, in a folder with umlauts.
        let copy = work.appendingPathComponent("Kopien für später/Märchenfassung.crea")
        try? FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        let saved = await model.saveCurrentBook(as: copy, keepServer: true)
        try? await Task.sleep(for: .seconds(1))
        let session = model.session
        let text = try? await model.editor.text()
        check(saved && session?.book.url == copy && text == "Vor dem Sichern, noch keine Version.\n", "saveAsContinuesInCopy")
        let copyHead = await session?.book.git.headCommit()
        check(copyHead == originalHead && session?.serverURL == server.path, "saveAsKeepsHistoryAndServer")
        check(session?.health == nil, "saveAsUmlautPathHealthy")
        check(sceneText(original) == "Vor dem Sichern, noch keine Version.\n", "saveAsOriginalHasUnsavedText")
        check(NSApp.windows.contains { $0.isVisible && $0.title.contains("Sichertest") }, "saveAsWindow")
        if let folder = pictureFolder, let window = NSApp.windows.first(where: { $0.isVisible && $0.title.contains("Sichertest") }) {
            await render(window, to: folder.appendingPathComponent("save-as.png"))
            // The panel's own part (the panel itself is drawn by macOS, out of Zadur's reach).
            let accessory = AppModel.saveAsAccessory().view
            let holder = NSWindow(contentRect: NSRect(origin: .zero, size: accessory.frame.size), styleMask: [.borderless], backing: .buffered, defer: false)
            holder.contentView = accessory
            await render(holder, to: folder.appendingPathComponent("save-as-panel-part.png"))
        }

        // Writing on in the copy leaves the original alone.
        await type("Nur in der Kopie.\n")
        await session?.saveVersion()
        let originalHeadAfter = await book.git.headCommit()
        check(originalHeadAfter == originalHead && sceneText(original) == "Vor dem Sichern, noch keine Version.\n", "saveAsOriginalUntouched")

        // An independent copy.
        let alone = work.appendingPathComponent("Unabhängig.crea")
        let savedAlone = await model.saveCurrentBook(as: alone, keepServer: false)
        try? await Task.sleep(for: .seconds(1))
        let aloneServer = await (try? Book(url: alone))?.remoteURL()
        check(savedAlone && model.session?.book.url == alone && model.session?.serverURL == nil && aloneServer == nil, "saveAsWithoutServer")
        let copyServer = await (try? Book(url: copy))?.remoteURL()
        check(copyServer == server.path, "saveAsOthersKeepServer")
        await model.closeBook()
        return (report, failures)
    }
}
