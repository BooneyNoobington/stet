import AppKit
import StetCore
import SwiftUI

/// Connect the open book to a server (Gitea, GitHub, a bare repository …).
struct ServerSheet: View {
    @ObservedObject var session: BookSession
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var check: Result<RemoteCheck, Error>?
    @State private var isWorking = false
    @State private var connectError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Server").font(.title2)
            Text("Stet sendet nach jedem ⌘S alle Versionen, Experimente und Meilensteine an den Server und holt beim Öffnen, was ein anderer Mac geschrieben hat. Überschrieben wird dabei nie etwas.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Adresse", text: $url, prompt: Text(verbatim: "git@gitea.example.org:name/buch.git"))
                .textFieldStyle(.roundedBorder)
                .onChange(of: url) { check = nil; connectError = nil }
                .onSubmit { Task { await runCheck() } }
            if let suggestion = ServerAddress.suggestionForPortInShortForm(url) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("In der Kurzform „benutzer@host:pfad“ lässt sich kein Port angeben – „\(url.split(separator: ":").dropFirst().first ?? "")“ würde als Pfad gelesen.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    HStack {
                        Text(suggestion).font(.callout.monospaced()).textSelection(.enabled)
                        Button("So verwenden") { url = suggestion }.controlSize(.small)
                    }
                    Text("Kennt deine ~/.ssh/config den Port für diesen Host schon, geht auch die Kurzform ohne Port.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text("SSH oder HTTPS. Mit Port: ssh://git@host:PORT/name/buch.git. Bei SSH muss dein Schlüssel funktionieren und der Server diesem Mac schon einmal begegnet sein (einmal im Terminal verbinden).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !trimmed.lowercased().hasPrefix("http") {
                GroupBox("Anmeldung") {
                    KeySection(
                        key: session.stetKey,
                        create: { await session.createKey() },
                        remove: { await session.removeKey() }
                    )
                    .padding(6)
                }
            }

