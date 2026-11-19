import StetCore
import SwiftUI
import WebKit

struct BookView: View {
    @ObservedObject var session: BookSession
    @ObservedObject var editor: EditorController
    @State private var showInspector = true
    @State private var inspectorTab: InspectorView.Tab = .scene

    var body: some View {
        NavigationSplitView {
            NavigatorView(session: session)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 380)
        } detail: {
            VStack(spacing: 0) {
                Banners(session: session)
                ZStack {
                    EditorWebView(webView: editor.webView)
                    if let comparison = session.comparison {
                        ComparisonView(session: session, comparison: comparison)
                    }
                }
                StatusBar(session: session, editor: editor)
            }
            .overlay(alignment: .top) { ToastView(session: session) }
        }
        .inspector(isPresented: $showInspector) {
            InspectorView(session: session, tab: $inspectorTab)
                .inspectorColumnWidth(min: 240, ideal: 280, max: 400)
        }
        .navigationTitle(session.manifest.title)
        .navigationSubtitle(session.currentScene?.displayTitle ?? "")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await session.saveVersion() }
                } label: {
                    Label("Version sichern", systemImage: session.hasChangesSinceVersion ? "checkmark.circle.badge.plus" : "checkmark.circle")
                }
                .help("Version sichern (⌘S)")

                Toggle(isOn: $editor.settings.showComments) {
                    Label("Kommentare", systemImage: "text.bubble")
                }
                .help("Kommentare zeigen/verbergen (⇧⌘K)")

                Toggle(isOn: $editor.settings.focusMode) {
                    Label("Fokus", systemImage: "scope")
                }
                .help("Fokusmodus (⌥⌘F)")

                Button {
                    if showInspector && inspectorTab == .history {
                        showInspector = false
                    } else {
                        inspectorTab = .history
                        showInspector = true
                    }
                } label: {
                    Label("Verlauf", systemImage: "clock.arrow.circlepath")
                }
                .help("Verlauf dieser Szene")

                Button { showInspector.toggle() } label: {
                    Label("Inspektor", systemImage: "sidebar.right")
                }
                .help("Inspektor ein-/ausblenden")
            }
        }
        .onChange(of: editor.settings) {
            Task { await editor.applySettings() }
        }
        .alert("Fehler", isPresented: Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } })) {
            Button("OK") { session.errorMessage = nil }
        } message: {
            Text(session.errorMessage ?? "")
        }
    }
}

struct EditorWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

// MARK: - Status bar

struct StatusBar: View {
    @ObservedObject var session: BookSession
    @ObservedObject var editor: EditorController

    var body: some View {
        HStack(spacing: 14) {
            Text("Szene: \(editor.words.formatted()) Wörter")
            Text("Buch: \(session.totalWords.formatted()) Wörter")
            Spacer()
            Text(saveState)
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private var saveState: String {
        let disk = session.isWritingPending ? "Wird auf Disk geschrieben …" : "Auf Disk"
        guard let last = session.lastVersion else { return disk }
        let when = last.date.formatted(.relative(presentation: .named))
        return session.hasChangesSinceVersion
            ? "\(disk) · Änderungen seit der letzten Version (\(when))"
            : "\(disk) · Letzte Version \(when)"
    }
}

// MARK: - Banners

struct Banners: View {
    @ObservedObject var session: BookSession

    var body: some View {
        VStack(spacing: 0) {
            if let finding = session.syncFinding {
                Banner(
                    symbol: "exclamationmark.icloud",
                    text: "Dieses Buch liegt in einem \(finding.service)-Ordner. Stet speichert die Historie selbst – ein Sync-Dienst kann sie beschädigen, wenn zwei Geräte gleichzeitig schreiben."
                ) {
                    Button("In einen anderen Ordner verschieben …") { AppModel.shared.moveCurrentBook() }
                    Button("Hier lassen") { session.keepInSyncedFolder() }
                }
            }
            if let health = session.health {
                Banner(symbol: "stethoscope", text: healthText(health)) {
                    Button("Verstanden") { session.dismissHealthWarning() }
                }
            }
        }
    }

    private func healthText(_ report: HealthCheck.Report) -> String {
        var parts: [String] = []
        if !report.conflictCopies.isEmpty {
            parts.append("Konfliktkopien eines Sync-Dienstes gefunden: " + report.conflictCopies.prefix(3).joined(separator: ", "))
        }
        if let problem = report.integrityProblem {
            parts.append("Die Historie ist beschädigt: \(problem)")
        }
        return parts.joined(separator: " · ")
    }
}

struct Banner<Actions: View>: View {
    let symbol: String
    let text: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.orange)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            actions
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.1))
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: - Toast ("Version gesichert" + optional note)

struct ToastView: View {
    @ObservedObject var session: BookSession
    @State private var note = ""
    @State private var isAddingNote = false

    var body: some View {
        if let toast = session.toast {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(toast.message)
                if let commit = toast.commit {
                    if isAddingNote {
                        TextField("Notiz zu dieser Version", text: $note)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 260)
                            .onSubmit {
                                let text = note
                                isAddingNote = false
                                note = ""
                                Task { await session.addNote(text, to: commit) }
                            }
                    } else {
                        Button("Notiz hinzufügen …") {
                            isAddingNote = true
                            session.pinToast()
                        }
                        .buttonStyle(.link)
                    }
                }
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .padding(.top, 10)
            .transition(.move(edge: .top).combined(with: .opacity))
            .onExitCommand {
                isAddingNote = false
                session.toast = nil
            }
        }
    }
}
