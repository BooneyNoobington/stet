import Foundation
import Security

// MARK: - Addresses

/// A git server address, as far as logging in is concerned.
public struct ServerEndpoint: Equatable {
    public enum Kind: String { case ssh, https, http }

    public let kind: Kind
    public let host: String
    public let port: Int?
    public var user: String?
    /// The repository's path on the server (for SSH: absolute, `~/…`, or relative to the home folder).
    public let path: String
    /// "ssh://…" or "https://…" (as opposed to the short form `user@host:path`).
    let isURL: Bool

    /// `ssh://user@host:port/path`, `user@host:path`, `https://user@host/path`; nil for local paths.
    public static func parse(_ address: String) -> ServerEndpoint? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("://") {
            guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
                  let kind = Kind(rawValue: scheme == "git+ssh" ? "ssh" : scheme), let host = components.host, !host.isEmpty
            else { return nil }
            return ServerEndpoint(kind: kind, host: host, port: components.port,
                                  user: components.user?.removingPercentEncoding.flatMap { $0.isEmpty ? nil : $0 },
                                  path: components.percentEncodedPath.removingPercentEncoding ?? components.path, isURL: true)
        }
        // The short form: [user@]host:path, where host has no slash (a local path would).
        guard let colon = trimmed.firstIndex(of: ":"), !trimmed[..<colon].contains("/"), !trimmed.hasPrefix("/") else { return nil }
        let destination = String(trimmed[..<colon])
        let path = String(trimmed[trimmed.index(after: colon)...])
        let parts = destination.split(separator: "@", maxSplits: 1).map(String.init)
        let host = parts.count == 2 ? parts[1] : parts[0]
        guard !host.isEmpty, !path.isEmpty else { return nil }
        return ServerEndpoint(kind: .ssh, host: host, port: nil, user: parts.count == 2 ? parts[0] : nil, path: path, isURL: false)
    }

    /// The same address with this user in it (never a password).
    public func address(withUser newUser: String) -> String {
        let user = newUser.trimmingCharacters(in: .whitespaces)
        if !isURL { return "\(user)@\(host):\(path)" }
        var components = URLComponents()
        components.scheme = kind.rawValue
        components.user = user.isEmpty ? nil : user
        components.host = host
        components.port = port
        components.path = path
        return components.string ?? "\(kind.rawValue)://\(user)@\(host)\(path)"
    }

    var keychainProtocol: CFString {
        switch kind {
        case .ssh: kSecAttrProtocolSSH
        case .https: kSecAttrProtocolHTTPS
        case .http: kSecAttrProtocolHTTP
        }
    }
}

// MARK: - Stored logins

/// A user name and password (or access token) for a git server.
public struct ServerLogin: Equatable {
    public var user: String
    public var password: String

    public init(user: String, password: String) {
        self.user = user
        self.password = password
    }
}

public protocol LoginStore: AnyObject {
    /// The login for this server (with its user if the address names one, otherwise the first one stored).
    func login(for endpoint: ServerEndpoint) -> ServerLogin?
    func save(_ login: ServerLogin, for endpoint: ServerEndpoint) throws
    func remove(for endpoint: ServerEndpoint) throws
}

public enum ServerLogins {
    /// Where the app keeps passwords: the keychain. Tests use a temporary keychain or memory.
    public static var store: LoginStore = KeychainLoginStore()
}

/// Passwords in memory only (tests, or a login that isn't to be kept).
public final class MemoryLoginStore: LoginStore {
    private var logins: [String: ServerLogin] = [:]
    public init() {}

    private func key(_ endpoint: ServerEndpoint, user: String?) -> String {
        "\(endpoint.kind.rawValue)://\(user ?? "")@\(endpoint.host):\(endpoint.port ?? 0)"
    }

    public func login(for endpoint: ServerEndpoint) -> ServerLogin? {
        if let user = endpoint.user { return logins[key(endpoint, user: user)] }
        let prefix = "\(endpoint.kind.rawValue)://"
        let suffix = "@\(endpoint.host):\(endpoint.port ?? 0)"
        return logins.first { $0.key.hasPrefix(prefix) && $0.key.hasSuffix(suffix) }?.value
    }

    public func save(_ login: ServerLogin, for endpoint: ServerEndpoint) throws {
        logins[key(endpoint, user: login.user)] = login
    }

    public func remove(for endpoint: ServerEndpoint) throws {
        if let user = endpoint.user ?? login(for: endpoint)?.user { logins[key(endpoint, user: user)] = nil }
    }
}

/// Internet passwords in the keychain, marked as Stet's (comment "Stet"): host, protocol, port
/// and user name in the clear, the password encrypted by macOS.
public final class KeychainLoginStore: LoginStore {
    /// nil: the user's default keychain. Tests pass a temporary one.
    private let keychain: SecKeychain?

    public init(keychain: SecKeychain? = nil) {
        self.keychain = keychain
    }