            if let check { checkView(check) }
            if let connectError {
                Label(connectError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }

            HStack {
                if session.isConnected {
                    Button("Trennen", role: .destructive) {
                        Task {
                            await session.disconnectServer()
                            dismiss()
                        }
                    }
                    .help("Stet sendet nichts mehr an diesen Server. Auf dem Server und hier bleibt alles erhalten.")
                }
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Button("Abbrechen", role: .cancel) { dismiss() }
                Button("Prüfen") { Task { await runCheck() } }
                    .disabled(trimmed.isEmpty || isWorking)
                Button("Verbinden") { Task { await connect() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConnect || isWorking)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear { url = session.serverURL ?? "" }
    }

    private var trimmed: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canConnect: Bool {
        guard case .success(let result)? = check else { return false }
        return result != .unrelated
    }

    @ViewBuilder
    private func checkView(_ check: Result<RemoteCheck, Error>) -> some View {
        switch check {
        case .success(.empty):
            Label("Leeres Repository. Beim Verbinden sendet Stet das ganze Buch mit seiner Historie.", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        case .success(.sameBook(let ahead, let behind, true)):
            Label("Auf dem Server liegt dieses Buch. Hier gibt es \(ahead) neue Version(en), dort \(behind).", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        case .success(.sameBook(let ahead, _, false)):
            VStack(alignment: .leading, spacing: 6) {
                Label("Auf dem Server liegt die Historie dieses Buchs aus der Zeit vor Stet.", systemImage: "info.circle")
                Text("Beim Verbinden setzt Stet sie fort (\(ahead) neue Version(en)). Der Server zeigt danach den Aufbau eines Stet-Buchs; book.yaml, Skripte und alte Dateien bleiben in der Historie erhalten. Wenn du das nicht möchtest, leg auf dem Server ein neues, leeres Repository an.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.blue)
        case .success(.unrelated):
            Label("Auf dem Server liegt ein anderes Projekt. Stet verbindet dieses Buch nicht damit.", systemImage: "xmark.octagon")
                .foregroundStyle(.red)
        case .failure(let error):
            Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    private func runCheck() async {
        guard !trimmed.isEmpty else { return }
        isWorking = true
        check = await session.checkServer(trimmed)
        isWorking = false
    }

    private func connect() async {
        isWorking = true
        connectError = await session.connectServer(trimmed)
        isWorking = false
        if connectError == nil { dismiss() }
    }
}

/// "Buch vom Server holen" – for a second Mac.
struct CloneSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var useOwnKey = false
    @State private var key: SSHKey?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Buch vom Server holen").font(.title2)
            Text("Holt ein Stet-Buch mit seiner ganzen Historie und allen Experimenten auf diesen Mac. Danach gleicht Stet es bei jedem Öffnen und Sichern mit dem Server ab.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Adresse", text: $url, prompt: Text(verbatim: "git@gitea.example.org:name/buch.git"))
                .textFieldStyle(.roundedBorder)
            if let suggestion = ServerAddress.suggestionForPortInShortForm(url) {
                HStack {
                    Label("Mit Port so schreiben:", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(suggestion).font(.callout.monospaced())
                    Button("So verwenden") { url = suggestion }.controlSize(.small)
                }
            }
            if !url.lowercased().hasPrefix("http") {
                Toggle("Eigenen Schlüssel für dieses Buch verwenden (ohne Touch ID oder Passwort)", isOn: $useOwnKey)
                if useOwnKey {
                    GroupBox("Anmeldung") {
                        KeySection(
                            key: key,
                            create: {
                                do {
                                    key = try SSHKey.create(label: bookName)
                                    return nil
                                } catch {
                                    return error.localizedDescription
                                }
                            },
                            remove: {
                                try? key?.delete()
                                key = nil
                            }
                        )
                        .padding(6)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                Button("Speicherort wählen …") {
                    let address = url.trimmingCharacters(in: .whitespacesAndNewlines)
                    let chosenKey = useOwnKey ? key : nil
                    dismiss()
                    model.showCloneDestinationPanel(for: address, key: chosenKey)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty || (useOwnKey && key == nil))
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private var bookName: String {
        let name = URL(fileURLWithPath: url.replacingOccurrences(of: ":", with: "/")).deletingPathExtension().lastPathComponent
        return name.isEmpty ? "Buch" : name
    }
}

/// Stet's own key for a book: explain, create (after stating the risks), show, remove.
struct KeySection: View {
    let key: SSHKey?
    let create: () async -> String?
    let remove: () async -> Void
    @State private var confirmCreate = false
    @State private var confirmRemove = false
    @State private var error: String?
    @State private var copied = false

    static let risks = """
    Ein Schlüssel ohne Passwort liegt unverschlüsselt auf diesem Mac. Jedes Programm, das unter deinem Benutzerkonto läuft, könnte ihn lesen und ohne Nachfrage benutzen. Er steckt auch in Time-Machine-Backups.

    So begrenzt Stet das Risiko: Der Schlüssel gilt nur für dieses Buch, liegt nicht im Buch (wird also nie mitsynchronisiert) und ist nur für dich lesbar. Trag ihn in Gitea als Deploy-Schlüssel dieses einen Repositorys ein, nicht in deinem Konto – dann reicht er im schlimmsten Fall nur für dieses Repository. Du kannst ihn jederzeit hier und in Gitea entfernen.
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let key {
                Label("Stet meldet sich für dieses Buch mit einem eigenen Schlüssel an – ohne Touch ID oder Passwort.", systemImage: "key.fill")
                Text(key.publicKey)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.background.secondary))
                HStack {
                    Button(copied ? "Kopiert" : "Öffentlichen Schlüssel kopieren") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(key.publicKey, forType: .string)
                        copied = true
                    }
                    Spacer()
                    Text(key.fingerprint).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
                .controlSize(.small)
                Text("In Gitea: Repository ▸ Einstellungen ▸ Deploy-Schlüssel ▸ Schlüssel hinzufügen. Den öffentlichen Schlüssel einfügen und „Schreibzugriff erlauben“ anhaken.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Schlüssel entfernen …", role: .destructive) { confirmRemove = true }
                    .controlSize(.small)
            } else {
                Text("Stet meldet sich mit deinen üblichen SSH-Schlüsseln an. Verlangt dein Schlüssel jedes Mal Touch ID oder ein Passwort, kann Stet für dieses Buch einen eigenen Schlüssel ohne Passwort anlegen.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Eigenen Schlüssel anlegen …") { confirmCreate = true }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
        .alert("Schlüssel ohne Passwort anlegen?", isPresented: $confirmCreate) {
            Button("Schlüssel anlegen") { Task { error = await create() } }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text(Self.risks)
        }
        .alert("Schlüssel entfernen?", isPresented: $confirmRemove) {
            Button("Entfernen", role: .destructive) { Task { await remove() } }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Stet löscht den Schlüssel von diesem Mac und meldet sich danach wieder mit deinen üblichen Schlüsseln an. Entferne ihn auch in Gitea bei den Deploy-Schlüsseln des Repositorys.")
        }
    }
}
