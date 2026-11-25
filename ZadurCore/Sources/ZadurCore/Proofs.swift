import Foundation

// MARK: - Receipt ("Beleg")

/// Every file of one version with its SHA-256, in the format of `shasum -a 256`, so anyone
/// can check the files without Zadur. The receipt's own SHA-256 is what gets timestamped:
/// the services see that checksum only, never text.
public struct Receipt: Equatable {
    public let commit: String
    public let text: String
    public let paths: [String]
    public var data: Data { Data(text.utf8) }
    public var digest: Data { data.sha256 }

    /// The first line (Crea spec §10.2). Stet 1.0 wrote `Stet-Beleg 1`; versions it stamped
    /// keep that header, so their receipts still give the stamped checksum.
    public static let header = "Crea-Receipt 1"
    public static let legacyHeader = "Stet-Beleg 1"
}

extension Book {
    /// The receipt of a version; the same version always gives the same receipt.
    public func receipt(for revision: String, header: String = Receipt.header) async throws -> Receipt {
        let commit = try await git.run(["rev-parse", "--verify", revision + "^{commit}"]).string
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let listing = try await git.run(["ls-tree", "-r", "-z", "--full-tree", commit]).string
        var entries: [(path: String, oid: String)] = []
        for record in listing.split(separator: "\0") {
            guard let tab = record.firstIndex(of: "\t") else { continue }
            let meta = record[..<tab].split(separator: " ")
            let path = String(record[record.index(after: tab)...])
            guard meta.count == 3, meta[1] == "blob", !path.contains("\n") else { continue }
            entries.append((path, String(meta[2])))
        }
        let blobs = try await git.blobs(Array(Set(entries.map(\.oid))))
        var lines = [header, "Version \(commit)", ""]
        for entry in entries { lines.append("\((blobs[entry.oid] ?? Data()).sha256.hex)  \(entry.path)") }
        return Receipt(commit: commit, text: lines.joined(separator: "\n") + "\n", paths: entries.map(\.path))
    }
}

// MARK: - Stamps, kept in git notes

/// One authority's stamp, attached to a version as a line in the `crea-stamps` notes (which
/// travel with the book to the server and into backups; Stet 1.0's `stet-stamps` are read too).
public struct StampRecord: Equatable, Identifiable {
    public enum Kind: String, Codable {
        /// The version's receipt.
        case version
        /// An exported file, by its own SHA-256.
        case file
    }

    public let kind: Kind
    public let commit: String
    public let authority: String
    public let time: Date
    public let digest: Data
    public let response: Data
    public let fileName: String?

    public var id: String { "\(commit)-\(kind.rawValue)-\(authority)-\(digest.hex)-\(time.timeIntervalSince1970)" }

    public init(kind: Kind, commit: String, authority: String, time: Date, digest: Data, response: Data, fileName: String? = nil) {
        self.kind = kind
        self.commit = commit
        self.authority = authority
        self.time = time
        self.digest = digest
        self.response = response
        self.fileName = fileName
    }

    private static let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    var line: String {
        var fields = ["crea-stamp", "1", kind.rawValue,
                      authority.addingPercentEncoding(withAllowedCharacters: Self.allowed) ?? "?",
                      ISO8601DateFormatter().string(from: time), digest.hex, response.base64EncodedString()]
        if let fileName { fields.append(fileName.addingPercentEncoding(withAllowedCharacters: Self.allowed) ?? "?") }
        return fields.joined(separator: " ")
    }

    init?(line: Substring, commit: String) {
        let f = line.split(separator: " ").map(String.init)
        guard f.count >= 7, f[0] == "crea-stamp" || f[0] == "stet-stamp", f[1] == "1", let kind = Kind(rawValue: f[2]),
              let time = ISO8601DateFormatter().date(from: f[4]), let digest = Data(hex: f[5]),
              let response = Data(base64Encoded: f[6])
        else { return nil }
        self.init(kind: kind, commit: commit, authority: f[3].removingPercentEncoding ?? f[3], time: time,
                  digest: digest, response: response, fileName: f.count > 7 ? f[7].removingPercentEncoding : nil)
    }

