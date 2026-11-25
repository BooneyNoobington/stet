import Foundation
import Security
import XCTest
@testable import ZadurCore

/// Logging in with a user name and password. Everything runs on this Mac: a git server over HTTP
/// with a password (as Gitea offers it), a stand-in for ssh that asks for the password like ssh
/// does, and a throwaway keychain. All names and passwords are made up.
final class ServerLoginTests: TempDirTestCase {
    private var savedStore: LoginStore!
    private var savedSSH: String!
    private var server: Process?

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedStore = ServerLogins.store
        savedSSH = Book.sshProgram
        ServerLogins.store = MemoryLoginStore()
    }

    override func tearDownWithError() throws {
        server?.terminate()
        ServerLogins.store = savedStore
        Book.sshProgram = savedSSH
        try super.tearDownWithError()
    }

    // MARK: Addresses

    func testParsesServerAddresses() {
        let short = ServerEndpoint.parse("claude@raspi.local:buecher/roman.git")
        XCTAssertEqual(short?.kind, .ssh)
        XCTAssertEqual(short?.user, "claude")
        XCTAssertEqual(short?.host, "raspi.local")
        XCTAssertEqual(short?.path, "buecher/roman.git")
        XCTAssertEqual(short?.address(withUser: "anna"), "anna@raspi.local:buecher/roman.git")

        let ssh = ServerEndpoint.parse("ssh://git@git.example.com:2222/autorin/buch.git")
        XCTAssertEqual(ssh?.port, 2222)
        XCTAssertEqual(ssh?.path, "/autorin/buch.git")

        let https = ServerEndpoint.parse("https://git.example.com/autorin/buch.git")
        XCTAssertEqual(https?.kind, .https)
        XCTAssertNil(https?.user)
        XCTAssertEqual(https?.address(withUser: "autorin"), "https://autorin@git.example.com/autorin/buch.git")

        XCTAssertNil(ServerEndpoint.parse("/Users/x/server.git"))
        XCTAssertNil(ServerEndpoint.parse("../server.git"))
        XCTAssertEqual(Book.remotePath("/~/b.git", isURL: true), "~/'b.git'")
        XCTAssertEqual(Book.remotePath("buecher/O'Brien.git", isURL: false), "'buecher/O'\\''Brien.git'")
    }

    // MARK: The askpass channel

    func testAskpassAnswersOnlyWhatItShould() throws {
        let askpass = try AskpassServer(login: ServerLogin(user: "autorin", password: "sehr geheim"))
        defer { askpass.stop() }
        func ask(_ prompt: String, token: String? = nil) throws -> String {
            var environment = askpass.environment
            if let token { environment["ZADUR_ASKPASS_TOKEN"] = token }
            return try Tools.run(askpass.script, [prompt], environment: environment).text.trimmingCharacters(in: .newlines)
        }
        XCTAssertEqual(try ask("Username for 'https://git.example.com': "), "autorin")
        XCTAssertEqual(try ask("Password for 'https://autorin@git.example.com': "), "sehr geheim")
        XCTAssertEqual(try ask("claude@raspi.local's password: "), "sehr geheim")
        XCTAssertEqual(try ask("Enter passphrase for key '/x/id_ed25519': "), "", "never guesses a key passphrase")
        XCTAssertEqual(try ask("Password: ", token: "falsch"), "", "the token is required")
        XCTAssertEqual(askpass.prompts.count, 4)

        let folder = askpass.folder
        askpass.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "socket and script are gone afterwards")
    }

    // MARK: Keychain (a throwaway one)

    func testKeychainKeepsLoginsPerServer() throws {
        var keychain: SecKeychain?
        let path = temp.appendingPathComponent("test.keychain-db").path
        let password = "test"
        let status = SecKeychainCreate(path, UInt32(password.utf8.count), password, false, nil, &keychain)
        XCTAssertEqual(status, errSecSuccess)
        defer { if let keychain { SecKeychainDelete(keychain) } }
        let store = KeychainLoginStore(keychain: keychain)

        let endpoint = try XCTUnwrap(ServerEndpoint.parse("https://git.example.com/autorin/buch.git"))
        XCTAssertNil(store.login(for: endpoint))
        try store.save(ServerLogin(user: "autorin", password: "eins"), for: endpoint)
        XCTAssertEqual(store.login(for: endpoint), ServerLogin(user: "autorin", password: "eins"), "found without a user in the address")
        try store.save(ServerLogin(user: "autorin", password: "zwei"), for: endpoint)
        XCTAssertEqual(store.login(for: endpoint)?.password, "zwei", "saving again replaces")

        let other = try XCTUnwrap(ServerEndpoint.parse("ssh://autorin@git.example.com/autorin/buch.git"))
        XCTAssertNil(store.login(for: other), "SSH and HTTPS are kept apart")

        try store.remove(for: ServerEndpoint.parse("https://autorin@git.example.com/x.git")!)
        XCTAssertNil(store.login(for: endpoint))
    }

    // MARK: HTTP with a password (like Gitea)

    /// A git server over HTTP that wants "autorin" / "Lichtung-42" (Basic auth), on 127.0.0.1.
    private func startHTTPServer() throws -> String {
        let root = temp.appendingPathComponent("http")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = temp.appendingPathComponent("server.py")
        try Data(#"""
        import base64, http.server, os, subprocess, sys
        root, user, password = sys.argv[1], sys.argv[2], sys.argv[3]
        expected = "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()

        class Handler(http.server.BaseHTTPRequestHandler):
            def git(self):
                if self.headers.get("Authorization") != expected:
                    self.send_response(401)
                    self.send_header("WWW-Authenticate", 'Basic realm="Zadur test"')
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                path, _, query = self.path.partition("?")
                body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
                env = dict(os.environ, GIT_PROJECT_ROOT=root, GIT_HTTP_EXPORT_ALL="1", REMOTE_USER=user,
                           REQUEST_METHOD=self.command, PATH_INFO=path, QUERY_STRING=query,
                           CONTENT_TYPE=self.headers.get("Content-Type", ""), CONTENT_LENGTH=str(len(body)))
                if self.headers.get("Content-Encoding"):
                    env["HTTP_CONTENT_ENCODING"] = self.headers.get("Content-Encoding")
                out = subprocess.run(["git", "http-backend"], input=body, env=env, capture_output=True).stdout
                head, _, rest = out.partition(b"\r\n\r\n")
                if not rest:
                    head, _, rest = out.partition(b"\n\n")
                status, headers = 200, []
                for line in head.decode().splitlines():
                    key, _, value = line.partition(":")
                    if key.lower() == "status":
                        status = int(value.split()[0])
                    elif key:
                        headers.append((key, value.strip()))
                self.send_response(status)
                for key, value in headers:
                    self.send_header(key, value)
                self.send_header("Content-Length", str(len(rest)))
                self.end_headers()
                self.wfile.write(rest)

            do_GET = git
            do_POST = git

            def log_message(self, *args):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        print(server.server_address[1], flush=True)
        server.serve_forever()
        """#.utf8).write(to: script)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", script.path, root.path, "autorin", "Lichtung-42"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        server = process
        var line = Data()
        while !line.contains(0x0a) {
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { break }
            line.append(chunk)
        }
        let port = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(port.isEmpty, "the test server didn't start")
        _ = try Tools.run(URL(fileURLWithPath: "/usr/bin/git"), ["init", "--quiet", "--bare", "--initial-branch=main", root.appendingPathComponent("buch.git").path])
        return "http://127.0.0.1:\(port)/buch.git"
    }

    func testHTTPWithPassword() async throws {
        let url = try startHTTPServer()
        let book = try await Book.create(at: temp.appendingPathComponent("A/Buch.crea"), title: "Buch", author: "Test")

        // Without a password the server says no, and Zadur says so in plain words.
        do {
            _ = try await book.checkRemote(url)
            XCTFail("the server accepted no password")
        } catch let error as SyncError {
            XCTAssertTrue(error.localizedDescription.contains("Anmeldung abgelehnt"), error.localizedDescription)
        }
        // A wrong password is refused and not kept.
        do {
            try await book.connect(to: url, device: "macA", login: ServerLogin(user: "fremd", password: "falsch"))
            XCTFail("a wrong password was accepted")
        } catch {}
        XCTAssertNil(ServerLogins.store.login(for: ServerEndpoint.parse(url.replacingOccurrences(of: "http://", with: "http://fremd@"))!))

        // The right one: connect, then sync with what was kept.
        try await book.connect(to: url, device: "macA", login: ServerLogin(user: "autorin", password: "Lichtung-42"))
        let remote = await book.remoteURL()
        XCTAssertEqual(remote, url.replacingOccurrences(of: "http://", with: "http://autorin@"))
        let config = try String(contentsOf: book.url.appendingPathComponent(".git/config"), encoding: .utf8)
        XCTAssertFalse(config.contains("Lichtung"), "the password is not in the book")

        var scene = try book.readScene(book.manifest.sceneIDs[0])
        scene.body = "Vom ersten Mac.\n"
        try book.writeScene(scene)
        try await book.saveVersion()
        let result = try await book.sync(device: "macA")
        XCTAssertTrue(result.pushed)

        // A second Mac fetches the book with the password.
        let other = try await Book.clone(from: url, to: temp.appendingPathComponent("B/Buch.crea"),
                                         login: ServerLogin(user: "autorin", password: "Lichtung-42"))
        XCTAssertEqual(try other.readScene(other.manifest.sceneIDs[0]).body, "Vom ersten Mac.\n")
    }

    // MARK: SSH with a password (a plain git server, e.g. a Raspberry Pi)

    /// A stand-in for ssh: checks that Zadur asks for a password the way ssh would, asks through
    /// SSH_ASKPASS, and then runs the command on this Mac (the "server" is a local folder).
    private func installFakeSSH(password: String) throws -> URL {
        let log = temp.appendingPathComponent("ssh.log")
        let fake = temp.appendingPathComponent("fake-ssh")
        try Data("""
        #!/bin/bash
        echo "$@" >> '\(log.path)'
        args=("$@"); n=${#args[@]}
        command="${args[$((n-1))]}"; destination="${args[$((n-2))]}"
        if [ "$SSH_ASKPASS_REQUIRE" != "force" ]; then echo "Permission denied (publickey)." >&2; exit 255; fi
        answer="$("$SSH_ASKPASS" "${destination}'s password: ")"
        if [ "$answer" != '\(password)' ]; then echo "${destination}: Permission denied (publickey,password)." >&2; exit 255; fi
        exec /bin/sh -c "$command"

        """.utf8).write(to: fake)
        _ = try Tools.run(URL(fileURLWithPath: "/bin/chmod"), ["+x", fake.path])
        Book.sshProgram = fake.path
        return log
    }

    func testSSHWithPasswordAndCreatingTheRepository() async throws {
        let log = try installFakeSSH(password: "Kiefer-7")
        let serverPath = temp.appendingPathComponent("raspi/home/buecher/roman.git").path
        let url = "ssh://claude@raspi.test\(serverPath)"
        let login = ServerLogin(user: "claude", password: "Kiefer-7")
        let book = try await Book.create(at: temp.appendingPathComponent("A/Roman.crea"), title: "Roman", author: "Test")

        // Nothing there yet: Zadur recognises that and can create it.
        do {
            _ = try await book.checkRemote(url, login: login)
            XCTFail("found a repository that doesn't exist")
        } catch let error as SyncError {
            XCTAssertEqual(error, .noRepository)
        }
        try await Book.createRepository(at: url, login: login)
        XCTAssertTrue(FileManager.default.fileExists(atPath: serverPath + "/HEAD"))
        let check = try await book.checkRemote(url, login: login)
        XCTAssertEqual(check, .empty)

        try await book.connect(to: url, device: "macA", login: login)
        let head = try Tools.run(URL(fileURLWithPath: "/usr/bin/git"), ["-C", serverPath, "rev-parse", "main"]).text
        let localHead = await book.git.headCommit()
        XCTAssertEqual(head.trimmingCharacters(in: .whitespacesAndNewlines), localHead)

        // How Zadur called ssh: a password once, a new server trusted, a changed one never.
        let calls = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(calls.contains("BatchMode=no"))
        XCTAssertTrue(calls.contains("NumberOfPasswordPrompts=1"))
        XCTAssertTrue(calls.contains("StrictHostKeyChecking=accept-new"))
        XCTAssertTrue(calls.contains("claude@raspi.test"))

        // A wrong password: refused, in plain words.
        do {
            _ = try await book.checkRemote(url, login: ServerLogin(user: "claude", password: "falsch"))
            XCTFail("a wrong password was accepted")
        } catch let error as SyncError {
            XCTAssertTrue(error.localizedDescription.contains("Anmeldung abgelehnt"), error.localizedDescription)
        }
        // Creating needs SSH: for HTTP servers Zadur explains where to do it instead.
        do {
            try await Book.createRepository(at: "https://git.example.com/a/b.git")
            XCTFail("tried to create a repository over HTTPS")
        } catch let error as SyncError {
            guard case .cannotCreateRepository = error else { return XCTFail("\(error)") }
        }
    }
}
