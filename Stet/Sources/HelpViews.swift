import AppKit
import StetCore
import SwiftUI

// MARK: - First start

extension AppModel {
    static let welcomeShownKey = "StetWelcomeShown"

    /// The sample book in the Documents folder: opened if it's there, created otherwise.
    func openSampleBook() async {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documents.appendingPathComponent("\(SampleBook.title).\(Book.fileExtension)")
        if !FileManager.default.fileExists(atPath: url.path) {
            busyMessage = "Beispielbuch wird angelegt …"
            defer { busyMessage = nil }
            do {
                _ = try await SampleBook.create(at: url)
            } catch {
                errorMessage = "Das Beispielbuch ließ sich nicht anlegen: \(error.localizedDescription)"
                return
            }
        }
        await open(url)
    }
}

/// A short tour on first start (and from the Help menu).
struct WelcomeTour: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    private struct Page {
        let symbol: String
        let title: String
        let text: String
    }

    private let pages = [
        Page(symbol: "checkmark.circle", title: "Schreiben, ohne etwas zu verlieren",
             text: "Stet speichert, während du schreibst. Mit ⌘S sicherst du außerdem eine **Version** des ganzen Buchs – ein Stand, zu dem du jederzeit zurückkannst. Rechts im **Verlauf** siehst du alle Versionen einer Szene, kannst sie vergleichen und Sätze von früher zurückholen. Nichts wird je überschrieben."),
        Page(symbol: "flask", title: "Ausprobieren mit Experimenten",
             text: "Ein anderes Ende, ein Kapitel aus anderer Sicht? Starte ein **Experiment** (⇧⌘E). Was du dort schreibst, ändert die Hauptfassung nicht. Gefällt es dir, **übernimmst** du es – ganz oder Szene für Szene. Sonst legst du es einfach ab. Mit **Meilensteinen** (⇧⌘M) markierst du wichtige Stände, z. B. „An den Verlag“."),
        Page(symbol: "text.book.closed", title: "Notizen, Wiki und Fakten",
             text: "**Kommentare** und **TODOs** stehen direkt im Text (⌥⌘M, ⌥⌘T) und sammeln sich im Inspektor. Im **Wiki** (⌥⌘W) legst du Figuren, Orte und Begriffe an; ihre Namen werden im Text dezent unterstrichen, beim Überfahren zeigt Stet ihre Fakten. Jede Szene hat **Fakten** wie Datum und Ort – die **Zeitleiste** ordnet die Szenen danach."),
        Page(symbol: "externaldrive.badge.checkmark", title: "Sicher aufbewahren und weitergeben",
             text: "Stet macht täglich **Backups** und gleicht das Buch auf Wunsch mit einem **Server** ab – Gitea, GitHub oder einfach ein Raspberry Pi – damit es auf mehreren Macs gleich ist. Für Verlag oder Testleser **exportierst** du es als PDF, Word oder E-Book. **Nachweise** mit Zeitstempel belegen, dass dein Text zu einem Zeitpunkt existierte."),
    ]

    var body: some View {
        VStack(spacing: 18) {
            let current = pages[page]
            Image(systemName: current.symbol)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Color.accentColor)
                .frame(height: 56)
            Text(current.title).font(.title2.weight(.semibold))
            Text((try? AttributedString(markdown: current.text)) ?? AttributedString(current.text))
                .font(.body)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
            HStack(spacing: 6) {
                ForEach(pages.indices, id: \.self) { index in
                    Circle().fill(index == page ? Color.accentColor : Color.secondary.opacity(0.35)).frame(width: 7, height: 7)
                }
            }
            .accessibilityHidden(true)
            Spacer(minLength: 0)
            HStack {
                if page > 0 {
                    Button("Zurück") { page -= 1 }
                } else {
                    Button("Überspringen") { close() }
                }
                Spacer()
                if page < pages.count - 1 {
                    Button("Weiter") { page += 1 }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Beispielbuch ansehen") {
                        close()
                        Task { await model.openSampleBook() }
                    }
                    .help("Legt im Dokumente-Ordner ein kleines Buch an, in dem alles schon einmal vorkommt.")
                    Button("Los geht’s") { close() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(28)
        .frame(width: 540, height: 400)
    }

    private func close() {
        UserDefaults.standard.set(true, forKey: AppModel.welcomeShownKey)
        dismiss()
    }
}

// MARK: - Help

struct HelpTopic: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let text: String
}

