import AppKit
import CryptoKit
import StetCore

/// This Mac's signing and timestamp settings, for all books.
@MainActor
final class ProofSettings: ObservableObject {
    static let shared = ProofSettings()

    @Published var signing: SigningSetup? {
        didSet {
            Signing.current = signing
            save()
        }
    }
    @Published var timestampsOn: Bool { didSet { save() } }
    @Published var authorities: [TimestampAuthority] { didSet { save() } }

    /// The real services; the self-test swaps in a local authority.
    private(set) var client = TimestampClient()
    /// While set (self-test), nothing is written to the user's settings.
    private var saved: (SigningSetup?, Bool, [TimestampAuthority])?

    private static let signingKey = "StetSigning", timestampsKey = "StetTimestamps", authoritiesKey = "StetTimestampAuthorities"

    private init() {
        let defaults = UserDefaults.standard
        signing = defaults.data(forKey: Self.signingKey).flatMap { try? JSONDecoder().decode(SigningSetup.self, from: $0) }
        timestampsOn = defaults.bool(forKey: Self.timestampsKey)
        authorities = defaults.data(forKey: Self.authoritiesKey).flatMap { try? JSONDecoder().decode([TimestampAuthority].self, from: $0) }
            ?? TimestampAuthority.defaults
        Signing.current = signing
        Signing.onFailure = { reason in
            Task { @MainActor in AppModel.shared.session?.signingProblem = reason }
        }
    }

    private func save() {
        guard saved == nil else { return }
        let defaults = UserDefaults.standard
        defaults.set(signing.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.signingKey)
        defaults.set(timestampsOn, forKey: Self.timestampsKey)
        defaults.set(try? JSONEncoder().encode(authorities), forKey: Self.authoritiesKey)
    }

    /// For the self-test: other settings in memory only, until `endTemporary()`.
    func beginTemporary(signing: SigningSetup?, timestamps: Bool, authorities: [TimestampAuthority], client: TimestampClient) {
        if saved == nil { saved = (self.signing, timestampsOn, self.authorities) }
        self.signing = signing
        self.timestampsOn = timestamps
        self.authorities = authorities
        self.client = client
    }

    func endTemporary() {
        guard let saved else { return }
        signing = saved.0
        timestampsOn = saved.1
        authorities = saved.2
        client = TimestampClient()
        self.saved = nil
    }

    /// Stamps a random checksum at each service: shows whether they answer (nothing of a book is sent).
    func testAuthorities() async -> [String] {
        var lines: [String] = []
        let checksum = Data(SHA256.hash(data: Data(UUID().uuidString.utf8)))
        for authority in authorities {
            do {
                let stamp = try await client.stamp(checksum, at: authority)
                let trusted = (try? RFC3161.verify(stamp.response, anchors: client.anchors))?.trusted == true
                lines.append("\(authority.name): ✓ \(stamp.time.formatted(date: .omitted, time: .standard))" + (trusted ? "" : " (Zertifikat nicht vertrauenswürdig)"))
            } catch {
                lines.append("\(authority.name): ✗ \(error.localizedDescription)")
            }
        }
        return lines
    }
}

/// Signatures, timestamps and proofs for the open book.
extension BookSession {
    var proofs: ProofSettings { .shared }

    /// On opening: this Mac's key into the book (so other Macs recognise it), stamps still to fetch.
    func startProofs() async {
        registerSigner()
        await loadProofInfo()
        if proofs.timestampsOn { await processStamps() }
    }

    func signingChanged() async {
        signatures = [:]
        signingProblem = nil
        registerSigner()
        await loadProofInfo()
        await loadSignatures(for: history.filter { !$0.isSnapshot }.map(\.commit.hash))
    }

    private func registerSigner() {
        guard let setup = proofs.signing else { return }
        let host = ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? "Mac"
        let label = setup.kind == .stetKey ? nil : "\(setup.label) (\(host))"
        if (try? book.registerSigner(setup, label: label)) == true { hasChangesSinceVersion = true }
    }

    func loadProofInfo() async {
        stamps = await book.stamps()
        pendingStampCount = book.pendingStamps.count
        var labels: [String: String] = [:]
        for signer in book.signers() { labels[signer.fingerprint] = signer.label }
        if let own = proofs.signing { labels[own.fingerprint] = "dieser Mac" }
        signerLabels = labels
        if let head = lastVersion?.hash { await loadSignatures(for: [head]) }
    }

