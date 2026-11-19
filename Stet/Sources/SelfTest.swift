import AppKit
import Foundation
import StetCore

/// Automated checks against the real app, WebKit and git. Both print a JSON report and exit
/// (0 = all checks passed). Neither prints any manuscript text.
///
///   Stet --selftest                     editor bridge: byte-exact round trips, settings, large texts
///   Stet --selftest-book <folder>       imports <folder> into a temporary book and drives the whole
///                                       flow: scenes, edit, version, note, snapshot, history, restore,
///                                       structure, health. The temporary book is deleted afterwards;
///                                       <folder> is only read.
enum SelfTest {
    static func startIfRequested() {
        let args = CommandLine.arguments
        if args.contains("--selftest") {
            armWatchdog()
            Task { @MainActor in
                await AppModel.shared.editor.waitUntilReady()
                await runBridge(editor: AppModel.shared.editor)
            }
        } else if let flag = args.firstIndex(of: "--selftest-book"), args.indices.contains(flag + 1) {
            armWatchdog(seconds: 120)
            let source = URL(fileURLWithPath: args[flag + 1])
            Task { @MainActor in await runBookFlow(source: source) }
        }
    }

    private static func armWatchdog(seconds: Double = 30) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            print(#"{"ok": false, "failures": ["timeout"]}"#)
            exit(2)
        }
    }

    private static func finish(_ report: [String: Any], failures: [String]) -> Never {
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
        let work = fm.temporaryDirectory.appendingPathComponent("StetSelfTest-\(UUID().uuidString)")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        let destination = work.appendingPathComponent("Selbsttest.stet")
        defer { try? fm.removeItem(at: work) }

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
