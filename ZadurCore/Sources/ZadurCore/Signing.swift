import Foundation
import Security

// MARK: - How this Mac signs

/// The key Zadur signs versions, milestones and exports with. Zadur never changes the user's
/// git or GPG configuration: everything is passed to git per call.
public enum SigningMethod: Codable, Hashable {
    /// Zadur's own SSH key for this Mac (no passphrase, no prompts).
    case zadurKey(path: String)
    /// A key in an SSH agent such as Secretive or 1Password.
    case sshAgent(socket: String, publicKey: String)
    /// An S/MIME certificate from the keychain, through smimesign.
    case smime(program: String, certificateID: String)
    /// An OpenPGP key, through GnuPG.
    case openpgp(program: String, keyID: String)

    /// As stored in the settings (from when Zadur was called Stet).
    enum CodingKeys: String, CodingKey { case zadurKey = "stetKey", sshAgent, smime, openpgp }
}

public struct SigningSetup: Codable, Equatable {
    public var method: SigningMethod
    /// How Zadur describes the key ("Zadur-Schlüssel dieses Macs", "S/MIME: …").
    public var label: String
    /// SSH fingerprint, certificate or key ID.
    public var fingerprint: String
    /// Name and e-mail for the versions (e.g. the certificate's address); nil keeps the default.
    public var name: String?
    public var email: String?

    public init(method: SigningMethod, label: String, fingerprint: String, name: String? = nil, email: String? = nil) {
        self.method = method
        self.label = label
        self.fingerprint = fingerprint
        self.name = name
        self.email = email
    }

    public var kind: SigningOption.Kind {
        switch method {
        case .zadurKey: .zadurKey
        case .sshAgent: .sshAgent
        case .smime: .smime
        case .openpgp: .openpgp
        }
    }

    var format: String {
        switch method {
        case .zadurKey, .sshAgent: "ssh"
        case .smime: "x509"
        case .openpgp: "openpgp"
        }
    }

    /// The public key line, for the SSH methods.
    public var sshPublicKey: String? {
        switch method {
        case .zadurKey(let path):
            (try? String(contentsOfFile: path + ".pub", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        case .sshAgent(_, let key): key
        default: nil
        }
    }

    var gitArguments: [String] {
        var args = ["-c", "gpg.format=\(format)", "-c", Signing.marker, "-c", "tag.gpgsign=true"]
        switch method {
        case .zadurKey(let path):
            args += ["-c", "gpg.ssh.program=\(Tools.sshKeygen.path)", "-c", "user.signingkey=\(path)"]
        case .sshAgent(_, let key):
            args += ["-c", "gpg.ssh.program=\(Tools.sshKeygen.path)", "-c", "user.signingkey=key::\(key)"]
        case .smime(let program, let id):
            args += ["-c", "gpg.x509.program=\(program)", "-c", "user.signingkey=\(id)"]
        case .openpgp(let program, let id):
            args += ["-c", "gpg.program=\(program)", "-c", "user.signingkey=\(id)"]
        }
        if let name, !name.isEmpty { args += ["-c", "user.name=\(name)"] }
        if let email, !email.isEmpty { args += ["-c", "user.email=\(email)"] }
        return args
    }

    var environment: [String: String] {
        if case .sshAgent(let socket, _) = method { return ["SSH_AUTH_SOCK": socket] }
        return [:]
    }
}

public enum Signing {
    /// The setup in use on this Mac (set by the app; nil = versions aren't signed).
    public static var current: SigningSetup?
    /// Called, on any thread, when something had to be saved without a signature.
    public static var onFailure: ((String) -> Void)?

    static let marker = "commit.gpgsign=true"
    private static let signingKeys = ["gpg.format", "gpg.ssh.program", "gpg.x509.program", "gpg.program", "user.signingkey", "commit.gpgsign", "tag.gpgsign"]

    /// `arguments` without the signing options (the identity stays).
    static func unsigned(_ arguments: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < arguments.count {
            if arguments[index] == "-c", index + 1 < arguments.count,
               let key = arguments[index + 1].split(separator: "=").first, signingKeys.contains(String(key))
            {
                index += 2
                continue
            }
            result.append(arguments[index])
            index += 1
        }
        return result
    }

    /// Plain-language reason from what git or the signing tool printed.
    static func explain(_ stderr: String) -> String {
        let text = stderr.lowercased()
        if text.contains("agent refused") || text.contains("communication with agent failed") || text.contains("cancel") {
            return "Die Signatur wurde abgelehnt oder abgebrochen (z. B. Touch ID)."
        }
        if text.contains("no such file") || text.contains("couldn't load") || text.contains("could not open") {
            return "Der Schlüssel wurde nicht gefunden."
        }
        if text.contains("agent") && (text.contains("connect") || text.contains("not running")) {
            return "Der SSH-Agent läuft nicht."
        }
        if text.contains("no secret key") || text.contains("could not find identity") || text.contains("no identity") {
            return "Das Zertifikat oder der Schlüssel ist auf diesem Mac nicht (mehr) vorhanden."
        }
        if text.contains("expired") { return "Der Schlüssel oder das Zertifikat ist abgelaufen." }
        let lines = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.suffix(2).joined(separator: " ")
    }

    // MARK: Finding keys

    static var smimesign: URL? { Tools.find("smimesign") }
    static var gpg: URL? { Tools.find("gpg", extraFolders: ["/usr/local/MacGPG2/bin"]) }

    /// SSH agents with sockets on this Mac.
    static func agentSockets() -> [(name: String, path: String)] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var sockets = [
            ("Secretive", "\(home)/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh"),
            ("1Password", "\(home)/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"),
        ]
        if let system = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"], !sockets.contains(where: { $0.1 == system }) {
            sockets.append(("SSH-Agent", system))
        }
        return sockets.filter { FileManager.default.fileExists(atPath: $0.1) }
    }