    func loadSignatures(for commits: [String]) async {
        let missing = commits.filter { signatures[$0] == nil }
        guard !missing.isEmpty else { return }
        let found = await book.signatures(of: missing)
        signatures.merge(found) { _, new in new }
    }

    // MARK: Stamping

    /// After a version was saved: the day's first stamp.
    func versionSaved() async {
        guard proofs.timestampsOn else { return }
        if let head = lastVersion?.hash { await loadSignatures(for: [head]) }
        let queued = (try? await book.queueVersionStamp(daily: true)) ?? false
        if queued || !book.pendingStamps.isEmpty { await processStamps() }
    }

    func milestoneSet() async {
        guard proofs.timestampsOn else { return }
        try? await book.queueVersionStamp()
        await processStamps()
    }

    func exported(_ file: URL) async {
        guard proofs.timestampsOn else { return }
        try? await book.queueFileStamp(file)
        await processStamps()
    }

    /// "Zeitstempel jetzt holen": for the current version (or another one).
    func stampNow(_ commit: String? = nil) async {
        guard proofs.timestampsOn else {
            proofMessage = "Zeitstempel sind ausgeschaltet. Du kannst sie in den Einstellungen unter „Signatur & Zeitstempel“ einschalten."
            return
        }
        await persist()
        if commit == nil, hasChangesSinceVersion { await saveVersion() }
        do {
            try await book.queueVersionStamp(commit ?? "HEAD")
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        while isStamping { try? await Task.sleep(for: .milliseconds(100)) }
        await processStamps()
        if stampProblem == nil { showToast(Toast(message: "Zeitstempel geholt")) }
    }

    func processStamps() async {
        guard proofs.timestampsOn, !isStamping else { return }
        isStamping = true
        defer { isStamping = false }
        let run = await book.processStamps(authorities: proofs.authorities, client: proofs.client)
        stampProblem = run.problems.isEmpty ? nil : run.problems.joined(separator: "\n")
        pendingStampCount = run.pending
        if run.stamped > 0 {
            stamps = await book.stamps()
            scheduleSync()
        }
    }

    // MARK: What the inspector and history show

    func versionStamps(_ commit: String) -> [StampRecord] { (stamps[commit] ?? []).filter { $0.kind == .version } }
    func fileStamps(_ commit: String) -> [StampRecord] { (stamps[commit] ?? []).filter { $0.kind == .file } }

    var lastStamp: StampRecord? { stamps.values.flatMap { $0 }.max { $0.time < $1.time } }

    var proofSummary: String {
        var parts = [proofs.signing == nil ? "Nicht signiert" : "Signiert"]
        if !proofs.timestampsOn {
            parts.append("Zeitstempel aus")
        } else if isStamping {
            parts.append("Stempel wird geholt …")
        } else if pendingStampCount > 0 {
            parts.append("\(pendingStampCount) Stempel ausstehend")
        } else if let last = lastStamp {
            parts.append("Stempel " + Self.relative(last.time))
        } else {
            parts.append("noch kein Stempel")
        }
        return parts.joined(separator: " · ")
    }

    var proofDetail: String {
        var lines: [String] = []
        if let signing = proofs.signing { lines.append("Signiert mit: \(signing.label)\n\(signing.fingerprint)") }
        if let last = lastStamp { lines.append("Letzter Zeitstempel: \(last.authority), \(last.time.formatted(date: .long, time: .standard))") }
        if pendingStampCount > 0 { lines.append("Ausstehend, weil: \(stampProblem ?? "noch nicht versucht")") }
        return lines.joined(separator: "\n")
    }

    static func relative(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? "heute \(date.formatted(date: .omitted, time: .shortened))"
            : date.formatted(date: .abbreviated, time: .shortened)
    }

    func signatureText(_ info: SignatureInfo) -> String {
        let who = signerLabels[info.key] ?? (info.signer.isEmpty || info.signer == "*" ? info.key : info.signer)
        switch info.state {
        case .good: return "Signiert – \(who)"
        case .unknownKey: return "Signiert mit einem Schlüssel, den dieses Buch nicht kennt (\(info.key))"
        case .expired: return "Signiert – \(who); der Schlüssel ist inzwischen abgelaufen"
        case .bad: return "Die Signatur passt nicht: Diese Version wurde nach dem Signieren verändert."
        case .cannotCheck: return "Signiert, aber auf diesem Mac nicht prüfbar (das passende Programm fehlt)"
        case .unsigned: return "Nicht signiert"
        }
    }

    func stampText(_ records: [StampRecord]) -> String {
        records.map { "\($0.authority): \($0.time.formatted(date: .numeric, time: .standard))" + ($0.fileName.map { " – \($0)" } ?? "") }
            .joined(separator: "\n")
    }

    // MARK: Proofs

    /// Asks where to put the proof of a version, writes it and shows it in the Finder.
    func saveProof(for commit: String) {
        let date = Date().formatted(.iso8601.year().month().day())
        choose(name: "Nachweis – \(manifest.title) – \(date)") { url in
            Task { _ = await self.writeProof(for: commit, to: url) }
        }
    }

    func saveProof(forFile file: URL) {
        choose(name: "Nachweis – \(file.deletingPathExtension().lastPathComponent)") { url in
            Task { _ = await self.writeProof(forFile: file, to: url) }
        }
    }

    private func choose(name: String, then: @escaping (URL) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.prompt = "Sichern"
        panel.message = "Stet legt einen Ordner mit dem Nachweis und einer Anleitung zum Prüfen an."
        panel.canCreateDirectories = true
        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            then(url)
        }
    }