    /// Checks the authority's signature and that the stamp is for this record's checksum.
    public func verify(anchors: [SecCertificate]? = nil) -> TimestampVerification? {
        guard let verification = try? RFC3161.verify(response, anchors: anchors), verification.digest == digest else { return nil }
        return verification
    }
}

/// A stamp still to fetch (offline, or a service didn't answer). Kept per Mac in `.local/`.
public struct PendingStamp: Codable, Equatable {
    public var kind: StampRecord.Kind
    public var commit: String
    public var digest: String
    public var fileName: String?
    public var created: Date
    /// Authorities (by URL) that have answered.
    public var done: [String] = []
    public var failures: [String: Int] = [:]
}

struct StampState: Codable {
    var lastDaily: Date?
    var pending: [PendingStamp] = []
}

extension Book {
    public static let stampNotesRef = "refs/notes/crea-stamps"
    /// Where Stet 1.0 kept stamps: still read, and synced for Macs that haven't updated.
    public static let legacyStampNotesRef = "refs/notes/stet-stamps"
    /// After this many failed tries a service is skipped for that stamp.
    static let maxStampAttempts = 20

    /// All stamps of the book, by commit (from the Crea notes and Stet 1.0's).
    public func stamps() async -> [String: [StampRecord]] {
        var result: [String: [StampRecord]] = [:]
        for ref in [Self.stampNotesRef, Self.legacyStampNotesRef] {
            guard await git.resolve(ref) != nil, let list = try? await git.run(["notes", "--ref=\(ref)", "list"]) else { continue }
            let pairs = list.string.split(separator: "\n").compactMap { line -> (note: String, commit: String)? in
                let parts = line.split(separator: " ")
                return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
            }
            guard let blobs = try? await git.blobs(pairs.map(\.note)) else { continue }
            for pair in pairs {
                let text = String(decoding: blobs[pair.note] ?? Data(), as: UTF8.self)
                let records = text.split(separator: "\n").compactMap { StampRecord(line: $0, commit: pair.commit) }
                for record in records where !(result[pair.commit] ?? []).contains(record) { result[pair.commit, default: []].append(record) }
            }
        }
        return result.mapValues { $0.sorted { $0.time < $1.time } }
    }