    public struct AgentKey: Equatable {
        public let publicKey: String
        public let fingerprint: String
        public let comment: String
    }

    /// The keys an agent offers (listing them never asks for Touch ID).
    public static func agentKeys(socket: String) -> [AgentKey] {
        guard let result = try? Tools.run(Tools.sshAdd, ["-L"], environment: ["SSH_AUTH_SOCK": socket]), result.status == 0 else { return [] }
        return result.text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count >= 2 else { return nil }
            let key = parts[0] + " " + parts[1]
            return AgentKey(publicKey: key, fingerprint: fingerprint(ofPublicKey: key) ?? "", comment: parts.count > 2 ? parts[2] : "")
        }
    }

    static func fingerprint(ofPublicKey key: String) -> String? {
        let result = try? Tools.run(Tools.sshKeygen, ["-l", "-f", "-"], input: Data((key + "\n").utf8))
        return result?.text.split(separator: " ").first { $0.hasPrefix("SHA256:") }.map(String.init)
    }

    public struct Certificate: Equatable {
        public let id: String
        public let subject: String
        public let issuer: String
        public let emails: [String]
        public let validUntil: Date?
        public var isExpired: Bool { validUntil.map { $0 < Date() } ?? false }
    }

    /// Parses `smimesign --list-keys`.
    static func parseSmimesignList(_ text: String) -> [Certificate] {
        text.components(separatedBy: "\n\n").compactMap { block in
            var fields: [String: String] = [:]
            for line in block.split(separator: "\n") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                fields[line[..<colon].trimmingCharacters(in: .whitespaces)] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard let id = fields["ID"], !id.isEmpty else { return nil }
            var validUntil: Date?
            if let validity = fields["Validity"], let end = validity.components(separatedBy: " - ").last {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z 'UTC'"
                validUntil = formatter.date(from: end)
            }
            return Certificate(
                id: id,
                subject: commonName(fields["Subject"] ?? ""),
                issuer: commonName(fields["Issuer"] ?? ""),
                emails: (fields["Emails"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                validUntil: validUntil
            )
        }
    }

    /// "CN=Max Muster,O=…" → "Max Muster".
    static func commonName(_ distinguishedName: String) -> String {
        for part in distinguishedName.split(separator: ",") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("CN=") { return String(trimmed.dropFirst(3)) }
        }
        return distinguishedName
    }

    public struct OpenPGPKey: Equatable {
        public let fingerprint: String
        public let userID: String
        public let validUntil: Date?
    }

    /// Parses `gpg --list-secret-keys --with-colons`: usable signing keys only.
    static func parseGPGColons(_ text: String) -> [OpenPGPKey] {
        var keys: [OpenPGPKey] = []
        var current: (usable: Bool, expires: Date?, fingerprint: String?, uid: String?)?
        func flush() {
            if let c = current, c.usable, let fingerprint = c.fingerprint {
                keys.append(OpenPGPKey(fingerprint: fingerprint, userID: c.uid ?? fingerprint, validUntil: c.expires))
            }
        }
        for line in text.split(separator: "\n") {
            let f = line.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            switch f.first {
            case "sec":
                flush()
                let validity = f.count > 1 ? f[1] : ""
                let capabilities = f.count > 11 ? f[11] : ""
                let expires = f.count > 6 ? TimeInterval(f[6]).map(Date.init(timeIntervalSince1970:)) : nil
                current = (!["e", "r", "d", "i"].contains(validity) && capabilities.contains("S"), expires, nil, nil)
            case "fpr" where current != nil && current?.fingerprint == nil:
                current?.fingerprint = f.count > 9 ? f[9] : nil
            case "uid" where current != nil && current?.uid == nil:
                current?.uid = f.count > 9 ? f[9].replacingOccurrences(of: "\\x3a", with: ":") : nil
            case "ssb":
                // Subkeys come after the primary key's fpr and uid; nothing more to read.
                break
            default:
                break
            }
        }
        flush()
        return keys
    }

    /// S/MIME identities in the keychain (counted without touching their private keys).
    static func keychainEmailIdentities() -> Int {
        let query: [String: Any] = [kSecClass as String: kSecClassIdentity, kSecMatchLimit as String: kSecMatchLimitAll, kSecReturnRef as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let identities = result as? [SecIdentity] else { return 0 }
        return identities.filter { identity in
            var certificate: SecCertificate?
            SecIdentityCopyCertificate(identity, &certificate)
            var emails: CFArray?
            if let certificate { SecCertificateCopyEmailAddresses(certificate, &emails) }
            return !((emails as? [String]) ?? []).isEmpty
        }.count
    }

    /// Everything this Mac could sign with.
    public static func discover() async -> SigningDiscovery {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: discoverNow())
            }
        }
    }

    private static func discoverNow() -> SigningDiscovery {
        var discovery = SigningDiscovery()
        let host = ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? "Mac"

        if let existing = existingZadurKey() {
            discovery.options.append(SigningOption(kind: .zadurKey, title: "Zadur-Schlüssel dieses Macs",
                                                   detail: existing.fingerprint, setup: zadurKeySetup(existing)))
        } else {
            discovery.options.append(SigningOption(kind: .zadurKey, title: "Zadur-Schlüssel für diesen Mac",
                                                   detail: "wird beim Einrichten angelegt (\(host))", setup: nil))
        }

        if let program = smimesign {
            discovery.hasSmimesign = true
            let list = (try? Tools.run(program, ["--list-keys"]))?.text ?? ""
            for certificate in parseSmimesignList(list) {
                var detail = "ausgestellt von \(certificate.issuer)"
                if let until = certificate.validUntil {
                    detail += certificate.isExpired ? " · abgelaufen" : " · gültig bis \(until.formatted(date: .numeric, time: .omitted))"
                }
                let email = certificate.emails.first
                let setup = SigningSetup(method: .smime(program: program.path, certificateID: certificate.id),
                                         label: "S/MIME: \(certificate.subject)" + (email.map { " <\($0)>" } ?? ""),
                                         fingerprint: certificate.id, email: email)
                discovery.options.append(SigningOption(kind: .smime, title: "S/MIME: \(certificate.subject)" + (email.map { " (\($0))" } ?? ""),
                                                       detail: detail, setup: setup, isUsable: !certificate.isExpired))
            }
        } else {
            discovery.smimeCertificatesWithoutTool = keychainEmailIdentities()
        }

        for socket in agentSockets() {
            for key in agentKeys(socket: socket.path) {
                let comment = key.comment.isEmpty ? key.fingerprint : key.comment
                let setup = SigningSetup(method: .sshAgent(socket: socket.path, publicKey: key.publicKey),
                                         label: "\(socket.name): \(comment)", fingerprint: key.fingerprint)
                discovery.options.append(SigningOption(kind: .sshAgent, title: "\(socket.name): \(comment)",
                                                       detail: key.fingerprint, setup: setup))
            }
        }

        if let program = gpg {
            discovery.hasGPG = true
            let list = (try? Tools.run(program, ["--list-secret-keys", "--with-colons", "--fixed-list-mode"]))?.text ?? ""
            for key in parseGPGColons(list) {
                var detail = "Schlüssel \(key.fingerprint.suffix(16))"
                if let until = key.validUntil { detail += " · gültig bis \(until.formatted(date: .numeric, time: .omitted))" }
                let setup = SigningSetup(method: .openpgp(program: program.path, keyID: key.fingerprint),
                                         label: "OpenPGP: \(key.userID)", fingerprint: key.fingerprint)
                discovery.options.append(SigningOption(kind: .openpgp, title: "OpenPGP: \(key.userID)", detail: detail, setup: setup))
            }
        }
        return discovery
    }

    // MARK: Zadur's own key

    static let zadurKeyLabel = "Signatur"

    static func existingZadurKey() -> SSHKey? {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: SSHKey.folder.path)) ?? []
        let name = files.sorted().first { $0.hasPrefix(Book.slug(zadurKeyLabel) + "-") && $0.hasSuffix("_ed25519") }
        return name.flatMap { try? SSHKey.load(SSHKey.folder.appendingPathComponent($0)) }
    }

    static func zadurKeySetup(_ key: SSHKey) -> SigningSetup {
        SigningSetup(method: .zadurKey(path: key.privateKeyURL.path), label: "Zadur-Schlüssel dieses Macs", fingerprint: key.fingerprint)
    }

    /// Zadur's signing key for this Mac, created if needed.
    public static func makeZadurKey() throws -> SigningSetup {
        if let existing = existingZadurKey() { return zadurKeySetup(existing) }
        return zadurKeySetup(try SSHKey.create(label: zadurKeyLabel))
    }

    // MARK: Trying a setup

    public enum ProbeError: Error, LocalizedError {
        case failed(String)
        public var errorDescription: String? {
            if case .failed(let reason) = self { return "Die Probe-Signatur hat nicht geklappt: \(reason)" }
            return nil
        }
    }

    /// Signs a throwaway version in a temporary repository exactly as a real version would be
    /// signed (this is when Touch ID or the keychain may ask), then checks the signature.
    public static func probe(_ setup: SigningSetup) async throws -> SignatureInfo {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zadur-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let git = Git(directory: folder)
        try await git.initRepository()
        try Data("Probe\n".utf8).write(to: folder.appendingPathComponent("probe.txt"))
        try await git.run(["add", "probe.txt"])
        let output = try await git.run(
            ["-c", "user.name=Zadur", "-c", "user.email=zadur@localhost"] + setup.gitArguments + ["commit", "--quiet", "-m", "Probe"],
            environment: setup.environment, allowedStatus: Set(0...255), retryUnsigned: false
        )
        guard output.status == 0 else { throw ProbeError.failed(explain(output.stderr)) }
        let allowed = folder.appendingPathComponent("allowed_signers")
        try Data((setup.sshPublicKey.map { "* \($0)\n" } ?? "").utf8).write(to: allowed)
        let info = await git.signatures(of: ["HEAD"], allowedSigners: allowed)["HEAD"] ?? SignatureInfo(state: .unsigned, key: "", signer: "")
        guard info.isSigned else { throw ProbeError.failed("Die Version wurde nicht signiert.") }
        return info
    }

    // MARK: Signing a file (for proofs)

    public struct DetachedSignature {
        /// Files to put next to the signed file: the signature, the public key (if it has one).
        public let files: [(name: String, data: Data)]
        /// How to check it, for the proof's read-me (German, for people without Zadur).
        public let instructions: String
    }

    /// Part of every signed proof, also of those from when Zadur was called Stet: never change it.
    static let proofNamespace = "stet-nachweis"

    /// Signs `file` with `setup`; the signature file name is `file`'s name plus an extension.
    public static func signDetached(_ file: URL, with setup: SigningSetup) async throws -> DetachedSignature {
        let name = file.lastPathComponent
        let input = try Data(contentsOf: file)
        switch setup.method {
        case .zadurKey, .sshAgent:
            guard let publicKey = setup.sshPublicKey else { throw ProbeError.failed("Der öffentliche Schlüssel fehlt.") }
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("zadur-sign-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            let copy = temp.appendingPathComponent(name)
            try input.write(to: copy)
            var arguments = ["-Y", "sign", "-n", proofNamespace]
            if case .zadurKey(let path) = setup.method {
                arguments += ["-f", path]
            } else {
                let pub = temp.appendingPathComponent("key.pub")
                try Data((publicKey + "\n").utf8).write(to: pub)
                arguments += ["-f", pub.path, "-U"]
            }
            let result = try await Tools.runAsync(Tools.sshKeygen, arguments + [copy.path], environment: setup.environment)
            guard result.status == 0, let signature = FileManager.default.contents(atPath: copy.path + ".sig") else {
                throw ProbeError.failed(explain(result.errors))
            }
            let keyFile = "Schlüssel.pub", allowedFile = "Schlüssel.allowed_signers"
            return DetachedSignature(
                files: [(name + ".sig", signature), (keyFile, Data((publicKey + "\n").utf8)), (allowedFile, Data("autor \(publicKey)\n".utf8))],
                instructions: """
                Die Signatur (SSH-Schlüssel \(setup.fingerprint)):
                     ssh-keygen -Y verify -f "\(allowedFile)" -I autor -n \(proofNamespace) -s "\(name).sig" < "\(name)"
                   Es muss „Good "\(proofNamespace)" signature for autor“ erscheinen.
                """
            )
        case .smime(let program, let id):
            let result = try await Tools.runAsync(URL(fileURLWithPath: program), ["--detach-sign", "--armor", "-u", id], input: input)
            let pem = result.text
            let body = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
            guard result.status == 0, let der = Data(base64Encoded: body) else { throw ProbeError.failed(explain(result.errors)) }
            return DetachedSignature(
                files: [(name + ".p7s", der)],
                instructions: """
                Die Signatur (S/MIME-Zertifikat \(setup.label.replacingOccurrences(of: "S/MIME: ", with: ""))):
                     openssl smime -verify -binary -inform DER -in "\(name).p7s" -content "\(name)" -CAfile /etc/ssl/cert.pem -purpose any > /dev/null
                   Es muss „Verification successful“ erscheinen. Das Zertifikat steckt in der Signatur:
                     openssl pkcs7 -inform DER -in "\(name).p7s" -print_certs -noout
                """
            )
        case .openpgp(let program, let id):
            let tool = URL(fileURLWithPath: program)
            let signed = try await Tools.runAsync(tool, ["--detach-sign", "--armor", "-u", id, "--output", "-", file.path])
            guard signed.status == 0, !signed.output.isEmpty else { throw ProbeError.failed(explain(signed.errors)) }
            let exported = try await Tools.runAsync(tool, ["--export", "--armor", id])
            return DetachedSignature(
                files: [(name + ".asc", signed.output), ("Schlüssel.asc", exported.output)],
                instructions: """
                Die Signatur (OpenPGP-Schlüssel \(setup.fingerprint)):
                     gpg --import "Schlüssel.asc"
                     gpg --verify "\(name).asc" "\(name)"
                   Es muss „Good signature“ bzw. „Korrekte Signatur“ erscheinen.
                """
            )
        }
    }
}

