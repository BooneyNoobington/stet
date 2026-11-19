import XCTest
@testable import StetCore

/// The importer against a project shaped like a typical "scenes + book.yaml + Pandoc" setup.
/// All texts here are made up for the tests.
final class ImporterTests: TempDirTestCase {
    var source: URL { temp.appendingPathComponent("roman") }
    var destination: URL { temp.appendingPathComponent("Roman.stet") }

    let bookYAML = """
    book:
      filename: "Roman"
      source: "Szenen"
      css: "epub.css"
      cover: "cover.jpg"
    metadata:
      title: "Ein Roman"
      author:
        - "Erika Muster"
      lang: "de-DE"
    chapters:
      - title: "Prolog"
        scenes:
          - "Ankunft"
          - "Übergabe"
      - title: "Erstes Kapitel"
        scenes:
          - "Der Turm"

    """

    func makeSourceRepository() async throws {
        try write(bookYAML, to: "book.yaml", in: source)
        try write("Der Wind kam von Westen.\n", to: "Szenen/Ankunft.md", in: source)
        // Decomposed umlaut in the file name, as macOS sometimes produces.
        try write("Sie übergab den Brief.\n", to: "Szenen/U\u{0308}bergabe.md", in: source)
        try write("Der Turm war dunkel.", to: "Szenen/Der Turm.md", in: source)
        try write("Ein Entwurf ohne Kapitel.\n", to: "Szenen/Entwurf.md", in: source)
        try write("body { }", to: "epub.css", in: source)
        try write("JPEG", to: "cover.jpg", in: source)
        try write("# Nützliches\n\nNamen.", to: "Nützliches.md", in: source)
        try write("# Readme", to: "README.md", in: source)
        try write("print('build')", to: "build_book.py", in: source)
        try write("ZIP", to: "Szenen.zip", in: source)

        try await git(["init", "--quiet", "--initial-branch=main"], in: source)
        try await git(["add", "-A"], in: source)
        try await git(["commit", "--quiet", "-m", "Erste Fassung"], in: source)
        try write("Der Wind kam von Westen. Er roch nach Tang.\n", to: "Szenen/Ankunft.md", in: source)
        try await git(["commit", "--quiet", "-am", "Ankunft erweitert"], in: source)
        // An experiment branch
        try await git(["branch", "albtraum"], in: source)
    }