enum HelpContent {
    static let topics: [HelpTopic] = [
        HelpTopic(id: "start", title: "Erste Schritte", symbol: "book", text: """
        **Ein Buch anlegen:** Ablage ▸ Neues Buch (⇧⌘N). Ein Buch ist eine einzige Datei mit der Endung .stet – im Finder sieht es aus wie ein Dokument. Lege es am besten in einen Ordner, den kein Sync-Dienst (iCloud Drive, Nextcloud, Dropbox) verwaltet; für mehrere Macs gibt es den Server-Abgleich.

        **Ein bestehendes Projekt übernehmen:** Ablage ▸ Ordner importieren. Stet übernimmt Markdown-Szenen samt ihrer Git-Historie; der Originalordner bleibt unverändert.

        **Kapitel und Szenen:** Links in der Seitenleiste. Neue Szene: ⌘N, neues Kapitel: ⌥⌘N. Über das Kontextmenü verschiebst, benennst und löschst du; Szenen lassen sich auch ziehen. Teile sind optional.

        **Schreiben:** Stet schreibt Markdown, zeigt aber die Zeichen nur, wenn der Cursor sie berührt. **Fett** mit ⌘B, *kursiv* mit ⌘I. Anführungszeichen, Gedankenstriche und Auslassungspunkte setzt Stet passend zur Sprache des Buchs.

        **Suchen:** ⌘F sucht im ganzen Buch, Groß- und Kleinschreibung egal. Zeilenschalter oder ⌘G springt zum nächsten Treffer, auch in die nächste Szene; Esc schließt die Suche. Mit dem Häkchen **Ersetzen** zählt Groß- und Kleinschreibung: „Ersetzen“ nimmt sich den markierten Treffer vor (⌘Z macht es rückgängig), „Alle ersetzen“ das ganze Buch – vorher sichert Stet einen Schnappschuss.

        **Titelbild:** Rechts unter Details ▸ Buch ▸ Titelbild ein Bild wählen oder darauf ziehen, am besten im Hochformat. Es wird die erste Seite des PDF-Buchs, das Cover des E-Books und das Symbol des Buchs im Finder.

        **Zum Ausprobieren:** Hilfe ▸ Beispielbuch öffnen.
        """),
        HelpTopic(id: "versions", title: "Versionen und Verlauf", symbol: "clock.arrow.circlepath", text: """
        Stet speichert ständig auf die Festplatte. Eine **Version** sicherst du mit ⌘S: ein Stand des ganzen Buchs mit kurzer Beschreibung, was sich geändert hat. Zusätzlich legt Stet alle zehn Minuten unsichtbare **Schnappschüsse** an.

        **Verlauf** (Inspektor ▸ Verlauf): alle Versionen der geöffneten Szene. Ein Klick zeigt die Unterschiede zum jetzigen Text; „Diese Fassung wiederherstellen“ holt den alten Text zurück – rückgängig machbar mit ⌘Z.

        Nach ⌘S kannst du der Version eine **Notiz** geben („Nach Giselas Feedback“).

        **Grafischer Verlauf:** Fassung ▸ Verlauf zeigen – alle Versionen, Experimente und Meilensteine auf einer Zeitachse.
        """),
        HelpTopic(id: "experiments", title: "Experimente und Meilensteine", symbol: "flask", text: """
        Ein **Experiment** (⇧⌘E) ist eine zweite Fassung neben der Hauptfassung. Was du dort schreibst, berührt die Hauptfassung nicht. Über das Menü oben links wechselst du zwischen den Fassungen.

        **Übernehmen:** Fassung ▸ Experiment übernehmen. Haben beide Fassungen dieselbe Stelle geändert, zeigt Stet beide nebeneinander und du entscheidest – Absatz für Absatz.

        **Ablegen:** Ein Experiment, das du nicht brauchst, verschwindet aus der Liste, bleibt aber erhalten und lässt sich zurückholen.

        **Meilensteine** (⇧⌘M) markieren wichtige Stände, z. B. „Erste Fassung“ oder „An den Verlag“. Exporte markiert Stet automatisch.
        """),
        HelpTopic(id: "notes", title: "Kommentare, TODOs und Feedback", symbol: "text.bubble", text: """
        **Kommentar** an der markierten Stelle: ⌥⌘M. **TODO**: ⌥⌘T. Beide stehen im Text in geschweiften Klammern und erscheinen als Sprechblasen am Rand (zeigen/verbergen: ⇧⌘K).

        **Inspektor ▸ Notizen** sammelt alle Kommentare und TODOs des Buchs; ein Klick springt zur Stelle, erledigte TODOs hakst du dort ab.

        **Feedback** (Inspektor ▸ Feedback): Rückmeldungen von Testlesern mit Datum und Bezug auf einen Export. Word-Dateien mit Kommentaren liest Stet ein und setzt die Kommentare an die richtigen Stellen im heutigen Text.
        """),
        HelpTopic(id: "wiki", title: "Wiki, Fakten und Zeitleiste", symbol: "text.book.closed", text: """
        Das **Wiki** (⌥⌘W) kennt Figuren, Orte, Begriffe und Notizen. Ihre Namen – auch andere Namen, mit Genitiv-s oder Apostroph – werden im Text dezent unterstrichen; beim Überfahren erscheinen die Fakten, ⌘-Klick öffnet den Eintrag. Neuer Eintrag: im Wiki-Fenster ＋ unten links, oder im Text den Namen markieren und ⌃⌘W, oder Rechtsklick auf den Namen.

        **Nicht gemeint:** Heißt eine Figur Andrea und kommt auch ein Andreas vor, trägst du bei Andrea „Andreas“ unter „Nicht gemeint“ ein.

        **Fakten** (Inspektor ▸ Details): pro Szene, Kapitel und Teil, z. B. Datum, Uhrzeit, Ort, Perspektive. Welche Felder es gibt, legst du im Inspektor beim Buch fest.

        **Zeitleiste** (Buch ▸ Zeitleiste): die Szenen in der Reihenfolge der Geschichte, nach ihrem Datum. Rückblenden und Zeitsprünge werden sichtbar.

        **Für die Fortsetzung:** Im Wiki-Fenster das Wiki exportieren und im neuen Buch übernehmen.
        """),
        HelpTopic(id: "spelling", title: "Rechtschreibung", symbol: "textformat.abc", text: """
        Stet markiert unbekannte Wörter rot und gewellt (Darstellung ▸ Rechtschreibfehler markieren). Rechtsklick zeigt Vorschläge. Namen aus dem Wiki gelten als richtig.

        **Für dieses Buch erlauben:** Das Wort gilt in diesem Buch als richtig, auf allen Macs.

        **Das ganze Buch prüfen:** Buch ▸ Rechtschreibung prüfen (⇧⌘;). Alle unbekannten Wörter, die häufigsten zuerst, mit Vorschlägen und Fundstellen.

        In deutschen Büchern weist Stet blau gepunktet auf Apostrophe wie in „Gabriela's“ hin (richtig: „Gabrielas“).
        """),
        HelpTopic(id: "export", title: "Exportieren", symbol: "square.and.arrow.up", text: """
        Ablage ▸ Exportieren (⌘E): **PDF als Manuskript** (Normseiten-ähnlich zum Ausdrucken), **PDF als Buch**, **ePUB**, **Word**, **OpenDocument** und **Markdown**.

        Für die meisten Formate braucht Stet die Programme Pandoc und Typst. Fehlen sie, bietet der Export-Dialog an, sie einmalig zu laden – von den offiziellen Seiten der Projekte, geprüft.

        Jeder Export sichert vorher eine Version und markiert sie im Verlauf; im Dokument steht, aus welcher Version es stammt.
        """),
        HelpTopic(id: "backup", title: "Backups", symbol: "externaldrive", text: """
        Stet legt einmal am Tag ein **Backup** an (Ablage ▸ Backups einstellen): eine ZIP-Datei mit dem ganzen Buch und seiner ganzen Geschichte. Am besten auf einer externen Festplatte oder einem Netzlaufwerk.

        Von Hand: Ablage ▸ Backup sichern (⌥⌘B). Zurückholen: Ablage ▸ Backup wiederherstellen – Stet legt dabei eine Kopie an und überschreibt nichts.
        """),
        HelpTopic(id: "server", title: "Server und mehrere Macs", symbol: "server.rack", text: """
        Mit einem **Server** ist dein Buch auf mehreren Macs gleich: Stet schickt nach jedem ⌘S alles an den Server und holt beim Öffnen, was ein anderer Mac geschrieben hat. Überschrieben wird nie etwas; haben zwei Macs an derselben Stelle geschrieben, entscheidest du.

        **Welcher Server:** Gitea oder GitHub – oder einfach ein Raspberry Pi oder NAS mit git und SSH. Dort legt Stet das Repository auf Knopfdruck selbst an.

        **Anmeldung:** mit SSH-Schlüssel oder mit Benutzername und Passwort. Das Passwort liegt im Schlüsselbund dieses Macs.

        **Einrichten:** Buch ▸ Server. **Auf einem zweiten Mac:** Ablage ▸ Buch vom Server holen.
        """),
        HelpTopic(id: "proofs", title: "Signatur und Nachweise", symbol: "checkmark.seal", text: """
        In den Einstellungen (⌘,) unter „Signatur & Zeitstempel“: Stet kann jede Version **signieren** und **Zeitstempel** unabhängiger Dienste holen. Die Dienste sehen dabei nur eine Prüfsumme, nie deinen Text.

        **Nachweis:** Rechtsklick auf eine Version im Verlauf ▸ „Nachweis für diese Version“, oder nach einem Export „Nachweis speichern“. Der Ordner enthält eine Anleitung, mit der jeder den Nachweis ohne Stet prüfen kann.

        **Datei prüfen:** Buch ▸ Datei prüfen – war genau diese Datei (z. B. ein verschicktes PDF) gestempelt, und wann?
        """),
        HelpTopic(id: "stats", title: "Statistik", symbol: "chart.bar", text: """
        Buch ▸ Statistik (⌥⌘I): Wörter heute und diese Woche, Schreibzeit, wie viele Tage in Folge du geschrieben hast, die Wörter pro Tag und wie das Buch wächst. Dazu ein Tagesziel und ein Ziel für das ganze Buch.
        """),
        HelpTopic(id: "keys", title: "Tastenkürzel", symbol: "keyboard", text: """
        ⌘S  Version sichern
        ⌘F  Suchen · ⇧⌘F  Suchen und ersetzen · ⌘G / ⇧⌘G  Nächster / vorheriger Treffer
        ⌘N  Neue Szene · ⌥⌘N  Neues Kapitel · ⇧⌘N  Neues Buch
        ⌘O  Buch öffnen · ⌘E  Exportieren · ⌥⌘B  Backup sichern
        ⌘B  fett · ⌘I  kursiv
        ⌥⌘M  Kommentar · ⌥⌘T  TODO · ⇧⌘K  Kommentare zeigen
        ⇧⌘E  Neues Experiment · ⇧⌘M  Meilenstein setzen
        ⌥⌘W  Wiki öffnen · ⌃⌘W  Wiki-Eintrag aus Auswahl · ⌘-Klick auf einen Namen: Eintrag öffnen
        ⇧⌘;  Rechtschreibung prüfen · ⌥⌘I  Statistik
        ⌃⌘S  Mit dem Server abgleichen
        ⌥⌘F  Fokusmodus · ⌘+ / ⌘−  Schrift größer / kleiner
        ⌘,  Einstellungen
        """),
        HelpTopic(id: "trouble", title: "Wenn etwas nicht klappt", symbol: "lifepreserver", text: """
        **Etwas ist weg?** Im Verlauf der Szene findest du jede gesicherte Version und die letzten Schnappschüsse. Eine ganze Szene oder ein Experiment verschwindet in Stet nie endgültig.

        **Das Buch liegt in iCloud Drive oder Nextcloud?** Stet warnt dann. Verschiebe es in einen normalen Ordner und nutze für mehrere Macs den Server-Abgleich.

        **Problem melden:** Hilfe ▸ Problem melden. Stet stellt technische Angaben zusammen – nie Text aus deinem Buch –, du siehst alles vor dem Senden und kannst ergänzen, was passiert ist.
        """),
    ]
}