    private func query(_ endpoint: ServerEndpoint, user: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: endpoint.host,
            kSecAttrProtocol as String: endpoint.keychainProtocol,
            kSecAttrComment as String: "Stet",
        ]
        if let port = endpoint.port { query[kSecAttrPort as String] = port }
        if let user { query[kSecAttrAccount as String] = user }
        if let keychain { query[kSecMatchSearchList as String] = [keychain] }
        return query
    }

    public func login(for endpoint: ServerEndpoint) -> ServerLogin? {
        var search = query(endpoint, user: endpoint.user)
        search[kSecReturnAttributes as String] = true
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess,
              let item = result as? [String: Any],
              let account = item[kSecAttrAccount as String] as? String,
              let data = item[kSecValueData as String] as? Data
        else { return nil }
        return ServerLogin(user: account, password: String(decoding: data, as: UTF8.self))
    }

    public func save(_ login: ServerLogin, for endpoint: ServerEndpoint) throws {
        try? remove(for: ServerEndpoint(kind: endpoint.kind, host: endpoint.host, port: endpoint.port, user: login.user,
                                        path: endpoint.path, isURL: endpoint.isURL))
        var item = query(endpoint, user: login.user)
        item.removeValue(forKey: kSecMatchSearchList as String)
        item[kSecAttrLabel as String] = "Stet – \(endpoint.host)"
        item[kSecValueData as String] = Data(login.password.utf8)
        if let keychain { item[kSecUseKeychain as String] = keychain }
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw LoginError.keychain(status) }
    }

    public func remove(for endpoint: ServerEndpoint) throws {
        let status = SecItemDelete(query(endpoint, user: endpoint.user) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LoginError.keychain(status) }
    }
}

public enum LoginError: Error, LocalizedError {
    case keychain(OSStatus)
    case askpass(String)

    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            "Der Schlüsselbund hat das Passwort nicht angenommen (\(SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "\(status)"))."
        case .askpass(let detail): "Stet konnte die Anmeldung nicht vorbereiten: \(detail)"
        }
    }
}

// MARK: - Answering git's and ssh's questions

/// While a network command runs, git (`GIT_ASKPASS`) and ssh (`SSH_ASKPASS`) ask a tiny script for
/// the user name and password; the script asks Stet over a private socket. The password never
/// appears in a command line, a file or the environment; only the socket's address and a
/// one-time token do, and the socket is gone when the command ends.
final class AskpassServer {
    let folder: URL
    let socketPath: String
    let script: URL
    private let token = UUID().uuidString
    private let descriptor: Int32
    private let answer: (String) -> String?
    private let lock = NSLock()
    private var stopped = false
    private var askedPrompts: [String] = []

    /// The prompts git or ssh showed (never the answers): for tests and error messages.
    var prompts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return askedPrompts
    }

    convenience init(login: ServerLogin) throws {
        try self.init { prompt in AskpassServer.answer(prompt, with: login) }
    }

    init(answer: @escaping (String) -> String?) throws {
        self.answer = answer
        let fm = FileManager.default
        folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("stet-ask-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        socketPath = folder.appendingPathComponent("s").path
        script = folder.appendingPathComponent("askpass")
        let text = """
        #!/bin/sh
        # Stet's helper for git and ssh: asks the running Stet for the answer to a login prompt.
        printf '%s\\n%s\\n' "$STET_ASKPASS_TOKEN" "$1" | /usr/bin/nc -U "$STET_ASKPASS_SOCKET"

        """
        try Data(text.utf8).write(to: script)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LoginError.askpass("socket \(errno)") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw LoginError.askpass("path too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in path.enumerated() { buffer[index] = UInt8(bitPattern: byte) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw LoginError.askpass("bind \(errno)")
        }
        descriptor = fd
        let thread = Thread { [weak self] in self?.serve() }
        thread.name = "Stet askpass"
        thread.start()
    }

    deinit { stop() }

    /// What to answer: the user name to "Username for …", the password to "… password: ",
    /// nothing to anything else (key passphrases, unknown questions).
    static func answer(_ prompt: String, with login: ServerLogin) -> String? {
        let text = prompt.lowercased()
        if text.contains("username") { return login.user }
        if text.contains("password") { return login.password }
        return nil
    }

    var environment: [String: String] {
        [
            "GIT_ASKPASS": script.path,
            "SSH_ASKPASS": script.path,
            "SSH_ASKPASS_REQUIRE": "force",
            "DISPLAY": ProcessInfo.processInfo.environment["DISPLAY"] ?? ":0",
            "STET_ASKPASS_SOCKET": socketPath,
            "STET_ASKPASS_TOKEN": token,
        ]
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func serve() {
        var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        while !isStopped {
            guard poll(&poller, 1, 200) > 0 else { continue }
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { continue }
            handle(client)
            close(client)
        }
    }

    private func handle(_ client: Int32) {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while data.count < 16_384, data.filter({ $0 == 0x0a }).count < 2 {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
        }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        var reply = ""
        if lines.count == 2, lines[0] == token {
            let prompt = lines[1].trimmingCharacters(in: .newlines)
            lock.lock()
            askedPrompts.append(prompt)
            lock.unlock()
            reply = answer(prompt) ?? ""
        }
        let bytes = Array((reply + "\n").utf8)
        _ = bytes.withUnsafeBytes { write(client, $0.baseAddress, bytes.count) }
    }

    func stop() {
        lock.lock()
        let wasStopped = stopped
        stopped = true
        lock.unlock()
        guard !wasStopped else { return }
        close(descriptor)
        try? FileManager.default.removeItem(at: folder)
    }
}
