import Foundation
import XCTest
@testable import ZadurCore

/// "Sichern unter …": the whole book in another place; the original stays as it is.
final class BookCopyTests: TempDirTestCase {
    /// History, an experiment, a milestone, a note, feedback, a snapshot, unsaved text and per-device state.
    private func makeBook(_ name: String = "Der Leuchtturm.crea") async throws -> Book {
        let book = try await Book.create(at: temp.appendingPathComponent("Bücher/\(name)"), title: "Der Leuchtturm", author: "Test")
        var scene = try book.readScene(book.manifest.sceneIDs[0])
        scene.body = "Der Wind kam von Westen.\n"
        try book.writeScene(scene)
        try await book.saveVersion()
        try await book.startExperiment(named: "Andere Sicht", carryChanges: false)
        try await book.switchTo("main")
        try await book.setMilestone(name: "Erste Fassung")
        try book.addFeedback(from: "Gisela", refersTo: nil, text: "Schön.")
        if let head = await book.git.headCommit() { try await book.git.addNote("Erste Notiz", to: head) }
        scene.body = "Der Wind kam von Westen. Noch nicht gesichert.\n"
        try book.writeScene(scene)
        _ = try await book.snapshot(device: "a")
        try write("{\"lastSceneID\":\"x\"}", to: ".local/zadur-state.json", in: book.url)
        return book
    }

    private func refs(_ folder: URL) async throws -> String {
        try await git(["for-each-ref", "--format=%(refname) %(objectname)"], in: folder)
    }

    private func text(_ book: Book) throws -> String {
        try book.readScene(book.manifest.sceneIDs[0]).body
    }

    func testTheCopyHasEverythingAndTheOriginalStays() async throws {
        let book = try await makeBook()
        let refsBefore = try await refs(book.url)
        let destination = temp.appendingPathComponent("Woanders/Leuchtturm, zweiter Ort.crea")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let made = try await book.copy(to: destination, keepServer: true)
        XCTAssertEqual(made, destination)
        let copy = try Book(url: destination)
        let refsCopy = try await refs(destination)
        XCTAssertEqual(refsCopy, refsBefore, "every version, experiment, milestone, note and snapshot")
        XCTAssertTrue(refsCopy.contains("refs/notes/commits") && refsCopy.contains("refs/crea/snapshots/a") && refsCopy.contains("refs/tags/"))
        XCTAssertEqual(try text(copy), "Der Wind kam von Westen. Noch nicht gesichert.\n", "unsaved text too")
        XCTAssertEqual(copy.feedbackEntries().map(\.from), ["Gisela"])
        XCTAssertEqual(try read(".local/zadur-state.json", in: destination), "{\"lastSceneID\":\"x\"}", "this Mac's state for the book")
        let problem = await copy.git.integrityProblem()
        XCTAssertNil(problem)
        let status = try await git(["status", "--porcelain"], in: destination)
        let statusOriginal = try await git(["status", "--porcelain"], in: book.url)
        XCTAssertEqual(status, statusOriginal, "the same unsaved changes, nothing else")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path),
                       [destination.lastPathComponent], "no half copy left next to it")

        // Writing on in the copy leaves the original alone.
        var scene = try copy.readScene(copy.manifest.sceneIDs[0])
        scene.body = "Nur in der Kopie.\n"
        try copy.writeScene(scene)
        try await copy.saveVersion()
        let refsAfter = try await refs(book.url)
        XCTAssertEqual(refsAfter, refsBefore)
        XCTAssertEqual(try text(book), "Der Wind kam von Westen. Noch nicht gesichert.\n")
    }

    func testTheServerStaysOrIsForgotten() async throws {
        let book = try await makeBook()
        try await git(["remote", "add", "origin", temp.appendingPathComponent("server.git").path], in: book.url)
        try await git(["config", "stet.sshKey", "/Schluessel/buch"], in: book.url)
        let server = await book.remoteURL()

        let kept = try await book.copy(to: temp.appendingPathComponent("Verbunden.crea"), keepServer: true)
        let keptServer = await (try Book(url: kept)).remoteURL()
        XCTAssertEqual(keptServer, server)
        let keptKey = try await git(["config", "--get", "stet.sshKey"], in: kept)
        XCTAssertEqual(keptKey, "/Schluessel/buch\n")

        let alone = try await book.copy(to: temp.appendingPathComponent("Unabhängig.crea"), keepServer: false)
        let aloneServer = await (try Book(url: alone)).remoteURL()
        XCTAssertNil(aloneServer)
        let key = try await Git(directory: alone).run(["config", "--get", "stet.sshKey"], allowedStatus: [0, 1])
        XCTAssertEqual(key.status, 1, "the key is forgotten, not deleted")

        let originalServer = await book.remoteURL()
        XCTAssertEqual(originalServer, server, "the original keeps its server")
        let originalKey = try await git(["config", "--get", "stet.sshKey"], in: book.url)
        XCTAssertEqual(originalKey, "/Schluessel/buch\n")
    }

    func testNoCopyOverAnotherBookOrIntoItself() async throws {
        let book = try await makeBook()
        let other = try await Book.create(at: temp.appendingPathComponent("Anderes.crea"), title: "Anderes", author: "Test")
        let otherHead = await other.git.headCommit()

        for (destination, expected) in [
            (other.url, BookError.alreadyExists(other.url) as Error),
            (book.url, BookError.alreadyExists(book.url) as Error),
            (book.url.appendingPathComponent("scenes/Kopie.crea"), CopyError.insideItself as Error),
        ] {
            do {
                try await book.copy(to: destination, keepServer: true)
                XCTFail("copied to \(destination.lastPathComponent)")
            } catch {
                XCTAssertEqual(error.localizedDescription, expected.localizedDescription)
            }
        }
        let otherHeadAfter = await other.git.headCommit()
        XCTAssertEqual(otherHeadAfter, otherHead, "the other book is untouched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: book.url.appendingPathComponent("scenes/Kopie.crea").path))
    }

    func testAnOldBookIsCopiedUnderTheNewExtension() async throws {
        let book = try await makeBook("Alter Name.stet")
        let copy = try await book.copy(to: temp.appendingPathComponent("Neuer Name.crea"), keepServer: true)
        let head = await book.git.headCommit()
        let copyHead = await (try Book(url: copy)).git.headCommit()
        XCTAssertEqual(copyHead, head)
    }

    func testItWaitsForGitToFinish() async throws {
        let book = try await makeBook()
        Book.lockChecks = 3
        defer { Book.lockChecks = 50 }
        try write("", to: ".git/index.lock", in: book.url)
        let destination = temp.appendingPathComponent("Kopie.crea")
        do {
            try await book.copy(to: destination, keepServer: true)
            XCTFail("copied while git was writing")
        } catch {
            XCTAssertEqual(error as? CopyError, .busy)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try FileManager.default.removeItem(at: book.url.appendingPathComponent(".git/index.lock"))
        try await book.copy(to: destination, keepServer: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("manuscript.yaml").path))
    }
}
