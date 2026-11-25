import XCTest
@testable import ZadurCore

/// Two "Macs" (two copies of a book) syncing through a local test server (a bare repository).
final class SyncTests: TempDirTestCase {
    var server: URL { temp.appendingPathComponent("server.git") }

    func makeServer(_ url: URL? = nil) async throws -> URL {
        let target = url ?? server
        try await git(["init", "--quiet", "--bare", "--initial-branch=main", target.path], in: temp)
        return target
    }

    func edit(_ book: Book, _ id: String, _ body: String) throws {
        var scene = try book.readScene(id)
        scene.body = body
        try book.writeScene(scene)
    }

    /// Mac A: a book with two scenes in one chapter, connected to the server.
    func macA() async throws -> Book {
        let book = try await Book.create(at: temp.appendingPathComponent("A/Buch.crea"), title: "Buch", author: "Test")
        let first = book.manifest.sceneIDs[0]
        _ = try book.addScene(toChapter: book.manifest.chapters[0].id, after: first)
        try edit(book, book.manifest.sceneIDs[0], "Erster Absatz von eins.\n\nZweiter Absatz von eins.\n")
        try edit(book, book.manifest.sceneIDs[1], "Erster Absatz von zwei.\n")
        try await book.saveVersion()
        _ = try await makeServer()
        try await book.connect(to: server.path, device: "macA")
        return book
    }

    func macB() async throws -> Book {
        try await Book.clone(from: server.path, to: temp.appendingPathComponent("B/Buch.crea"))
    }

    func serverRefs() async throws -> [String] {
        try await Git(directory: server).run(["for-each-ref", "--format=%(refname)"]).string
            .split(separator: "\n").map(String.init)
    }

    // MARK: -

    func testConnectingSendsEverything() async throws {
        let book = try await Book.create(at: temp.appendingPathComponent("A/Buch.crea"), title: "Buch", author: "Test")
        let id = book.manifest.sceneIDs[0]
        try await book.startExperiment(named: "Andere Sicht", carryChanges: false)
        try edit(book, id, "Im Experiment.\n")
        try await book.saveVersion()
        try await book.switchTo("main")
        try await book.setMilestone(name: "Erste Fassung")
        try await book.git.addNote("Eine Notiz", to: await book.git.headCommit()!)
        try edit(book, id, "Noch nicht gesichert.\n")
        try await book.snapshot(device: "macA")

        _ = try await makeServer()
        let check = try await book.checkRemote(server.path)
        XCTAssertEqual(check, .empty)
        let result = try await book.connect(to: server.path, device: "macA")
        XCTAssertTrue(result.pushed)
        XCTAssertEqual(result.warnings, [])

        let refs = try await serverRefs()
        XCTAssertTrue(refs.contains("refs/heads/main"))
        XCTAssertTrue(refs.contains("refs/heads/experiments/Andere-Sicht"))
        XCTAssertTrue(refs.contains("refs/tags/milestone/Erste-Fassung"))
        XCTAssertTrue(refs.contains("refs/notes/commits"))
        XCTAssertTrue(refs.contains("refs/crea/snapshots/macA"))
        let url = await book.remoteURL()
        XCTAssertEqual(url, server.path)
    }

    func testSecondMacGetsTheBookAndChangesFlowBothWays() async throws {
        let a = try await macA()
        let b = try await macB()
        XCTAssertEqual(b.manifest, a.manifest)
        XCTAssertEqual(try b.readScene(b.manifest.sceneIDs[0]).body, try a.readScene(a.manifest.sceneIDs[0]).body)

        // B writes, A picks it up.
        try edit(b, b.manifest.sceneIDs[1], "Erster Absatz von zwei, auf Mac B weitergeschrieben.\n")
        try await b.saveVersion()
        let sent = try await b.sync(device: "macB")
        XCTAssertTrue(sent.pushed)

        let received = try await a.sync(device: "macA")
        XCTAssertEqual(received.pulledVersions, 1)
        XCTAssertFalse(received.needsMerge)
        XCTAssertTrue(try a.readScene(a.manifest.sceneIDs[1]).body.contains("Mac B"))
    }