public struct SigningOption: Identifiable, Equatable {
    public enum Kind: String, Codable { case zadurKey = "stetKey", sshAgent, smime, openpgp }
    public let kind: Kind
    public let title: String
    public let detail: String
    /// nil for Zadur's key when it doesn't exist yet (it's created on choosing it).
    public let setup: SigningSetup?
    public var isUsable = true
    public var id: String { kind.rawValue + ":" + (setup?.fingerprint ?? "new") }

    public init(kind: Kind, title: String, detail: String, setup: SigningSetup?, isUsable: Bool = true) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.setup = setup
        self.isUsable = isUsable
    }
}

public struct SigningDiscovery: Equatable {
    public var options: [SigningOption] = []
    /// S/MIME certificates in the keychain that can't be used because smimesign is missing.
    public var smimeCertificatesWithoutTool = 0
    public var hasSmimesign = false
    public var hasGPG = false

    public init(options: [SigningOption] = [], smimeCertificatesWithoutTool: Int = 0, hasSmimesign: Bool = false, hasGPG: Bool = false) {
        self.options = options
        self.smimeCertificatesWithoutTool = smimeCertificatesWithoutTool
        self.hasSmimesign = hasSmimesign
        self.hasGPG = hasGPG
    }
}

// MARK: - Checking signatures

