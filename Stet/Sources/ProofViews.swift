import AppKit
import StetCore
import SwiftUI

// MARK: - Settings window (⌘,)

struct StetSettingsView: View {
    var body: some View {
        TabView {
            ProofSettingsView(settings: .shared)
                .tabItem { Label("Signatur & Zeitstempel", systemImage: "checkmark.seal") }
            UpdateSettingsView()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .frame(width: 600)
    }
}

struct ProofSettingsView: View {
    @ObservedObject var settings: ProofSettings
    @State private var showSetup = false
    @State private var newName = ""
    @State private var newURL = ""
    @State private var testLines: [String] = []
    @State private var isTesting = false

    var body: some View {
        Form {
            Section {
                if let signing = settings.signing {
                    LabeledContent("Signiert mit") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(signing.label).multilineTextAlignment(.trailing)
                            Text(signing.fingerprint)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Ausschalten") {
                            settings.signing = nil
                            Task { await AppModel.shared.session?.signingChanged() }
                        }
                        Button("Ändern …") { showSetup = true }
                    }
                } else {
                    LabeledContent("Versionen werden noch nicht signiert.") {
                        Button("Signatur einrichten …") { showSetup = true }
                    }
                }
            } header: {
                Text("Signatur")
            } footer: {
                Text("Mit einer Signatur unterschreibt Stet jede gesicherte Version, jeden Meilenstein und jeden Export. So lässt sich zeigen, dass ein Stand von dir stammt und seitdem nicht verändert wurde. Schnappschüsse bleiben unsigniert. Deine eigene Git- und GPG-Einstellung ändert Stet nicht.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Zeitstempel holen", isOn: $settings.timestampsOn)
                Text("Täglich bei der ersten gesicherten Version, bei jedem Meilenstein und für jede exportierte Datei. Ohne Internet holt Stet sie später nach.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(settings.authorities) { authority in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(authority.name)
                            Text(authority.url).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            settings.authorities.removeAll { $0.id == authority.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(settings.authorities.count < 2)
                        .help("Dienst entfernen")
                    }
                }
                HStack {
                    TextField("Name", text: $newName, prompt: Text("Name des Dienstes"))
                        .frame(width: 150)
                    TextField("Adresse", text: $newURL, prompt: Text("https://…"))
                    Button("Hinzufügen") {
                        settings.authorities.append(TimestampAuthority(name: newName.trimmingCharacters(in: .whitespaces),
                                                                       url: newURL.trimmingCharacters(in: .whitespaces)))
                        newName = ""
                        newURL = ""
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || !newURL.hasPrefix("https://"))
                }
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                HStack {
                    if settings.authorities != TimestampAuthority.defaults {
                        Button("Voreinstellung") { settings.authorities = TimestampAuthority.defaults }
                    }
                    Spacer()
                    if isTesting { ProgressView().controlSize(.small) }
                    Button("Dienste testen") {
                        isTesting = true
                        Task {
                            testLines = await settings.testAuthorities()
                            isTesting = false
                        }
                    }
                    .disabled(isTesting)
                    .help("Holt bei jedem Dienst einen Stempel für eine zufällige Prüfsumme – nichts aus einem Buch.")
                }
                ForEach(testLines, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
            } header: {
                Text("Zeitstempel")
            } footer: {
                Text("Ein Zeitstempeldienst bestätigt mit seiner Unterschrift, dass es einen Stand zu einem Zeitpunkt gab. Stet schickt dafür nur eine Prüfsumme (SHA-256); aus ihr lässt sich der Text nicht zurückgewinnen. Die Dienste erfahren aber deine IP-Adresse und wann du stempelst. Eigene Dienste nur mit https://.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 520)
        .sheet(isPresented: $showSetup) { SigningSetupSheet(settings: settings) }
    }
}

// MARK: - Choosing a key

struct SigningSetupSheet: View {
    @ObservedObject var settings: ProofSettings
    /// Example data instead of this Mac's keys (window self-test).
    var preview: SigningDiscovery?
    @Environment(\.dismiss) private var dismiss
    @State private var discovery: SigningDiscovery?
    @State private var selection: String?
    @State private var email = ""
    @State private var isWorking = false
    @State private var problem: String?

    private var selected: SigningOption? { discovery?.options.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Signatur einrichten").font(.title2)
            Text("Womit soll Stet deine Versionen signieren? Was auf diesem Mac schon eingerichtet ist, findet Stet selbst.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let discovery {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        group("Einfach", discovery.options.filter { $0.kind == .stetKey })
                        let others = discovery.options.filter { $0.kind != .stetKey }
                        if !others.isEmpty { group("Schon auf diesem Mac", others) }
                        hints(discovery)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 250)

                if let selected {
                    Text(explanation(selected.kind))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if selected.kind == .smime || selected.kind == .openpgp {
                        TextField("E-Mail in den Versionen", text: $email, prompt: Text("wie bisher"))
                            .help("Gitea und andere Server zeigen eine Signatur nur dann als „bestätigt“, wenn diese Adresse zum Zertifikat bzw. Schlüssel passt.")
                    }
                }
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Suche Schlüssel und Zertifikate …").foregroundStyle(.secondary)
                }
                .frame(height: 250)
            }

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if isWorking {
                    ProgressView().controlSize(.small)
                    Text("Probe-Signatur …").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                Button("Ausprobieren und einrichten") { Task { await apply() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil || selected?.isUsable == false || isWorking)
            }
        }
        .padding(24)
        .frame(width: 580)
        .task {
            let found: SigningDiscovery
            if let preview { found = preview } else { found = await Signing.discover() }
            discovery = found
            let current = settings.signing.map { setup in found.options.first { $0.setup?.fingerprint == setup.fingerprint } } ?? nil
            selection = (current ?? found.options.first)?.id
        }
        .onChange(of: selection) {
            email = selected?.setup?.email ?? ""
            problem = nil
        }
    }