    func testImportKeepsHistoryAndConvertsLayout() async throws {
        try await makeSourceRepository()
        let sourceHead = try await git(["rev-parse", "HEAD"], in: source)

        let report = try await Importer.importFolder(source, to: destination)

        XCTAssertEqual(report.title, "Ein Roman")
        XCTAssertEqual(report.chapters, 3, "Prolog, Erstes Kapitel, Nicht zugeordnet")
        XCTAssertEqual(report.scenes, 4)
        XCTAssertEqual(report.commitsKept, 2)
        XCTAssertEqual(report.experiments, [], "albtraum has nothing of its own")
        XCTAssertEqual(report.shelvedExperiments, ["albtraum"])
        XCTAssertEqual(Set(report.removed), ["book.yaml", "build_book.py", "README.md"])

        let book = try Book(url: destination)
        XCTAssertEqual(book.manifest.authors, ["Erika Muster"])
        XCTAssertEqual(book.manifest.language, "de-DE")
        XCTAssertEqual(book.manifest.cover, "assets/cover.jpg")
        XCTAssertEqual(book.manifest.epubCSS, "assets/epub.css")
        XCTAssertEqual(book.manifest.chapters.map(\.title), ["Prolog", "Erstes Kapitel", "Nicht zugeordnet"])

        // Scene bodies are byte-identical to the originals, titles come from book.yaml.
        let prolog = book.manifest.chapters[0].sceneIDs
        let first = try book.readScene(prolog[0])
        XCTAssertEqual(first.title, "Ankunft")
        XCTAssertEqual(first.body, "Der Wind kam von Westen. Er roch nach Tang.\n")
        XCTAssertEqual(try book.readScene(prolog[1]).title, "Übergabe")
        XCTAssertEqual(try book.readScene(book.manifest.chapters[1].sceneIDs[0]).body, "Der Turm war dunkel.")

        // Other files
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("wiki/Nützliches.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("imported/Szenen.zip").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Szenen").path))

        // History: two original commits plus the conversion; nothing uncommitted; no remote.
        let log = try await book.git.log()
        XCTAssertEqual(log.map(\.subject), ["Nach Stet übernommen", "Ankunft erweitert", "Erste Fassung"])
        XCTAssertEqual(log[0].trailers["Stet-Words"], String(report.words))
        let changed = try await book.git.changedPaths()
        XCTAssertTrue(changed.isEmpty)
        let remotes = try await book.git.run(["remote"]).string
        XCTAssertEqual(remotes, "")
        let experiment = await book.git.resolve("refs/heads/shelved/albtraum")
        XCTAssertNotNil(experiment)

        // The scene's history follows the rename back into the original repository.
        let history = try await book.history(ofScene: prolog[0])
        XCTAssertEqual(history.map(\.commit.subject), ["Nach Stet übernommen", "Ankunft erweitert", "Erste Fassung"])
        XCTAssertEqual(history.last?.path, "Szenen/Ankunft.md")
        let oldest = await book.text(of: history.last!)
        XCTAssertEqual(oldest, "Der Wind kam von Westen.\n")

        // The source is untouched.
        let headAfter = try await git(["rev-parse", "HEAD"], in: source)
        XCTAssertEqual(headAfter, sourceHead)
        let sourceStatus = try await git(["status", "--porcelain"], in: source)
        XCTAssertEqual(sourceStatus, "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("book.yaml").path))
    }

    func testBranchWithOwnWorkBecomesAnAdoptableExperiment() async throws {
        try await makeSourceRepository()
        try await git(["switch", "--quiet", "-c", "umbau"], in: source)
        try write("Der Wind kam von Westen. Er roch nach Tang und Teer.\n", to: "Szenen/Ankunft.md", in: source)
        try write("Eine Szene, die es nur im Umbau gibt.\n", to: "Szenen/Neu.md", in: source)
        try write(bookYAML.replacingOccurrences(of: "      - \"Übergabe\"\n", with: "      - \"Übergabe\"\n      - \"Neu\"\n"), to: "book.yaml", in: source)
        try await git(["add", "-A"], in: source)
        try await git(["commit", "--quiet", "-m", "Umbau"], in: source)
        try await git(["switch", "--quiet", "main"], in: source)

        let report = try await Importer.importFolder(source, to: destination)
        XCTAssertEqual(report.experiments, ["umbau"])
        XCTAssertEqual(report.shelvedExperiments, ["albtraum"])

        let book = try Book(url: destination)
        let current = await book.currentBranch()
        XCTAssertEqual(current, "main")
        let ankunft = book.manifest.chapters[0].sceneIDs[0]
        let experiments = await book.experiments()
        let umbau = try XCTUnwrap(experiments.first { $0.branch == "experiments/umbau" })
        XCTAssertTrue(umbau.isStetBook, "converted to the Stet layout")

        // Same scene IDs as the main version, so the experiment opens and adopts cleanly.
        try await book.switchTo(umbau.branch)
        XCTAssertEqual(book.manifest.chapters[0].sceneIDs.first, ankunft)
        XCTAssertTrue(try book.readScene(ankunft).body.contains("Teer"))
        try await book.switchTo("main")

        let result = try await book.adopt(umbau.branch)
        guard case .adopted = result else { return XCTFail("\(result)") }
        XCTAssertTrue(try book.readScene(ankunft).body.contains("Teer"))
        let titles = try book.manifest.chapters.map { try $0.sceneIDs.map { try book.readScene($0).title ?? "?" } }
        XCTAssertEqual(titles.first, ["Ankunft", "Übergabe", "Neu"])
    }

    func testUncommittedChangesAreCarriedOver() async throws {
        try await makeSourceRepository()
        try write("Neuer, noch nicht gesicherter Text.\n", to: "Szenen/Der Turm.md", in: source)

        let report = try await Importer.importFolder(source, to: destination)
        XCTAssertFalse(report.warnings.isEmpty)
        let book = try Book(url: destination)
        XCTAssertEqual(try book.readScene(book.manifest.chapters[1].sceneIDs[0]).body, "Neuer, noch nicht gesicherter Text.\n")
    }

    func testPlainFolderWithoutGitOrConfig() async throws {
        try write("Erste Szene.", to: "a.md", in: source)
        try write("Zweite Szene.", to: "b.md", in: source)
        try write("# Über dieses Projekt", to: "README.md", in: source)

        let report = try await Importer.importFolder(source, to: destination)
        XCTAssertEqual(report.scenes, 2)
        XCTAssertEqual(report.commitsKept, 0)
        let book = try Book(url: destination)
        XCTAssertEqual(book.manifest.title, "roman")
        XCTAssertEqual(book.manifest.chapters.map(\.title), ["Kapitel 1"])
        XCTAssertEqual(try book.readScene(book.manifest.sceneIDs[0]).title, "a")
        let log = try await book.git.log()
        XCTAssertEqual(log.count, 1)
    }

    func testRefusesExistingDestination() async throws {
        try write("x", to: "a.md", in: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            _ = try await Importer.importFolder(source, to: destination)
            XCTFail("expected an error")
        } catch Importer.ImportError.destinationExists {}
    }
}

final class SyncLocationTests: TempDirTestCase {
    func testDetectsMarkersAndCloudStorage() throws {
        let home = temp!
        try write("", to: "Nextcloud/.sync_abc123.db", in: home)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Nextcloud/Bücher/Roman.stet"), withIntermediateDirectories: true)
        XCTAssertEqual(SyncLocation.detect(home.appendingPathComponent("Nextcloud/Bücher/Roman.stet"), home: home)?.service, "Nextcloud")

        let dropbox = home.appendingPathComponent("Library/CloudStorage/Dropbox/Roman.stet")
        XCTAssertEqual(SyncLocation.detect(dropbox, home: home)?.service, "Dropbox")
        let drive = home.appendingPathComponent("Library/CloudStorage/GoogleDrive-someone/Roman.stet")
        XCTAssertEqual(SyncLocation.detect(drive, home: home)?.service, "Google Drive")

        try FileManager.default.createDirectory(at: home.appendingPathComponent("Books/Roman.stet"), withIntermediateDirectories: true)
        XCTAssertNil(SyncLocation.detect(home.appendingPathComponent("Books/Roman.stet"), home: home))
    }

    func testReadsNextcloudConfig() throws {
        let home = temp!
        try write("[Accounts]\n0\\Folders\\1\\localPath=\(home.path)/Wolke/\n", to: "Library/Preferences/Nextcloud/nextcloud.cfg", in: home)
        XCTAssertEqual(SyncLocation.detect(home.appendingPathComponent("Wolke/Roman.stet"), home: home)?.service, "Nextcloud")
    }
}
