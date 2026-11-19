import AppKit
import SwiftUI

@main
struct StetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var editor: EditorController
    @StateObject private var session: SceneSession

    init() {
        let editor = EditorController()
        _editor = StateObject(wrappedValue: editor)
        _session = StateObject(wrappedValue: SceneSession(editor: editor))
    }

    var body: some Scene {
        Window("Stet", id: "main") {
            ContentView(session: session, editor: editor)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Öffnen …") { session.open() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Sichern") { Task { await session.save() } }
                    .keyboardShortcut("s")
                Button("Sichern unter …") { session.saveAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandMenu("Prototyp") {
                Button("Beispielszene laden") { Task { await session.loadSample() } }
                Divider()
                Button("Stresstest: 15.000 Wörter") { runStressTest(words: 15_000) }
                Button("Stresstest: 60.000 Wörter") { runStressTest(words: 60_000) }
            }
        }
    }

    private func runStressTest(words: Int) {
        Task {
            do {
                let result = try await editor.stressTest(words: words)
                let alert = NSAlert()
                alert.messageText = "Stresstest"
                alert.informativeText = result
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key): \($0.value)" }
                    .joined(separator: "\n")
                alert.runModal()
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`) rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        SelfTest.armWatchdog()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
