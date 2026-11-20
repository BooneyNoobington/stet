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
                .overlay(alignment: .top) { ToastView(session: session) }
                StatusBar(session: session, editor: editor)
            }
        }
        .inspector(isPresented: $showInspector) {
            InspectorView(session: session, tab: $inspectorTab)
                .inspectorColumnWidth(min: 240, ideal: 280, max: 400)
        }
        .navigationTitle(session.manifest.title)
        .navigationSubtitle(session.currentScene?.displayTitle ?? "")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                VersionMenu(session: session)
            }
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

                Button { AppModel.shared.openWiki() } label: {
                    Label("Wiki", systemImage: "text.book.closed")
                }
                .help("Wiki: Figuren, Orte, Begriffe (⌥⌘W)")

                Button { session.sheet = .export } label: {
                    Label("Exportieren", systemImage: "square.and.arrow.up")
                }
                .help("Exportieren als PDF, ePUB, Word … (⌘E)")

                Button { showInspector.toggle() } label: {
                    Label("Inspektor", systemImage: "sidebar.right")
                }
                .help("Inspektor ein-/ausblenden")
            }
        }
        .onChange(of: editor.settings) {
            Task { await editor.applySettings() }
        }
        .sheet(item: $session.sheet) { sheet in
            switch sheet {
            case .startExperiment: StartExperimentSheet(session: session)
            case .adopt(let experiment): AdoptSheet(session: session, experiment: experiment)
            case .conflicts: ConflictSheet(session: session)
            case .milestone: MilestoneSheet(session: session)
            case .server: ServerSheet(session: session)
            case .export: ExportSheet(session: session)
            case .backup: BackupSheet(session: session)
            }
        }
        .overlay {
            if session.isBusy && session.sheet == nil {
                ProgressView()
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .onChange(of: editor.settings.checkSpelling) { Task { await session.checkSpellingNow() } }
        .alert("Nachweis", isPresented: Binding(get: { session.proofMessage != nil }, set: { if !$0 { session.proofMessage = nil } })) {
            Button("OK") { session.proofMessage = nil }
        } message: {
            Text(session.proofMessage ?? "")
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
            if let server = session.syncStatusText {
                Divider().frame(height: 10)
                Button {
                    if case .offline = session.syncState { session.sheet = .server } else { Task { await session.syncNow() } }
                } label: {
                    Label(server, systemImage: serverSymbol)
                }
                .buttonStyle(.plain)
                .help((session.syncStatusDetail ?? "") + "\nKlicken zum Abgleichen")
            }
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private var serverSymbol: String {
        switch session.syncState {
        case .offline: "icloud.slash"
        case .needsMerge, .serverHasNew: "arrow.down.circle"
        case .syncing: "arrow.triangle.2.circlepath"
        default: "checkmark.icloud"
        }
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
            if let adoption = session.adoption, session.sheet == nil {
                Banner(symbol: "arrow.triangle.merge", text: "Übernahme von „\(adoption.name)“ noch offen", tint: .purple) {
                    Button("Fortsetzen …") { session.sheet = .conflicts }
                    Button("Abbrechen") { Task { await session.cancelAdoption() } }
                }
            } else if session.isOnExperiment, let experiment = session.currentExperiment {
                Banner(symbol: "flask", text: "Experiment „\(experiment.name)“", detail: "– was du hier schreibst, ändert die Hauptfassung nicht.", tint: .purple) {
                    Button("Übernehmen …") { session.sheet = .adopt(experiment) }
                    Button("Zur Hauptfassung") { Task { await session.switchTo(session.mainBranch) } }
                }
            }
            if session.adoption == nil {
                switch session.syncState {
                case .needsMerge:
                    Banner(symbol: "arrow.triangle.merge", text: "Auf dem Server gibt es Änderungen von einem anderen Mac.",
                           detail: "Beide Fassungen werden zusammengeführt; wo nötig, entscheidest du.", tint: .blue) {
                        Button("Zusammenführen …") { Task { await session.mergeWithServer() } }
                    }
                case .serverHasNew:
                    Banner(symbol: "arrow.down.circle", text: "Neue Versionen vom Server verfügbar.", tint: .blue) {
                        Button("Holen") { Task { await session.syncNow() } }
                    }
                default:
                    EmptyView()
                }
            }
            if let finding = session.syncFinding {
                Banner(
                    symbol: "exclamationmark.icloud",
                    text: "Dieses Buch liegt in einem \(finding.service)-Ordner.",
                    detail: "Stet speichert die Historie selbst – ein Sync-Dienst kann sie beschädigen, wenn zwei Geräte gleichzeitig schreiben."
                ) {
                    Button("Verschieben …") { AppModel.shared.moveCurrentBook() }
                        .help("In einen Ordner verschieben, den kein Sync-Dienst verwaltet")
                    Button("Hier lassen") { session.keepInSyncedFolder() }
                }
            }
            if let problem = session.signingProblem {
                Banner(symbol: "exclamationmark.triangle", text: "Ohne Signatur gesichert:", detail: problem) {
                    SettingsLink { Text("Signatur prüfen …") }
                    Button("OK") { session.signingProblem = nil }
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
    /// Shown after the text when there is room (and always in the tooltip).
    var detail: String? = nil
    var tint: Color = .orange
    @ViewBuilder let actions: Actions

    var body: some View {
        // The text is limited to two lines on purpose. Unlimited wrapping made SwiftUI measure it at
        // the narrowest possible width, word by word, which raised the window's minimum height above
        // the screen height: no full screen, and a zoomed window that cut off the navigator.
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            ViewThatFits(in: .horizontal) {
                if let detail {
                    Text(text + " " + detail).lineLimit(1)
                }
                Text(text).lineLimit(2).truncationMode(.middle)
            }
            .layoutPriority(1)
            .help([text, detail].compactMap { $0 }.joined(separator: " "))
            Spacer(minLength: 12)
            HStack(spacing: 8) { actions }
                .fixedSize()
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(tint.opacity(0.1))
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