    func addStamps(_ records: [StampRecord], to commit: String) async throws {
        let existing = try? await git.run(["notes", "--ref=\(Self.stampNotesRef)", "show", commit], allowedStatus: [0, 1])
        var lines = (existing?.status == 0 ? existing?.string : nil)?.split(separator: "\n").map(String.init) ?? []
        for record in records where !lines.contains(record.line) { lines.append(record.line) }
        let identity = await git.identityArguments(fallbackName: manifest.authors.first ?? "Zadur", sign: false)
        try await git.run(identity + ["notes", "--ref=\(Self.stampNotesRef)", "add", "--force", "--file=-", commit],
                          input: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    private var stampStateURL: URL { url.appendingPathComponent(Self.localFolder).appendingPathComponent("zadur-stamps.json") }
    /// Stet 1.0's name for it; read once and replaced by the next save.
    private var legacyStampStateURL: URL { url.appendingPathComponent(Self.localFolder).appendingPathComponent("stamps.json") }

    func loadStampState() -> StampState {
        for file in [stampStateURL, legacyStampStateURL] {
            if let data = try? Data(contentsOf: file), let state = try? JSONDecoder().decode(StampState.self, from: data) { return state }
        }
        return StampState()
    }

    func saveStampState(_ state: StampState) {
        try? FileManager.default.createDirectory(at: stampStateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: stampStateURL, options: .atomic) }
        try? FileManager.default.removeItem(at: legacyStampStateURL)
    }

    public var pendingStamps: [PendingStamp] { loadStampState().pending }

    /// Queues a stamp of a version's receipt. With `daily`, only if none was queued today.
    @discardableResult
    public func queueVersionStamp(_ revision: String = "HEAD", daily: Bool = false, now: Date = Date()) async throws -> Bool {
        var state = loadStampState()
        if daily, let last = state.lastDaily, Calendar.current.isDate(last, inSameDayAs: now) { return false }
        let receipt = try await receipt(for: revision)
        if !state.pending.contains(where: { $0.kind == .version && $0.commit == receipt.commit }) {
            state.pending.append(PendingStamp(kind: .version, commit: receipt.commit, digest: receipt.digest.hex, created: now))
        }
        if daily { state.lastDaily = now }
        saveStampState(state)
        return true
    }

    /// Queues a stamp of an exported file (its own SHA-256), attached to the exported version.
    public func queueFileStamp(_ file: URL, revision: String = "HEAD", now: Date = Date()) async throws {
        let digest = try Data(contentsOf: file).sha256
        let commit = try await git.run(["rev-parse", "--verify", revision + "^{commit}"]).string
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var state = loadStampState()
        if !state.pending.contains(where: { $0.digest == digest.hex }) {
            state.pending.append(PendingStamp(kind: .file, commit: commit, digest: digest.hex, fileName: file.lastPathComponent, created: now))
        }
        saveStampState(state)
    }

    public struct StampRun: Equatable {
        public var stamped = 0
        public var problems: [String] = []
        public var pending = 0
    }

    /// Asks each authority for every queued stamp; what fails stays queued for next time.
    public func processStamps(authorities: [TimestampAuthority], client: TimestampClient) async -> StampRun {
        var state = loadStampState()
        var run = StampRun()
        guard !authorities.isEmpty else {
            run.pending = state.pending.count
            return run
        }
        for index in state.pending.indices {
            var item = state.pending[index]
            guard let digest = Data(hex: item.digest) else { continue }
            var records: [(StampRecord, String)] = []
            for authority in authorities where !item.done.contains(authority.url) && (item.failures[authority.url] ?? 0) < Self.maxStampAttempts {
                do {
                    let stamp = try await client.stamp(digest, at: authority)
                    records.append((StampRecord(kind: item.kind, commit: item.commit, authority: authority.name, time: stamp.time,
                                                digest: digest, response: stamp.response, fileName: item.fileName), authority.url))
                } catch {
                    item.failures[authority.url, default: 0] += 1
                    let message = error.localizedDescription
                    if !run.problems.contains(message) { run.problems.append(message) }
                }
            }
            if !records.isEmpty {
                do {
                    try await addStamps(records.map(\.0), to: item.commit)
                    item.done += records.map(\.1)
                    run.stamped += records.count
                } catch {
                    run.problems.append(error.localizedDescription)
                }
            }
            state.pending[index] = item
        }
        state.pending.removeAll { item in
            authorities.allSatisfy { item.done.contains($0.url) || (item.failures[$0.url] ?? 0) >= Self.maxStampAttempts }
        }
        run.pending = state.pending.count
        saveStampState(state)
        return run
    }

    /// Stamps of a file (e.g. a PDF sent to a publisher), found by its content.
    public func stamps(forFile file: URL) async throws -> [StampRecord] {
        let digest = try Data(contentsOf: file).sha256
        return await stamps().values.flatMap { $0 }.filter { $0.digest == digest }.sorted { $0.time < $1.time }
    }
}

// MARK: - Proof package ("Nachweis")

/// A folder anyone can check without Zadur: the text, the receipt, the stamps, the signature,
/// and a read-me in plain German with the commands to check each of them.
public enum Proof {
    /// For a version: its files in `Buch/`, the receipt, its stamps.
    public static func writeVersion(
        _ commit: String,
        of book: Book,
        stamps: [StampRecord],
        signing: SigningSetup?,
        versionSignature: SignatureInfo?,
        to folder: URL,
        anchors: [SecCertificate]? = nil
    ) async throws -> URL {
        let fm = FileManager.default
        // Versions Stet 1.0 stamped have receipts with its header: use the one the stamps are for.
        let versionStamps = stamps.filter { $0.kind == .version }
        var receipt = try await book.receipt(for: commit)
        if !versionStamps.contains(where: { $0.digest == receipt.digest }) {
            let legacy = try await book.receipt(for: commit, header: Receipt.legacyHeader)
            if versionStamps.contains(where: { $0.digest == legacy.digest }) { receipt = legacy }
        }
        let stamps = versionStamps.filter { $0.digest == receipt.digest }
        try fm.createDirectory(at: folder.appendingPathComponent("Buch"), withIntermediateDirectories: true)
        let archive = try await book.git.run(["archive", "--format=tar", receipt.commit])
        let untar = try await Tools.runAsync(URL(fileURLWithPath: "/usr/bin/tar"), ["-x", "-f", "-", "-C", folder.appendingPathComponent("Buch").path], input: archive.data)
        guard untar.status == 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: untar.errors]) }
        try receipt.data.write(to: folder.appendingPathComponent("Beleg.txt"))

        let date = (try? await book.git.run(["show", "-s", "--format=%cI", receipt.commit]))
            .flatMap { ISO8601DateFormatter().date(from: $0.string.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let stampLines = try writeStamps(stamps, to: folder, anchors: anchors)
        let signature = await sign(folder.appendingPathComponent("Beleg.txt"), with: signing, into: folder)

        var text = heading("Nachweis für „\(book.manifest.title)“", "=")
        if !book.manifest.authors.isEmpty { text += "von \(book.manifest.authors.joined(separator: ", "))\n" }
        text += "Version vom \(date.map(long) ?? "?") · erstellt mit Zadur am \(long(Date()))\n\n"
        text += heading("Was dieser Nachweis belegt", "-")
        text += """
        Der Ordner „Buch“ enthält alle Dateien des Buchs in genau dieser Version: den Text aller
        Szenen (Ordner „scenes“), den Aufbau (manuscript.yaml) und alles Weitere. Die Datei
        „Beleg.txt“ listet jede dieser Dateien mit ihrer SHA-256-Prüfsumme auf, einem digitalen
        Fingerabdruck: Ändert sich auch nur ein Zeichen, ändert sich die Prüfsumme.


        """
        text += stampParagraph(stampLines, what: "diesen Beleg")
        if signature != nil, let signing {
            text += "Außerdem ist „Beleg.txt“ signiert (\(signing.label)). Die Signatur zeigt, dass der Nachweis\nvon der Person stammt, die diesen Schlüssel besitzt.\n\n"
        }
        text += heading("So prüfen Sie den Nachweis", "-")
        text += howTo
        text += """
        1. Die Dateien passen zum Beleg:
             cd Buch && shasum -a 256 -c ../Beleg.txt; cd ..
           Jede Datei muss mit „OK“ gemeldet werden. Die Warnung über „improperly formatted“
           Zeilen betrifft nur die drei Kopfzeilen des Belegs und ist normal.


        """
        text += checkSteps(stampLines, data: "Beleg.txt", first: 2)
        if let signature { text += "\(stampLines.isEmpty ? 2 : 3). " + signature.instructions + "\n\n" }
        text += heading("Technische Angaben", "-")
        text += "Version (git-Commit): \(receipt.commit)\nSHA-256 von Beleg.txt: \(receipt.digest.hex)\n"
        if let versionSignature, versionSignature.isSigned {
            text += "Im Verlauf des Buchs ist diese Version selbst signiert (\(describe(versionSignature)), Schlüssel \(versionSignature.key)).\n"
        }
        text += technicalStamps(stampLines)
        try Data(text.utf8).write(to: folder.appendingPathComponent("LIESMICH.txt"))
        return folder
    }

    /// For an exported file: the file itself and its stamps.
    public static func writeFile(
        _ file: URL,
        of book: Book,
        stamps: [StampRecord],
        signing: SigningSetup?,
        to folder: URL,
        anchors: [SecCertificate]? = nil
    ) async throws -> URL {
        let fm = FileManager.default
        let digest = try Data(contentsOf: file).sha256
        let stamps = stamps.filter { $0.digest == digest }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(file.lastPathComponent)
        if fm.fileExists(atPath: copy.path) { try fm.removeItem(at: copy) }
        try fm.copyItem(at: file, to: copy)
        let stampLines = try writeStamps(stamps, to: folder, anchors: anchors)
        let signature = await sign(copy, with: signing, into: folder)
        let name = file.lastPathComponent

        var text = heading("Nachweis für „\(name)“", "=")
        text += "aus dem Buch „\(book.manifest.title)“"
        if !book.manifest.authors.isEmpty { text += " von \(book.manifest.authors.joined(separator: ", "))" }
        text += " · erstellt mit Zadur am \(long(Date()))\n\n"
        text += heading("Was dieser Nachweis belegt", "-")
        text += "Die Datei „\(name)“ hat die SHA-256-Prüfsumme\n  \(digest.hex)\n– einen digitalen Fingerabdruck: Ändert sich auch nur ein Zeichen, ändert sich die Prüfsumme.\n\n"
        text += stampParagraph(stampLines, what: "genau diese Datei")
        if signature != nil, let signing {
            text += "Außerdem ist die Datei signiert (\(signing.label)). Die Signatur zeigt, dass sie von der\nPerson stammt, die diesen Schlüssel besitzt.\n\n"
        }
        text += heading("So prüfen Sie den Nachweis", "-")
        text += howTo
        text += "1. Die Prüfsumme der Datei:\n     shasum -a 256 \"\(name)\"\n   Es muss \(digest.hex) erscheinen.\n\n"
        text += checkSteps(stampLines, data: name, first: 2)
        if let signature { text += "\(stampLines.isEmpty ? 2 : 3). " + signature.instructions + "\n\n" }
        text += heading("Technische Angaben", "-")
        text += "SHA-256 der Datei: \(digest.hex)\n"
        if let commit = stamps.first?.commit { text += "Exportiert aus Version (git-Commit): \(commit)\n" }
        text += technicalStamps(stampLines)
        try Data(text.utf8).write(to: folder.appendingPathComponent("LIESMICH.txt"))
        return folder
    }

    // MARK: Pieces

    struct StampFile {
        let record: StampRecord
        let file: String
        let certificates: String
        let verification: TimestampVerification?
        let rootName: String?
        let rootFingerprint: String?
    }

    private static func writeStamps(_ stamps: [StampRecord], to folder: URL, anchors: [SecCertificate]?) throws -> [StampFile] {
        var used: Set<String> = []
        return try stamps.map { record in
            var name = record.authority
            var n = 2
            while used.contains(name) { name = "\(record.authority) \(n)"; n += 1 }
            used.insert(name)
            let file = "Zeitstempel – \(name).tsr", certificates = "Zertifikate – \(name).pem"
            try record.response.write(to: folder.appendingPathComponent(file))
            let verification = record.verify(anchors: anchors)
            var rootName: String?, rootFingerprint: String?
            if let verification {
                let certs = verification.embedded.isEmpty ? verification.chain : verification.embedded
                try Data(RFC3161.pem(certs).utf8).write(to: folder.appendingPathComponent(certificates))
            }
            if let chain = verification?.chain, !chain.isEmpty {
                if let root = chain.last, let certificate = SecCertificateCreateWithData(nil, root as CFData) {
                    rootName = SecCertificateCopySubjectSummary(certificate) as String?
                    rootFingerprint = root.sha256.map { String(format: "%02X", $0) }.joined(separator: ":")
                }
            }
            return StampFile(record: record, file: file, certificates: certificates, verification: verification,
                             rootName: rootName, rootFingerprint: rootFingerprint)
        }
    }

    private static func sign(_ file: URL, with setup: SigningSetup?, into folder: URL) async -> Signing.DetachedSignature? {
        guard let setup, let signature = try? await Signing.signDetached(file, with: setup) else { return nil }
        for item in signature.files { try? item.data.write(to: folder.appendingPathComponent(item.name)) }
        return signature
    }

    private static func stampParagraph(_ stamps: [StampFile], what: String) -> String {
        guard !stamps.isEmpty else {
            return "Für \(what) gibt es noch keinen Zeitstempel.\n\n"
        }
        var text = stamps.count == 1
            ? "Ein unabhängiger Zeitstempeldienst hat mit seiner digitalen Unterschrift bestätigt, dass es\n\(what) zu folgendem Zeitpunkt gab:\n\n"
            : "Unabhängige Zeitstempeldienste haben mit ihrer digitalen Unterschrift bestätigt, dass es\n\(what) zu folgenden Zeitpunkten gab:\n\n"
        for stamp in stamps {
            text += "  • \(stamp.record.authority): \(long(stamp.verification?.time ?? stamp.record.time))\n"
        }
        text += "\nDie Dienste haben dabei nur die Prüfsumme gesehen, nie den Text.\n\n"
        return text
    }

    private static let howTo = """
    Dafür genügt das Terminal auf einem Mac oder unter Linux. Alle Befehle werden in diesem
    Ordner ausgeführt (im Terminal „cd “ tippen, den Ordner ins Fenster ziehen, Return).


    """

    private static func checkSteps(_ stamps: [StampFile], data: String, first: Int) -> String {
        guard !stamps.isEmpty else { return "" }
        var text = "\(first). Die Zeitstempel gelten für „\(data)“ und sind echt:\n"
        for stamp in stamps {
            text += "     openssl ts -verify -data \"\(data)\" -in \"\(stamp.file)\" -CAfile /etc/ssl/cert.pem -untrusted \"\(stamp.certificates)\"\n"
        }
        text += """
           Es muss jeweils „Verification: OK“ erscheinen. Den bestätigten Zeitpunkt zeigt:
             openssl ts -reply -in "\(stamps[0].file)" -text
           /etc/ssl/cert.pem enthält die Wurzelzertifikate des Systems (unter Linux je nach
           System z. B. /etc/ssl/certs/ca-certificates.crt). Welches Wurzelzertifikat jeder Dienst
           verwendet, steht unten unter „Technische Angaben“.
           Meldet openssl einen „ess signing certificate error“, ist es für diesen Stempel zu alt:
           Das betrifft das in macOS eingebaute openssl (LibreSSL) bei manchen Diensten. Nehmen
           Sie dann OpenSSL ab Version 1.1 (unter Linux vorinstalliert, auf dem Mac z. B. über
           Homebrew: „brew install openssl“).


        """
        return text
    }

    private static func technicalStamps(_ stamps: [StampFile]) -> String {
        var text = ""
        for stamp in stamps {
            text += "Zeitstempel \(stamp.record.authority) (RFC 3161): \(stamp.file)"
            if let verification = stamp.verification {
                text += ", Seriennummer \(verification.serial), ausgestellt von „\(verification.signer)“"
            }
            if let root = stamp.rootName, let print = stamp.rootFingerprint {
                text += "\n  Wurzelzertifikat: „\(root)“, SHA-256-Fingerabdruck\n  \(print)"
            }
            text += "\n"
        }
        return text
    }

    static func describe(_ info: SignatureInfo) -> String {
        switch info.state {
        case .good: "gültig"
        case .unknownKey: "gültig, Schlüssel nicht hinterlegt"
        case .expired: "gültig, Schlüssel inzwischen abgelaufen"
        case .bad: "UNGÜLTIG"
        case .cannotCheck: "auf diesem Mac nicht prüfbar"
        case .unsigned: "nicht signiert"
        }
    }

    private static func heading(_ title: String, _ underline: Character) -> String {
        title + "\n" + String(repeating: underline, count: title.count) + "\n\n"
    }

    static func long(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "EEEE, d. MMMM yyyy, HH:mm:ss 'Uhr' (zzz)"
        return formatter.string(from: date)
    }
}
