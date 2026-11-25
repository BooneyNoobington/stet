import XCTest
@testable import ZadurCore

/// Throwaway keys in a temporary folder; nothing is registered anywhere.
final class KeyTests: TempDirTestCase {
    var savedFolder: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedFolder = SSHKey.folder
        SSHKey.folder = temp.appendingPathComponent("Keys")
    }

    override func tearDownWithError() throws {
        SSHKey.folder = savedFolder
        try super.tearDownWithError()
    }

    func testCreateUseAndRemoveABookKey() async throws {
        let book = try await Book.create(at: temp.appendingPathComponent("Schlüssel.crea"), title: "Schnee im September", author: "Test")
        let none = await book.zadurKey()
        XCTAssertNil(none)

        let key = try await book.createZadurKey()
        XCTAssertTrue(key.publicKey.hasPrefix("ssh-ed25519 "))
        XCTAssertTrue(key.publicKey.contains("Zadur – Schnee im September"))
        XCTAssertTrue(key.fingerprint.hasPrefix("SHA256:"))
        XCTAssertTrue(key.privateKeyURL.lastPathComponent.hasPrefix("Schnee-im-September-"))

        // Only the user can read it, and it lives outside the book.
        let mode = try FileManager.default.attributesOfItem(atPath: key.privateKeyURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        let folderMode = try FileManager.default.attributesOfItem(atPath: SSHKey.folder.path)[.posixPermissions] as? Int
        XCTAssertEqual(folderMode, 0o700)
        XCTAssertFalse(key.privateKeyURL.path.hasPrefix(book.url.path))
        let changed = try await book.git.changedPaths()
        XCTAssertTrue(changed.isEmpty, "nothing in the book changes")

        // Used only for this book, bypassing the SSH agent; the network commands add their safety options.
        let loaded = await book.zadurKey()
        XCTAssertEqual(loaded, key)
        let environment = await book.networkEnvironment()
        let command = try XCTUnwrap(environment["GIT_SSH_COMMAND"])
        XCTAssertTrue(command.contains("-i '\(key.privateKeyURL.path)'"))
        XCTAssertTrue(command.contains("IdentitiesOnly=yes"))
        XCTAssertTrue(command.contains("IdentityAgent=none"))
        XCTAssertTrue(command.contains("BatchMode=yes"))

        try await book.removeZadurKey()
        let gone = await book.zadurKey()
        XCTAssertNil(gone)
        XCTAssertFalse(FileManager.default.fileExists(atPath: key.privateKeyURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: key.publicKeyURL.path))
        let after = await book.networkEnvironment()
        XCTAssertFalse(after["GIT_SSH_COMMAND"]?.contains("-i ") ?? true)
    }

    func testCloneWithAKeyKeepsUsingIt() async throws {
        let original = try await Book.create(at: temp.appendingPathComponent("A/Buch.crea"), title: "Buch", author: "Test")
        let server = temp.appendingPathComponent("server.git")
        try await git(["init", "--quiet", "--bare", "--initial-branch=main", server.path], in: temp)
        try await original.connect(to: server.path, device: "macA")

        let key = try SSHKey.create(label: "Buch")
        let copy = try await Book.clone(from: server.path, to: temp.appendingPathComponent("B/Buch.crea"), key: key)
        let used = await copy.zadurKey()
        XCTAssertEqual(used, key)
    }
}
