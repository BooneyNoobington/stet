import AppKit
import Foundation

/// `Stet --selftest`: drives the real WebKit bridge, checks that text survives a
/// load → getText round trip byte for byte, runs the stress tests, prints a JSON
/// report to stdout and exits (0 = all checks passed).
enum SelfTest {
    static var isRequested: Bool { CommandLine.arguments.contains("--selftest") }

    /// Fails the run if the editor never reports `ready` (e.g. editor/dist missing).
    static func armWatchdog(seconds: Double = 30) {
        guard isRequested else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            print(#"{"ok": false, "failures": ["editor did not become ready"]}"#)
            exit(2)
        }
    }

    @MainActor
    static func run(editor: EditorController) async {
        var report: [String: Any] = [:]
        var failures: [String] = []

        // 1. Byte-exact round trips through the editor.
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
            do {
                try await editor.load(text)
                let back = try await editor.text()
                let identical = Array(back.utf8) == Array(text.utf8)
                roundTrip[name] = identical
                if !identical { failures.append("round trip changed text: \(name)") }
            } catch {
                roundTrip[name] = false
                failures.append("round trip \(name): \(error)")
            }
        }
        report["roundTrip"] = roundTrip

        // CodeMirror normalizes line breaks to \n. Recorded, not a failure: Stet's files are LF by definition.
        try? await editor.load("a\r\nb\r\n")
        report["crlfPreserved"] = ((try? await editor.text()) ?? "") == "a\r\nb\r\n"

        // 2. Stats arrive over the JS → Swift message channel.
        try? await editor.load(sample)
        var jsWords = -1
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(50))
            let stats = (try? await editor.call("return window.stet.stats()")) as? [String: Any]
            jsWords = (stats?["words"] as? NSNumber)?.intValue ?? -1
            if jsWords > 0 && editor.words == jsWords { break }
        }
        report["sampleWords"] = editor.words
        if editor.words == 0 || editor.words != jsWords {
            failures.append("stats message: swift=\(editor.words) js=\(jsWords)")
        }

        // 3. Settings reach the editor.
        editor.settings.font = .sans
        editor.settings.fontSize = 22
        await editor.applySettings()
        let applied = (try? await editor.call("return window.stet.getSettings()")) as? [String: Any]
        let settingsApplied =
            applied?["font"] as? String == "sans" && (applied?["fontSize"] as? NSNumber)?.doubleValue == 22
        report["settingsApplied"] = settingsApplied
        if !settingsApplied { failures.append("settings not applied") }
        editor.settings = EditorSettings()
        await editor.applySettings()

        // 4. Large documents in real WebKit.
        try? await editor.load(sample)
        for words in [15_000, 60_000] {
            do {
                report["stress\(words)"] = try await editor.stressTest(words: words)
            } catch {
                failures.append("stress test \(words): \(error)")
            }
        }

        if let agent = (try? await editor.call("return navigator.userAgent")) as? String {
            report["userAgent"] = agent
        }
        report["failures"] = failures
        report["ok"] = failures.isEmpty

        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8)
        {
            print(json)
        }
        exit(failures.isEmpty ? 0 : 1)
    }
}