public struct SignatureInfo: Equatable {
    public enum State: String {
        /// Valid, by a known key.
        case good
        /// Valid, but by a key this book doesn't know (or, for OpenPGP, one without trust).
        case unknownKey
        /// Valid, but the key or certificate has expired or was revoked since.
        case expired
        /// Doesn't match: the version was changed after signing.
        case bad
        /// The tool or key needed to check it is missing on this Mac.
        case cannotCheck
        case unsigned
    }

    public let state: State
    /// SSH fingerprint, certificate or key ID.
    public let key: String
    public let signer: String
    public var isSigned: Bool { state != .unsigned }

    public init(state: State, key: String, signer: String) {
        self.state = state
        self.key = key
        self.signer = signer
    }

    static func state(_ code: String) -> State {
        switch code {
        case "G": .good
        case "U": .unknownKey
        case "X", "Y", "R": .expired
        case "B": .bad
        case "E": .cannotCheck
        default: .unsigned
        }
    }
}

extension Git {
    /// Options that let git check every kind of signature Zadur can make.
    static func verificationArguments(allowedSigners: URL) -> [String] {
        var args = ["-c", "gpg.ssh.program=\(Tools.sshKeygen.path)", "-c", "gpg.ssh.allowedSignersFile=\(allowedSigners.path)"]
        if let smimesign = Signing.smimesign { args += ["-c", "gpg.x509.program=\(smimesign.path)"] }
        if let gpg = Signing.gpg { args += ["-c", "gpg.program=\(gpg.path)"] }
        return args
    }