    private func group(_ title: String, _ options: [SigningOption]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6)
            ForEach(options) { option in
                Button {
                    selection = option.id
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: selection == option.id ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(selection == option.id ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(option.title + (option.kind == .stetKey ? " (empfohlen)" : ""))
                            Text(option.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!option.isUsable)
            }
        }
    }

    @ViewBuilder
    private func hints(_ discovery: SigningDiscovery) -> some View {
        if discovery.smimeCertificatesWithoutTool > 0 {
            VStack(alignment: .leading, spacing: 4) {
                Text("Im Schlüsselbund liegen \(discovery.smimeCertificatesWithoutTool) S/MIME-Zertifikate. Damit Stet mit ihnen signieren kann, braucht es das kleine Hilfsprogramm smimesign. Im Terminal:")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("brew install smimesign").font(.caption.monospaced()).textSelection(.enabled)
                    Button("Kopieren") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("brew install smimesign", forType: .string)
                    }
                    .controlSize(.small)
                }
                Text("Danach dieses Fenster neu öffnen.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        }
        if !discovery.hasGPG {
            Text("OpenPGP-Schlüssel bietet Stet an, sobald GnuPG installiert ist (z. B. GPG Suite).")
                .font(.caption).foregroundStyle(.tertiary).padding(.top, 8)
        }
    }

    private func explanation(_ kind: SigningOption.Kind) -> String {
        switch kind {
        case .stetKey:
            "Stet legt einen Schlüssel an, der nur auf diesem Mac liegt: keine Passwörter, keine Abfragen. Er ist dafür nicht durch ein Passwort geschützt – wer Zugriff auf deinen Benutzer-Account hat, könnte damit ebenfalls signieren. Den Nachweis, dass ein Text zu einem Zeitpunkt existierte, liefern ohnehin die Zeitstempel."
        case .smime:
            "Ein Zertifikat einer Zertifizierungsstelle bestätigt deinen Namen bzw. deine E-Mail-Adresse – das macht die Signatur auch für andere aussagekräftig. Beim ersten Signieren fragt macOS, ob smimesign den Schlüssel verwenden darf; „Immer erlauben“ erspart die Frage künftig."
        case .sshAgent:
            "Der Schlüssel bleibt im Agenten, bei Secretive in der Secure Enclave dieses Macs. Je nach Einstellung des Agenten fragt er bei jeder gesicherten Version nach Touch ID."
        case .openpgp:
            "Signiert über GnuPG mit deinem OpenPGP-Schlüssel. Hat er eine Passphrase, fragt GnuPG beim Signieren danach (je nach Einstellung mit Zwischenspeicher)."
        }
    }

    private func apply() async {
        guard let option = selected else { return }
        isWorking = true
        problem = nil
        defer { isWorking = false }
        do {
            var setup = try option.setup ?? Signing.makeStetKey()
            if option.kind == .smime || option.kind == .openpgp {
                let trimmed = email.trimmingCharacters(in: .whitespaces)
                setup.email = trimmed.isEmpty ? nil : trimmed
            }
            _ = try await Signing.probe(setup)
            settings.signing = setup
            await AppModel.shared.session?.signingChanged()
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}

// MARK: - In the inspector and the history

struct ProofRow: View {
    @ObservedObject var session: BookSession

    var body: some View {
        LabeledContent("Nachweise") {
            HStack {
                Text(session.proofSummary)
                    .lineLimit(1)
                    .foregroundStyle(session.pendingStampCount > 0 && !session.isStamping ? Color.orange : Color.primary)
                    .help(session.proofDetail)
                Menu {
                    Button("Zeitstempel jetzt holen") { Task { await session.stampNow() } }
                        .disabled(!session.proofs.timestampsOn)
                    if let head = session.lastVersion?.hash {
                        Button("Nachweis für die letzte Version …") { session.saveProof(for: head) }
                    }
                    Button("Datei prüfen …") { session.chooseFileToCheck() }
                    Divider()
                    SettingsLink { Text("Einstellungen …") }
                } label: {
                    Image(systemName: "checkmark.seal")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }
}

/// The small signs in a history row: signature and timestamp.
struct ProofBadges: View {
    @ObservedObject var session: BookSession
    let commit: String

    var body: some View {
        HStack(spacing: 4) {
            if let info = session.signatures[commit], info.isSigned {
                Image(systemName: symbol(info.state))
                    .foregroundStyle(color(info.state))
                    .help(session.signatureText(info))
            }
            let stamps = session.stamps[commit] ?? []
            if !stamps.isEmpty {
                Image(systemName: "clock.badge.checkmark")
                    .foregroundStyle(.secondary)
                    .help("Zeitstempel\n" + session.stampText(stamps))
            }
        }
        .font(.caption)
    }

    private func symbol(_ state: SignatureInfo.State) -> String {
        switch state {
        case .good, .unknownKey: "checkmark.seal"
        case .expired: "checkmark.seal.fill"
        case .bad: "xmark.seal.fill"
        case .cannotCheck, .unsigned: "questionmark.diamond"
        }
    }

    private func color(_ state: SignatureInfo.State) -> Color {
        switch state {
        case .good: .green
        case .unknownKey, .cannotCheck, .unsigned: .secondary
        case .expired: .orange
        case .bad: .red
        }
    }
}

// MARK: - Updates

struct UpdateSettingsView: View {
    @State private var automatic = AppModel.shared.updater?.updater.automaticallyChecksForUpdates ?? true

    var body: some View {
        Form {
            Section {
                Toggle("Automatisch nach Updates suchen", isOn: $automatic)
                    .onChange(of: automatic) { AppModel.shared.updater?.updater.automaticallyChecksForUpdates = automatic }
                    .disabled(AppModel.shared.updater == nil)
                HStack {
                    Text("Installiert: Stet \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Jetzt suchen …") { AppModel.shared.updater?.checkForUpdates(nil) }
                        .disabled(AppModel.shared.updater == nil)
                }
            } footer: {
                Text("Stet fragt einmal am Tag bei GitHub nach, ob es eine neue Version gibt, und zeigt sie an. Installiert wird nur, wenn du zustimmst. Jedes Update ist signiert; ein verändertes würde Stet ablehnen. Deine Bücher bleiben bei einem Update unberührt.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 220)
    }
}
