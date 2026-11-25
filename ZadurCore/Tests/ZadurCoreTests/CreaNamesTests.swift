import Foundation
import XCTest
@testable import ZadurCore

/// The Crea names (spec §9.3, §9.6, Appendix B): what Zadur writes now, and what Stet 1.0 wrote,
/// which is still read.
final class CreaNamesTests: TempDirTestCase {
    private func makeBook() async throws -> Book {
        try await Book.create(at: temp.appendingPathComponent("Crea.crea"), title: "Crea", author: "Test")
    }

    private func commit(_ book: Book, _ message: String) async throws {
        try await book.git.run(["-c", "user.name=Test", "-c", "user.email=t@example.com", "commit", "--allow-empty", "-F", "-"],
                               input: Data(message.utf8))
    }

    func testTrailersOfBothNames() async throws {
        let book = try await makeBook()
        let first = try await book.git.log(limit: 1)[0]
        XCTAssertTrue(first.body.contains("Crea-Words: 0"))
        XCTAssertEqual(first.trailers["Words"], "0")

        try await commit(book, "Aus Stet 1.0\n\nStet-Words: 7\nStet-Words-Delta: +2\nStet-Active-Minutes: 3\n")
        let old = try await book.git.log(limit: 1)[0]
        XCTAssertEqual(old.trailers, ["Words": "7", "Words-Delta": "+2", "Active-Minutes": "3"])

        try await commit(book, "Beides\n\nStet-Words: 1\nCrea-Words: 2\nStet-Words: 3\n")
        let both = try await book.git.log(limit: 1)[0]
        XCTAssertEqual(both.trailers["Words"], "2", "the Crea name wins")
    }

    /// A Crea book from another program, without history, inside a folder that is a repository
    /// itself: Zadur never touches the outer repository and starts the book's own history.
    func testBookWithoutHistoryGetsItsOwnInsideAnotherRepository() async throws {
        let outer = temp.appendingPathComponent("Schreiben")
        let book = outer.appendingPathComponent("Fremd.crea")
        try FileManager.default.createDirectory(at: book.appendingPathComponent("scenes"), withIntermediateDirectories: true)
        let outerGit = Git(directory: outer)
        try await outerGit.initRepository()
        try Data("Notizen\n".utf8).write(to: outer.appendingPathComponent("notizen.txt"))
        _ = try await outerGit.commitAll(message: "Mein Schreibordner", identity: ["-c", "user.name=T", "-c", "user.email=t@example.com"])
        let outerHead = await outerGit.headCommit()
        try Data("format: 1\ntitle: \"Fremd\"\nauthors: []\nlanguage: de\nstructure:\n- chapter: \"Eins\"\n  id: ca1b2c3\n  scenes: [s1a2b3]\n".utf8)
            .write(to: book.appendingPathComponent("manuscript.yaml"))
        try Data("Ein Satz aus einem anderen Programm.\n".utf8).write(to: book.appendingPathComponent("scenes/s1a2b3.md"))

        let opened = try Book(url: book)
        let before = await opened.git.headCommit()
        XCTAssertNil(before, "not the outer repository's version")
        let started = try await opened.startHistoryIfNeeded()
        XCTAssertTrue(started)
        let first = try await opened.git.log(limit: 1)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?.trailers["Words"], "6")
        XCTAssertTrue(try String(contentsOf: book.appendingPathComponent(".gitignore"), encoding: .utf8).contains(".local/"))
        let outerAfter = await outerGit.headCommit()
        XCTAssertEqual(outerAfter, outerHead, "the outer repository is untouched")
        let again = try await opened.startHistoryIfNeeded()
        XCTAssertFalse(again)
    }

    func testSnapshotsMoveToTheCreaRef() async throws {
        let book = try await makeBook()
        let headCommit = await book.git.headCommit()
        let head = try XCTUnwrap(headCommit)
        try await book.git.run(["update-ref", "refs/stet/snapshots/macX", head])
        await book.adoptCreaNames()
        let moved = await book.git.resolve("refs/crea/snapshots/macX")
        let old = await book.git.resolve("refs/stet/snapshots/macX")
        XCTAssertEqual(moved, head)
        XCTAssertNil(old)

        var scene = try book.readScene(book.manifest.sceneIDs[0])
        scene.body = "Noch nicht gesichert.\n"
        try book.writeScene(scene)
        let snapshot = try await book.snapshot(device: "macY")
        let ref = await book.git.resolve("refs/crea/snapshots/macY")
        XCTAssertEqual(ref, snapshot)
        let made = try await book.git.log("refs/crea/snapshots/macY", limit: 1)[0]
        XCTAssertEqual(made.trailers["Snapshot"], "macY")
        let history = try await book.history(ofScene: book.manifest.sceneIDs[0], device: "macY")
        XCTAssertEqual(history.first?.isSnapshot, true)
    }
}