    @discardableResult
    func writeProof(for commit: String, to url: URL, reveal: Bool = true) async -> URL? {
        isBusy = true
        defer { isBusy = false }
        do {
            try? FileManager.default.removeItem(at: url)
            await loadSignatures(for: [commit])
            let folder = try await Proof.writeVersion(commit, of: book, stamps: stamps[commit] ?? [], signing: proofs.signing,
                                                      versionSignature: signatures[commit], to: url, anchors: proofs.client.anchors)
            if reveal { NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent("LIESMICH.txt")]) }
            return folder
        } catch {
            errorMessage = "Der Nachweis konnte nicht angelegt werden: \(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func writeProof(forFile file: URL, to url: URL, reveal: Bool = true) async -> URL? {
        isBusy = true
        defer { isBusy = false }
        do {
            try? FileManager.default.removeItem(at: url)
            let found = try await book.stamps(forFile: file)
            let folder = try await Proof.writeFile(file, of: book, stamps: found, signing: proofs.signing, to: url, anchors: proofs.client.anchors)
            if reveal { NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent("LIESMICH.txt")]) }
            return folder
        } catch {
            errorMessage = "Der Nachweis konnte nicht angelegt werden: \(error.localizedDescription)"
            return nil
        }
    }

    /// "Datei prüfen …": was this file (e.g. a PDF sent to a publisher) stamped from this book?
    func chooseFileToCheck() {
        let panel = NSOpenPanel()
        panel.message = "Welche Datei soll geprüft werden? Stet vergleicht ihre Prüfsumme mit den Zeitstempeln dieses Buchs."
        panel.prompt = "Prüfen"
        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await self.check(file: url) }
        }
    }

    func check(file: URL) async {
        do {
            let found = try await book.stamps(forFile: file)
            let name = file.lastPathComponent
            guard let first = found.first else {
                proofMessage = "Für „\(name)“ gibt es in diesem Buch keinen Zeitstempel. Schon ein einziges geändertes Zeichen ergibt eine andere Prüfsumme – oder die Datei stammt aus einem Export ohne Zeitstempel."
                return
            }
            let checked = found.filter { $0.verify(anchors: proofs.client.anchors)?.trusted == true }
            var text = "„\(name)“ ist genau die Datei, die am \(first.time.formatted(date: .long, time: .shortened)) gestempelt wurde"
            text += first.fileName.map { $0 == name ? "." : " (damals „\($0)“)." } ?? "."
            text += "\n\n" + stampText(found)
            if checked.count < found.count { text += "\n\n\(found.count - checked.count) der Stempel ließen sich auf diesem Mac nicht vollständig prüfen." }
            proofMessage = text
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
