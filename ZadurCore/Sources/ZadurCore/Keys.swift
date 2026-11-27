import Foundation

/// A passphrase-less SSH key that Zadur uses for one book's server, so syncing after every ⌘S
/// doesn't ask for a password or Touch ID.
///
/// Limits on purpose: one key per book and per Mac, stored outside the book (never synced),
/// readable only by the user, and used only for that book (via the book's local
/// `core.sshCommand`, bypassing any SSH agent). Meant to be added on the server as a deploy key
/// of that one repository, not to the user's account.
public struct SSHKey: Equatable {
    public let privateKeyURL: URL
    public let publicKey: String
    public let fingerprint: String

    public var publicKeyURL: URL { privateKeyURL.appendingPathExtension("pub") }

    /// Where Zadur keeps its keys (books name theirs by path, so the folder keeps its old name).
    /// Overridable for tests.
    public static var folder: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Stet/Keys", isDirectory: true)

    public enum KeyError: Error, LocalizedError {
        case generationFailed(String)
        case missing(URL)

        public var errorDescription: String? {
            switch self {
            case .generationFailed(let detail): "Der Schlüssel konnte nicht angelegt werden: \(detail)"
            case .missing(let url): "Der Schlüssel „\(url.lastPathComponent)“ fehlt."
            }
        }
    }

    /// Creates a new ed25519 key without passphrase. `label` names the file and the key's comment.
    public static func create(label: String) throws -> SSHKey {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let name = "\(Book.slug(label))-\(ZadurID.make())_ed25519"
        let url = folder.appendingPathComponent(name)
        let host = ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? "Mac"
        let comment = "Zadur – \(label) – \(host)"
        let result = try run(URL(fileURLWithPath: "/usr/bin/ssh-keygen"), ["-q", "-t", "ed25519", "-N", "", "-C", comment, "-f", url.path])
        guard result.status == 0 else { throw KeyError.generationFailed(result.output) }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return try load(url)
    }

    public static func load(_ privateKeyURL: URL) throws -> SSHKey {
        let publicURL = privateKeyURL.appendingPathExtension("pub")
        guard FileManager.default.fileExists(atPath: privateKeyURL.path),
              let publicKey = try? String(contentsOf: publicURL, encoding: .utf8)
        else { throw KeyError.missing(privateKeyURL) }
        let print = try run(URL(fileURLWithPath: "/usr/bin/ssh-keygen"), ["-l", "-f", publicURL.path])
        let fingerprint = print.output.split(separator: " ").first { $0.hasPrefix("SHA256:") }.map(String.init) ?? ""
        return SSHKey(privateKeyURL: privateKeyURL, publicKey: publicKey.trimmingCharacters(in: .whitespacesAndNewlines), fingerprint: fingerprint)
    }

    /// Deletes the key files.
    public func delete() throws {
        let fm = FileManager.default
        for url in [privateKeyURL, publicKeyURL] where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }

    /// The ssh command that uses only this key: no agent (no Secretive/Touch ID), no other keys.
    public var sshCommand: String { Self.sshCommand(forKeyAt: privateKeyURL.path) }

    private static func sshCommand(forKeyAt path: String) -> String {
        "ssh -i '\(path)' -o IdentitiesOnly=yes -o IdentityAgent=none"
    }

    /// A book names its key by path, and a book may come from someone else: only a key this Mac
    /// made counts (in its folder, a plain name), or the path could smuggle a command into ssh's.
    static func isOwnKey(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.path == path, url.deletingLastPathComponent().path == folder.standardizedFileURL.path,
              !path.contains("'"), !path.contains("\n")
        else { return false }
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeRegular
    }

    /// Whether `command` is exactly what Zadur itself sets as `core.sshCommand` for one of its keys.
    static func isOwnCommand(_ command: String) -> Bool {
        let parts = command.components(separatedBy: "'")
        return parts.count == 3 && isOwnKey(parts[1]) && command == sshCommand(forKeyAt: parts[1])
    }

    private static func run(_ tool: URL, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

extension Book {
    private static let keyConfig = "stet.sshKey"

    /// The key Zadur uses for this book's server, if one was set up.
    public func zadurKey() async -> SSHKey? {
        let output = try? await git.run(["config", "--get", Self.keyConfig], allowedStatus: [0, 1])
        guard let path = output?.string.trimmingCharacters(in: .whitespacesAndNewlines), SSHKey.isOwnKey(path) else { return nil }
        return try? SSHKey.load(URL(fileURLWithPath: path))
    }

    /// The ssh command with this book's key, if it has one of this Mac's.
    func ownSSHCommand() async -> String? { await zadurKey()?.sshCommand }

    /// Uses `key` for this book's server from now on (local git config, not synced).
    public func use(_ key: SSHKey) async throws {
        try await git.run(["config", Self.keyConfig, key.privateKeyURL.path])
        try await git.run(["config", "core.sshCommand", key.sshCommand])
    }

    /// Creates a key for this book and uses it.
    @discardableResult
    public func createZadurKey() async throws -> SSHKey {
        let key = try SSHKey.create(label: manifest.title)
        try await use(key)
        return key
    }

    /// Stops using the book's key and deletes it from this Mac. (Remove it on the server too.)
    public func removeZadurKey() async throws {
        let key = await zadurKey()
        try await forgetZadurKey()
        try key?.delete()
    }

    /// Stops using the book's key but keeps it (e.g. a copy no longer connected; the original
    /// still uses the key).
    func forgetZadurKey() async throws {
        try await git.run(["config", "--unset", Self.keyConfig], allowedStatus: [0, 5])
        try await git.run(["config", "--unset", "core.sshCommand"], allowedStatus: [0, 5])
    }
}