struct HelpWindow: View {
    @State private var selection: String? = HelpContent.topics.first?.id
    @State private var search = ""

    private var topics: [HelpTopic] {
        let term = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !term.isEmpty else { return HelpContent.topics }
        return HelpContent.topics.filter { $0.title.lowercased().contains(term) || $0.text.lowercased().contains(term) }
    }

    var body: some View {
        NavigationSplitView {
            List(topics, selection: $selection) { topic in
                Label(topic.title, systemImage: topic.symbol).tag(topic.id)
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Hilfe durchsuchen")
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            if let topic = HelpContent.topics.first(where: { $0.id == selection }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Label(topic.title, systemImage: topic.symbol).font(.title2.weight(.semibold))
                        ForEach(Array(topic.text.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                            Text((try? AttributedString(markdown: paragraph, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                                ?? AttributedString(paragraph))
                                .font(topic.id == "keys" ? .body.monospaced() : .body)
                                .lineSpacing(3)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 620, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView("Nichts gefunden", systemImage: "magnifyingglass")
            }
        }
        .frame(minWidth: 680, minHeight: 460)
        .onChange(of: search) {
            if !topics.contains(where: { $0.id == selection }) { selection = topics.first?.id }
        }
    }
}

// MARK: - Problem reports

/// The last errors and warnings Stet showed (for problem reports; kept in memory only).
enum DiagnosticsLog {
    private static var entries: [(Date, String)] = []
    private static let lock = NSLock()

    static func record(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.append((Date(), message))
        if entries.count > 30 { entries.removeFirst(entries.count - 30) }
    }

    static var recent: [(Date, String)] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

@MainActor
enum ProblemReport {
    /// Technical facts only: versions, tools, settings by kind, the open book by numbers, recent
    /// errors. Never text from a book; the home folder is shortened to "~".
    static func compose() async -> String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        var lines = ["Stet \(version) (\(build)), \(ExportTools.architecture), macOS \(os), Modell \(model())"]
        let git = (try? await Git(directory: FileManager.default.temporaryDirectory).run(["--version"]))?.string.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
        lines.append("git: \(git)")
        for tool in ["pandoc", "typst"] {
            let where_ = ExportTools.installed(tool) != nil ? "von Stet geladen" : (Exporter.tool(tool) != nil ? "installiert" : "fehlt")
            lines.append("\(tool): \(where_)")
        }
        let proofs = ProofSettings.shared
        lines.append("Signatur: \(proofs.signing.map { "\($0.kind.rawValue)" } ?? "aus"), Zeitstempel: \(proofs.timestampsOn ? "an" : "aus")")

        if let session = AppModel.shared.session {
            let book = session.book
            let versions = (try? await book.git.run(["rev-list", "--count", "--all"]))?.string.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
            let experiments = await book.experiments().count
            var server = "kein Server"
            if let url = session.serverURL {
                let endpoint = ServerEndpoint.parse(url)
                let login = endpoint.flatMap { ServerLogins.store.login(for: $0) } != nil ? "Passwort" : "Schlüssel"
                server = "\(endpoint?.kind.rawValue ?? "lokal"), \(login), Zustand: \(String(describing: session.syncState).split(separator: "(").first ?? "")"
            }
            lines.append("Offenes Buch: \(session.manifest.chapters.count) Kapitel, \(session.manifest.sceneIDs.count) Szenen, \(session.totalWords) Wörter, \(versions) Versionen, \(experiments) Experimente, Wiki \(session.wiki.count) Einträge, Server: \(server)")
            if let health = session.health, !health.isHealthy { lines.append("Gesundheitsprüfung: Auffälligkeiten") }
        } else {
            lines.append("Kein Buch geöffnet")
        }

        let recent = DiagnosticsLog.recent
        if !recent.isEmpty {
            lines.append("")
            lines.append("Letzte Meldungen:")
            for (date, message) in recent.suffix(15) {
                lines.append("\(date.formatted(date: .numeric, time: .standard))  \(message)")
            }
        }
        return lines.joined(separator: "\n").replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private static func model() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }

    /// Where reports go: `StetSupportEmail` in Info.plist (project.yml); empty until it's set.
    static var recipient: String {
        (Bundle.main.object(forInfoDictionaryKey: "StetSupportEmail") as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
    }
}

struct ProblemReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var description = ""
    @State private var details = "Wird zusammengestellt …"
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Problem melden").font(.title2)
            Text("Was ist passiert? Was hast du kurz vorher gemacht?")
                .foregroundStyle(.secondary)
            TextEditor(text: $description)
                .font(.body)
                .frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            Text("Dazu diese technischen Angaben – nie Text aus deinem Buch. Du kannst alles vor dem Senden lesen.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(details)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 170)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Button(copied ? "Kopiert" : "Kopieren") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                    copied = true
                }
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                Button("Per Mail senden …") {
                    if let url = mailURL { NSWorkspace.shared.open(url) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .help(ProblemReport.recipient.isEmpty ? "Öffnet eine Mail mit dem Bericht; die Adresse trägst du dort ein." : "An \(ProblemReport.recipient)")
            }
        }
        .padding(24)
        .frame(width: 560)
        .task { details = await ProblemReport.compose() }
    }

    private var report: String {
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text.isEmpty ? "" : text + "\n\n---\n") + details
    }

    private var mailURL: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = ProblemReport.recipient
        components.queryItems = [URLQueryItem(name: "subject", value: "Stet: Problem"), URLQueryItem(name: "body", value: report)]
        return components.url
    }
}
