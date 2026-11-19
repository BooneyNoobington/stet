import XCTest
@testable import StetCore

final class ManifestTests: XCTestCase {
    func testRoundTripPreservesStructureAndUnknownKeys() throws {
        let yaml = """
        format: 1
        title: Der Leuchtturm
        authors:
        - Jane Doe
        language: de
        year: 2026
        cover: assets/cover.jpg
        structure:
        - chapter: Ankunft
          id: c1
          scenes:
          - s1
          - s2
        - part: Zweiter Teil
          id: p1
          chapters:
          - chapter: Die Flut
            id: c2
            scenes:
            - s3
        futureSetting: keep me

        """
        let manifest = try Manifest.parse(yaml)
        XCTAssertEqual(manifest.title, "Der Leuchtturm")
        XCTAssertEqual(manifest.sceneIDs, ["s1", "s2", "s3"])
        XCTAssertEqual(manifest.chapters.map(\.title), ["Ankunft", "Die Flut"])
        XCTAssertEqual(manifest.yaml(), yaml)
    }

    func testUmlautsAreWrittenAsIs() {
        let manifest = Manifest(title: "Schnee im Mai", authors: ["Jürgen Größe"], language: "de-DE")
        XCTAssertTrue(manifest.yaml().contains("Jürgen Größe"))
    }

    func testMovingScenesAndChapters() throws {
        var manifest = Manifest(title: "T", authors: [], language: "de", structure: [
            .chapter(Chapter(id: "c1", title: "Eins", sceneIDs: ["a", "b"])),
            .chapter(Chapter(id: "c2", title: "Zwei", sceneIDs: ["c"])),
        ])
        manifest.moveScene("a", toChapter: "c2", at: 1)
        XCTAssertEqual(manifest.chapter(withID: "c1")?.sceneIDs, ["b"])
        XCTAssertEqual(manifest.chapter(withID: "c2")?.sceneIDs, ["c", "a"])

        manifest.moveStructureNode(containingChapter: "c2", by: -1)
        XCTAssertEqual(manifest.chapters.map(\.id), ["c2", "c1"])

        manifest.removeChapter("c1")
        XCTAssertEqual(manifest.chapters.map(\.id), ["c2"])
        XCTAssertEqual(manifest.sceneIDs, ["c", "a", "b"], "scenes of a removed chapter move to its neighbour")
    }
}

final class SceneFileTests: XCTestCase {
    func testUntouchedSceneIsByteIdentical() {
        let text = "---\ntitle:   Der Antrag   # odd spacing\nstatus: draft\n---\n„Hallo“, sagte sie.\n\n***\n\nEnde"
        let scene = SceneFile.parse(id: "x", text: text)
        XCTAssertEqual(scene.title, "Der Antrag")
        XCTAssertEqual(scene.status, .draft)
        XCTAssertEqual(scene.body, "„Hallo“, sagte sie.\n\n***\n\nEnde")
        XCTAssertEqual(scene.serialized(), text)
    }

    func testChangingMetadataKeepsBodyAndOtherKeys() {
        let text = "---\ntitle: Alt\nfacts:\n  Ort: Hafen\n---\nText"
        var scene = SceneFile.parse(id: "x", text: text)
        scene.title = "Neu"
        scene.synopsis = "Mara kommt an."
        XCTAssertEqual(scene.serialized(), "---\ntitle: Neu\nfacts:\n  Ort: Hafen\nsynopsis: Mara kommt an.\n---\nText")
        XCTAssertEqual(scene.facts.first?.value, "Hafen")
    }

    func testFileWithoutFrontMatter() {
        let text = "---\n\nEin Absatz nach einer Linie.\n\n---\n\nNoch einer."
        let scene = SceneFile.parse(id: "x", text: text)
        XCTAssertNil(scene.title)
        XCTAssertEqual(scene.body, text, "prose between rules must not be mistaken for front matter")
        XCTAssertEqual(scene.serialized(), text)
    }

    func testDisplayTitleFallsBackToOpeningWords() {
        let scene = SceneFile(id: "x", body: "{>>Notiz<<}Der Wind kam von Westen, als Mara Kessler den Anleger betrat.")
        XCTAssertEqual(scene.displayTitle, "Der Wind kam von Westen als Mara…")
    }
}

final class TextStatsTests: XCTestCase {
    func testCommentsDoNotCount() {
        XCTAssertEqual(TextStats.words(in: "Sie {==ging==}{>>zu schnell?<<} nach Hause. {>>TODO: prüfen<<}"), 4)
    }
}

final class WordDiffTests: XCTestCase {
    func testWordLevelChanges() {
        let segments = WordDiff.diff(old: "Der Wind kam von Westen.", new: "Der kalte Wind kam von Osten.")
        let rendered = segments.map { s -> String in
            switch s.kind {
            case .same: s.text
            case .inserted: "[+\(s.text)]"
            case .removed: "[-\(s.text)]"
            }
        }.joined()
        XCTAssertEqual(rendered, "Der [+kalte ]Wind kam von [-Westen][+Osten].")
        let summary = WordDiff.summary(of: segments)
        XCTAssertEqual(summary.insertedWords, 2)
        XCTAssertEqual(summary.removedWords, 1)
    }

    func testIdenticalTexts() {
        XCTAssertEqual(WordDiff.diff(old: "Gleich.", new: "Gleich."), [.init(.same, "Gleich.")])
    }
}

final class HealthCheckNameTests: XCTestCase {
    func testConflictNames() {
        let exists: (String) -> Bool = { $0 == "abc.md" || $0 == "HEAD" }
        XCTAssertTrue(HealthCheck.isConflictName("abc (conflicted copy 2026-11-19 104512).md", siblingExists: exists))
        XCTAssertTrue(HealthCheck.isConflictName("abc.sync-conflict-20261119-104512-ABC.md", siblingExists: exists))
        XCTAssertTrue(HealthCheck.isConflictName("abc 2.md", siblingExists: exists))
        XCTAssertTrue(HealthCheck.isConflictName("HEAD 2", siblingExists: exists))
        XCTAssertFalse(HealthCheck.isConflictName("Kapitel 2.md", siblingExists: exists))
        XCTAssertFalse(HealthCheck.isConflictName("abc.md", siblingExists: exists))
    }
}