    func testBothMacsWroteDifferentScenes() async throws {
        let a = try await macA()
        let b = try await macB()
        try edit(a, a.manifest.sceneIDs[0], "Erster Absatz von eins, auf Mac A geändert.\n\nZweiter Absatz von eins.\n")
        try await a.saveVersion()
        try await a.sync(device: "macA")

        try edit(b, b.manifest.sceneIDs[1], "Erster Absatz von zwei, auf Mac B geändert.\n")
        try await b.saveVersion()
        let result = try await b.sync(device: "macB")
        XCTAssertTrue(result.needsMerge)

        let merged = try await b.mergeWithServer()
        guard case .adopted = merged else { return XCTFail("\(merged)") }
        let head = try await b.git.log(limit: 1)[0]
        XCTAssertEqual(head.subject, "Mit dem Server zusammengeführt")
        XCTAssertEqual(head.parents.count, 2)
        let afterMerge = try await b.sync(device: "macB")
        XCTAssertTrue(afterMerge.pushed)

        try await a.sync(device: "macA")
        XCTAssertTrue(try a.readScene(a.manifest.sceneIDs[1]).body.contains("Mac B"))
        XCTAssertTrue(try b.readScene(b.manifest.sceneIDs[0]).body.contains("Mac A"))
    }

    func testBothMacsChangedTheSameParagraph() async throws {
        let a = try await macA()
        let b = try await macB()
        let id = a.manifest.sceneIDs[0]
        try edit(a, id, "Erster Absatz – Fassung A.\n\nZweiter Absatz von eins.\n")
        try await a.saveVersion()
        try await a.sync(device: "macA")
        try edit(b, id, "Erster Absatz – Fassung B.\n\nZweiter Absatz von eins.\n")
        try await b.saveVersion()
        _ = try await b.sync(device: "macB")

        let merged = try await b.mergeWithServer()
        guard case .conflicts(let conflicts) = merged else { return XCTFail("\(merged)") }
        let info = await b.adoptionInProgress()
        XCTAssertEqual(info?.fromServer, true)
        XCTAssertEqual(info?.name, "Server")
        guard case .text(let segments) = conflicts[0].kind else { return XCTFail() }
        XCTAssertTrue(segments.contains(.conflict(main: "Erster Absatz – Fassung B.\n", experiment: "Erster Absatz – Fassung A.\n")))
        try await b.resolve(conflicts[0].path, with: .main)
        try await b.finishAdoption()
        XCTAssertTrue(try b.readScene(id).body.hasPrefix("Erster Absatz – Fassung B."))
        let head = try await b.git.log(limit: 1)[0]
        XCTAssertEqual(head.subject, "Mit dem Server zusammengeführt")
    }

    func testExperimentsTravelAndShelvingFollows() async throws {
        let a = try await macA()
        let branch = try await a.startExperiment(named: "Umbau", carryChanges: false)
        try edit(a, a.manifest.sceneIDs[0], "Umgebaut.\n")
        try await a.saveVersion()
        try await a.switchTo("main")
        try await a.sync(device: "macA")

        let b = try await macB()
        let experimentsB = await b.experiments()
        XCTAssertEqual(experimentsB.map(\.branch), [branch])
        XCTAssertEqual(experimentsB.first?.name, "Umbau")

        try await a.shelve(branch)
        try await a.sync(device: "macA")
        let refs = try await serverRefs()
        XCTAssertTrue(refs.contains("refs/heads/shelved/Umbau"))
        XCTAssertFalse(refs.contains("refs/heads/experiments/Umbau"), "the old name is removed on the server")

        try await b.sync(device: "macB")
        let after = await b.experiments()
        XCTAssertEqual(after.map(\.branch), ["shelved/Umbau"])
    }

    func testSyncWithoutIntegratingNeverTouchesTheWorkingTree() async throws {
        let a = try await macA()
        let b = try await macB()
        try edit(b, b.manifest.sceneIDs[0], "Von Mac B.\n")
        try await b.saveVersion()
        try await b.sync(device: "macB")

        let before = try a.readScene(a.manifest.sceneIDs[0]).body
        try await a.setMilestone(name: "Nach dem Verbinden")
        let quiet = try await a.sync(device: "macA", integrate: false)
        XCTAssertTrue(quiet.serverHasNew)
        XCTAssertFalse(quiet.needsMerge)
        XCTAssertEqual(try a.readScene(a.manifest.sceneIDs[0]).body, before, "nothing pulled while the writer may be typing")
        let milestones = await a.milestones()
        XCTAssertEqual(milestones.map(\.name), ["Nach dem Verbinden"], "local milestones survive fetching")
        let refs = try await serverRefs()
        XCTAssertTrue(refs.contains("refs/tags/milestone/Nach-dem-Verbinden"))

        let full = try await a.sync(device: "macA")
        XCTAssertEqual(full.pulledVersions, 1)
        XCTAssertEqual(try a.readScene(a.manifest.sceneIDs[0]).body, "Von Mac B.\n")
    }