    /// Signature state of each revision, checked against the SSH keys in `allowedSigners`.
    func signatures(of revisions: [String], allowedSigners: URL) async -> [String: SignatureInfo] {
        guard !revisions.isEmpty else { return [:] }
        var result: [String: SignatureInfo] = [:]
        for chunk in stride(from: 0, to: revisions.count, by: 200).map({ Array(revisions[$0..<min($0 + 200, revisions.count)]) }) {
            let args = Self.verificationArguments(allowedSigners: allowedSigners)
                + ["log", "--no-walk=unsorted", "--format=%x1e%G?%x1f%GK%x1f%GS"] + chunk
            guard let output = try? await run(args, allowedStatus: [0, 128]), output.status == 0 else { continue }
            let records = output.string.split(separator: "\u{1e}", omittingEmptySubsequences: true)
            for (revision, record) in zip(chunk, records) {
                let fields = record.trimmingCharacters(in: .newlines).split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
                guard let code = fields.first else { continue }
                result[revision] = SignatureInfo(state: SignatureInfo.state(code), key: fields.count > 1 ? fields[1] : "", signer: fields.count > 2 ? fields[2] : "")
            }
        }
        return result
    }
}

extension Book {
    public static let signersFolder = "signers"

    public struct Signer: Equatable {
        public let fingerprint: String
        public let publicKey: String
        /// The key's comment, e.g. "Zadur – Signatur – MacBook-Air".
        public let label: String
    }

