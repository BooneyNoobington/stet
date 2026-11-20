import AppKit
import StetCore
import SwiftUI
import UniformTypeIdentifiers

extension BookSession {
    /// Exports the open version; pending changes are saved as a version first. Returns the result,
    /// or nil after showing an error.
    func export(_ options: ExportOptions, to url: URL) async -> ExportResult? {
        await persist()
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await Exporter.export(book, options: options, to: url)
            hasChangesSinceVersion = false
            lastVersion = try? await book.git.log(limit: 1).first
            await refreshVersions()
            await loadHistory()
            scheduleSync()
            Task { await exported(result.file) }
            return result
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    var defaultExportQuotes: ExportQuotes {
        manifest.language.lowercased().hasPrefix("en") ? .en : .de
    }
}

struct ExportSheet: View {
    @ObservedObject var session: BookSession
    @Environment(\.dismiss) private var dismiss
    @AppStorage("ExportFormat") private var formatRaw = ExportFormat.pdfManuscript.rawValue
    @AppStorage("ExportQuotes") private var quotesRaw = ""
    @AppStorage("ExportWordComments") private var wordComments = false
    @AppStorage("ExportSceneTitles") private var sceneTitles = false
    @State private var result: ExportResult?
    @State private var fileStamps: [StampRecord] = []

    private var format: ExportFormat { ExportFormat(rawValue: formatRaw) ?? .pdfManuscript }
    private var quotes: ExportQuotes { ExportQuotes(rawValue: quotesRaw) ?? session.defaultExportQuotes }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let result {
                done(result)
            } else {
                form
            }
        }
        .padding(24)
        .frame(width: 540)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Exportieren").font(.title2)

            Picker("Format", selection: $formatRaw) {
                ForEach(ExportFormat.allCases) { format in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(format.label)
                        Text(format.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(format.rawValue)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Divider()

            Picker("Anführungszeichen", selection: Binding(get: { quotes.rawValue }, set: { quotesRaw = $0 })) {
                ForEach(ExportQuotes.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .help("Gerade Anführungszeichen (\") werden in diese Form gebracht; dazu Apostroph, Gedankenstrich und Auslassungspunkte.")
            Toggle("Szenentitel als Zwischenüberschriften", isOn: $sceneTitles)
            if format.supportsWordComments {
                Toggle("Kommentare und TODOs als Kommentare mitnehmen", isOn: $wordComments)
                    .help("Sonst werden Kommentare beim Export entfernt.")
            } else {
                Text("Kommentare und TODOs werden beim Export entfernt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            let missing = Exporter.missingTools(for: format)
            if !missing.isEmpty {
                Label("Dafür fehlt \(missing.joined(separator: " und ")). Im Terminal: brew install \(missing.joined(separator: " "))", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            Text("Exportiert wird die \(session.branchName == "Hauptfassung" ? "Hauptfassung" : "Fassung „\(session.branchName)“"). Ungesicherte Änderungen werden vorher als Version gesichert, und der Export bekommt eine Markierung im Verlauf – so weißt du später genau, welcher Text in dieser Datei steht.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                Button("Exportieren …") { chooseDestination() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!missing.isEmpty || session.isBusy)
            }
        }
    }

    private func done(_ result: ExportResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Exportiert", systemImage: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
            Text(result.file.lastPathComponent).font(.headline)
            Text(result.stamp.line + ". Im Verlauf markiert.")
                .foregroundStyle(.secondary)
            if session.proofs.timestampsOn {
                HStack {
                    Label(stampLine, systemImage: "clock.badge.checkmark")
                        .foregroundStyle(.secondary)
                        .help(fileStamps.isEmpty ? "" : session.stampText(fileStamps))
                    Spacer()
                    Button("Nachweis speichern …") { session.saveProof(forFile: result.file) }
                        .help("Ein Ordner mit der Datei, ihren Zeitstempeln und einer Anleitung, wie man sie ohne Stet prüft.")
                }
                .task(id: session.stamps.values.map(\.count).reduce(0, +)) {
                    fileStamps = (try? await session.book.stamps(forFile: result.file)) ?? []
                }
            }
            HStack {
                Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([result.file]) }
                Spacer()
                Button("Öffnen") {
                    NSWorkspace.shared.open(result.file)
                    dismiss()
                }
                Button("Fertig") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var stampLine: String {
        if !fileStamps.isEmpty { return "Zeitstempel: " + fileStamps.map(\.authority).joined(separator: ", ") }
        return session.isStamping ? "Zeitstempel wird geholt …" : "Zeitstempel folgt, sobald ein Dienst erreichbar ist."
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .data]
        let suffix = format == .pdfManuscript ? " (Manuskript)" : ""
        panel.nameFieldStringValue = session.manifest.title + suffix + "." + format.fileExtension
        panel.prompt = "Exportieren"
        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            var options = ExportOptions(format: format, quotes: quotes)
            options.commentsAsAnnotations = wordComments && format.supportsWordComments
            options.sceneTitles = sceneTitles
            Task { result = await session.export(options, to: url) }
        }
    }
}