    func testServerWithAnotherProjectIsRefused() async throws {
        let a = try await macA()
        let other = try await Book.create(at: temp.appendingPathComponent("C/Anderes.crea"), title: "Anderes", author: "Test")
        let otherServer = try await makeServer(temp.appendingPathComponent("other.git"))
        try await other.connect(to: otherServer.path, device: "macC")

        let check = try await a.checkRemote(otherServer.path)
        XCTAssertEqual(check, .unrelated)
        do {
            try await a.connect(to: otherServer.path, device: "macA")
            XCTFail("expected an error")
        } catch SyncError.unrelatedServer {}
        let url = await a.remoteURL()
        XCTAssertEqual(url, server.path, "the existing server stays")
    }

    func testServerWithTheBooksHistoryFromBeforeZadur() async throws {
        // An existing repository (like a Gitea repo used before Zadur) is the server.
        let source = temp.appendingPathComponent("roman")
        try write("chapters:\n  - title: \"Eins\"\n    scenes:\n      - \"Anfang\"\n", to: "book.yaml", in: source)
        try write("Es war einmal.\n", to: "Szenen/Anfang.md", in: source)
        try await git(["init", "--quiet", "--initial-branch=main"], in: source)
        try await git(["add", "-A"], in: source)
        try await git(["commit", "--quiet", "-m", "Vor Zadur"], in: source)
        try await git(["clone", "--quiet", "--bare", source.path, server.path], in: temp)

        _ = try await Importer.importFolder(source, to: temp.appendingPathComponent("A/Roman.crea"))
        let book = try Book(url: temp.appendingPathComponent("A/Roman.crea"))
        let check = try await book.checkRemote(server.path)
        XCTAssertEqual(check, .sameBook(ahead: 1, behind: 0, isZadurBook: false))
        let result = try await book.connect(to: server.path, device: "macA")
        XCTAssertTrue(result.pushed)
        let serverMain = try await Git(directory: server).run(["rev-parse", "main"]).string.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = await book.git.headCommit()
        XCTAssertEqual(serverMain, head, "continued the existing history")
    }

    func testUnreachableServer() async throws {
        let book = try await Book.create(at: temp.appendingPathComponent("A/Buch.crea"), title: "Buch", author: "Test")
        do {
            try await book.connect(to: temp.appendingPathComponent("gibt-es-nicht.git").path, device: "macA")
            XCTFail("expected an error")
        } catch let error as SyncError {
            // No repository at that address (Zadur can offer to create one on SSH servers).
            XCTAssertEqual(error, .noRepository)
        }
        let url = await book.remoteURL()
        XCTAssertNil(url)
    }

    func testCloningSomethingThatIsNoBook() async throws {
        let plain = temp.appendingPathComponent("plain")
        try write("Hallo\n", to: "README.md", in: plain)
        try await git(["init", "--quiet", "--initial-branch=main"], in: plain)
        try await git(["add", "-A"], in: plain)
        try await git(["commit", "--quiet", "-m", "x"], in: plain)
        do {
            _ = try await Book.clone(from: plain.path, to: temp.appendingPathComponent("B/X.crea"))
            XCTFail("expected an error")
        } catch SyncError.notAZadurBook {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.appendingPathComponent("B/X.crea").path))
    }

    func testPortInShortAddressIsRecognised() {
        XCTAssertEqual(ServerAddress.suggestionForPortInShortForm("git@git.example.com:2222/autorin/buch.git"),
                       "ssh://git@git.example.com:2222/autorin/buch.git")
        XCTAssertEqual(ServerAddress.suggestionForPortInShortForm("git.example.com:2200/a/b.git"), "ssh://git.example.com:2200/a/b.git")
        XCTAssertNil(ServerAddress.suggestionForPortInShortForm("git@git.example.com:autorin/buch.git"))
        XCTAssertNil(ServerAddress.suggestionForPortInShortForm("ssh://git@git.example.com:2222/autorin/buch.git"))
        XCTAssertNil(ServerAddress.suggestionForPortInShortForm("https://example.org/a/b.git"))
    }

    func testFriendlyErrorMessages() {
        XCTAssertTrue(SyncError.explain("ssh: Could not resolve hostname git.example.com: nodename nor servname provided").contains("Servername"))
        XCTAssertTrue(SyncError.explain("Host key verification failed.\nfatal: Could not read from remote repository.").contains("unbekannt"))
        XCTAssertTrue(SyncError.explain("git@host: Permission denied (publickey).").contains("Anmeldung"))
    }
}