    /// SSH keys that sign this book, one file per key in `signers/` (so two Macs adding theirs
    /// never conflict). They let every Mac recognise the others' signatures.
    public func signers() -> [Signer] {
        let folder = url.appendingPathComponent(Self.signersFolder)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return files.filter { $0.hasSuffix(".pub") }.sorted().compactMap { file in
            guard let line = try? String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
                .split(separator: "\n").first.map(String.init)
            else { return nil }
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count >= 2 else { return nil }
            let key = parts[0] + " " + parts[1]
            return Signer(fingerprint: Signing.fingerprint(ofPublicKey: key) ?? "", publicKey: key, label: parts.count > 2 ? parts[2] : "")
        }
    }

    /// Adds this Mac's SSH signing key to `signers/` if it isn't there yet. Returns true if added.
    @discardableResult
    public func registerSigner(_ setup: SigningSetup, label: String? = nil) throws -> Bool {
        guard let line = setup.sshPublicKey else { return false }
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return false }
        let key = parts[0] + " " + parts[1]
        if signers().contains(where: { $0.publicKey == key }) { return false }
        let folder = url.appendingPathComponent(Self.signersFolder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = setup.fingerprint.replacingOccurrences(of: "SHA256:", with: "")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
        let comment = label ?? (parts.count > 2 ? parts[2] : setup.label)
        try Data("\(key) \(comment)\n".utf8).write(to: folder.appendingPathComponent("\(name.prefix(24)).pub"))
        return true
    }

    /// Signature state of versions (commits or tags).
    public func signatures(of revisions: [String]) async -> [String: SignatureInfo] {
        let allowed = FileManager.default.temporaryDirectory.appendingPathComponent("zadur-signers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: allowed) }
        var keys = signers().map(\.publicKey)
        if let own = Signing.current?.sshPublicKey { keys.append(own) }
        try? Data(keys.map { "* \($0)\n" }.joined().utf8).write(to: allowed)
        return await git.signatures(of: revisions, allowedSigners: allowed)
    }
}
