import XCTest
@testable import ZadurCore

final class ExperimentTests: TempDirTestCase {
    /// A book with two chapters: c1 = [a, b], c2 = [c]. Scenes have two paragraphs each.
    func makeBook() async throws -> Book {
        let book = try await Book.create(at: temp.appendingPathComponent("Exp.crea"), title: "Exp", author: "Test")
        let a = book.manifest.sceneIDs[0]
        let b = try book.addScene(toChapter: book.manifest.chapters[0].id, after: a).id
        let chapter2 = try book.addChapter(title: "Zwei", after: book.manifest.chapters[0].id)
        let c = chapter2.sceneIDs[0]
        let first = book.manifest.chapters[0].id
        try book.updateManifest { $0.updateChapter(first) { $0.title = "Eins" } }
        for (id, name) in [(a, "A"), (b, "B"), (c, "C")] {
            try edit(book, id, "Erster Absatz von \(name).\n\nZweiter Absatz von \(name).\n", title: name)
        }
        try await book.saveVersion()
        return book
    }

    func edit(_ book: Book, _ id: String, _ body: String, title: String? = nil) throws {
        var scene = (try? book.readScene(id)) ?? SceneFile(id: id)
        if let title { scene.title = title }
        scene.body = body
        try book.writeScene(scene)
    }

    func body(_ book: Book, _ id: String) throws -> String { try book.readScene(id).body }

    func ids(_ book: Book) -> (a: String, b: String, c: String) {
        let s = book.manifest.sceneIDs
        return (s[0], s[1], s[2])
    }

    // MARK: Basics

    func testSlug() {
        XCTAssertEqual(Book.slug("Kapitel 3 aus Maras Sicht"), "Kapitel-3-aus-Maras-Sicht")
        XCTAssertEqual(Book.slug("  Über/Tage: ein Test?  "), "ÜberTage-ein-Test")
        XCTAssertEqual(Book.slug("..."), "experiment")
    }

    func testStartSwitchShelve() async throws {
        let book = try await makeBook()
        let (a, _, _) = ids(book)
        let mainText = try body(book, a)

        // Unsaved changes move into the experiment.
        try edit(book, a, "Maras Sicht.\n")
        let branch = try await book.startExperiment(named: "Maras Sicht", carryChanges: true)
        XCTAssertEqual(branch, "experiments/Maras-Sicht")
        let current = await book.currentBranch()
        XCTAssertEqual(current, branch)
        try await book.saveVersion()

        try await book.switchTo("main")
        XCTAssertEqual(try body(book, a), mainText, "the main version is untouched")

        var experiments = await book.experiments()
        XCTAssertEqual(experiments.map(\.name), ["Maras Sicht"])
        XCTAssertEqual(experiments.first?.ahead, 1)
        XCTAssertFalse(experiments[0].isAdopted)

        try await book.shelve(branch)
        experiments = await book.experiments()
        XCTAssertEqual(experiments.first?.branch, "shelved/Maras-Sicht")
        XCTAssertEqual(experiments.first?.name, "Maras Sicht", "the name survives shelving")
        try await book.unshelve("shelved/Maras-Sicht")
        let back = await book.experiments()
        XCTAssertEqual(back.first?.branch, branch)

        // Without carrying, unsaved changes are saved in the main version first.
        try edit(book, a, "Gesichert in der Hauptfassung.\n")
        try await book.startExperiment(named: "Maras Sicht", carryChanges: false)
        let second = await book.currentBranch()
        XCTAssertEqual(second, "experiments/Maras-Sicht-2", "names stay unique")
        let mainHead = try await book.git.log("main", limit: 1)[0]
        XCTAssertTrue(mainHead.subject.hasPrefix("Bearbeitet"))
    }

    func testSwitchingRefusesBranchesFromBeforeZadur() async throws {
        let book = try await makeBook()
        try await book.git.run(["switch", "--quiet", "-c", "alt"])
        try await book.git.run(["rm", "--quiet", Manifest.fileName])
        try await git(["commit", "--quiet", "-m", "alt"], in: book.url)
        try await book.git.run(["switch", "--quiet", "main"])
        do {
            try await book.switchTo("alt")
            XCTFail("expected an error")
        } catch ExperimentError.notAZadurVersion {}
    }

    // MARK: Adopting

    func testAdoptWithoutConflicts() async throws {
        let book = try await makeBook()
        let (a, b, _) = ids(book)
        let branch = try await book.startExperiment(named: "Neu", carryChanges: false)
        try edit(book, a, "Erster Absatz von A, neu erzählt.\n\nZweiter Absatz von A.\n")
        let newScene = try book.addScene(toChapter: book.manifest.chapters[0].id, after: a)
        try edit(book, newScene.id, "Eine ganz neue Szene.\n", title: "Neu")
        try await book.saveVersion()

        try await book.switchTo("main")
        try edit(book, b, "Erster Absatz von B.\n\nZweiter Absatz von B, in der Hauptfassung geändert.\n")
        try await book.saveVersion()

        let changes = try await book.changes(in: branch)
        XCTAssertEqual(Set(changes.scenes.map(\.title)), ["A", "Neu"])
        XCTAssertTrue(changes.structureChanged)
        XCTAssertEqual(changes.mainChangedScenes, 1)

        let result = try await book.adopt(branch)
        guard case .adopted = result else { return XCTFail("\(result)") }
        XCTAssertEqual(try body(book, a), "Erster Absatz von A, neu erzählt.\n\nZweiter Absatz von A.\n")
        XCTAssertTrue(try body(book, b).contains("in der Hauptfassung geändert"))
        XCTAssertEqual(book.manifest.chapters[0].sceneIDs, [a, newScene.id, b])

        let head = try await book.git.log(limit: 1)[0]
        XCTAssertEqual(head.parents.count, 2)
        XCTAssertEqual(head.subject, "Experiment „Neu“ übernommen")
        XCTAssertTrue(head.trailers["Adopted-From"]?.hasPrefix(branch) == true)

        let experiments = await book.experiments()
        XCTAssertTrue(experiments[0].isAdopted)
        let again = try await book.adopt(branch)
        XCTAssertEqual(again, .nothingNew)
    }

    func testParagraphConflictResolution() async throws {
        let book = try await makeBook()
        let (a, _, _) = ids(book)
        let branch = try await book.startExperiment(named: "Andere Fassung", carryChanges: false)
        try edit(book, a, "Erster Absatz von A.\n\nZweiter Absatz – so im Experiment.\n")
        try await book.saveVersion()
        try await book.switchTo("main")
        try edit(book, a, "Erster Absatz von A.\n\nZweiter Absatz – so in der Hauptfassung.\n")
        try await book.saveVersion()
        let headBefore = await book.git.headCommit()

        let result = try await book.adopt(branch)
        guard case .conflicts(let conflicts) = result, let conflict = conflicts.first else { return XCTFail("\(result)") }
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflict.sceneID, a)
        guard case .text(let segments) = conflict.kind else { return XCTFail("\(conflict.kind)") }
        XCTAssertEqual(segments.filter { if case .conflict = $0 { return true } else { return false } }.count, 1)
        XCTAssertTrue(segments.contains(.conflict(main: "Zweiter Absatz – so in der Hauptfassung.\n", experiment: "Zweiter Absatz – so im Experiment.\n")))

        // Saving versions is blocked while the adoption is open.
        do {
            _ = try await book.saveVersion()
            XCTFail("expected an error")
        } catch ExperimentError.adoptionInProgress {}

        let resolved = segments.map { segment -> String in
            switch segment {
            case .same(let text): text
            case .conflict(_, let experiment): experiment
            }
        }.joined()
        try await book.resolve(conflict.path, with: .text(resolved))
        let remaining = try await book.currentConflicts()
        XCTAssertTrue(remaining.isEmpty)
        try await book.finishAdoption()

        XCTAssertTrue(try body(book, a).contains("so im Experiment"))
        XCTAssertFalse(try body(book, a).contains("<<<<<<<"))
        XCTAssertTrue(try book.readScene(a).serialized().hasPrefix("---\ntitle: A\n"), "front matter intact")
        let head = try await book.git.log(limit: 1)[0]
        XCTAssertEqual(head.parents.first, headBefore)
        let inProgress = await book.adoptionInProgress()
        XCTAssertNil(inProgress)
    }

    func testTitleChangeAndOpeningEditDoNotCollide() async throws {
        let book = try await makeBook()
        let (a, _, _) = ids(book)
        let branch = try await book.startExperiment(named: "Anfang", carryChanges: false)
        try edit(book, a, "Ein neuer erster Absatz.\n\nZweiter Absatz von A.\n")
        try await book.saveVersion()
        try await book.switchTo("main")
        var scene = try book.readScene(a)
        scene.title = "A, umbenannt"
        scene.status = .revised
        try book.writeScene(scene)
        try await book.saveVersion()

        let result = try await book.adopt(branch)
        guard case .adopted = result else { return XCTFail("\(result)") }
        let merged = try book.readScene(a)
        XCTAssertEqual(merged.title, "A, umbenannt")
        XCTAssertEqual(merged.status, .revised)
        XCTAssertEqual(merged.body, "Ein neuer erster Absatz.\n\nZweiter Absatz von A.\n")
    }

    func testAbortLeavesMainUntouched() async throws {
        let book = try await makeBook()
        let (a, _, _) = ids(book)
        let branch = try await book.startExperiment(named: "X", carryChanges: false)
        try edit(book, a, "Ganz anders.\n")
        try await book.saveVersion()
        try await book.switchTo("main")
        try edit(book, a, "Auch anders.\n")
        try await book.saveVersion()
        let head = await book.git.headCommit()

        _ = try await book.adopt(branch)
        try await book.abortAdoption()
        let headAfter = await book.git.headCommit()
        XCTAssertEqual(headAfter, head)
        XCTAssertEqual(try body(book, a), "Auch anders.\n")
        let changed = try await book.git.changedPaths()
        XCTAssertTrue(changed.isEmpty)
    }

    func testStructureChangedOnBothSides() async throws {
        let book = try await makeBook()
        let (a, b, c) = ids(book)
        let c1 = book.manifest.chapters[0].id, c2 = book.manifest.chapters[1].id
        let branch = try await book.startExperiment(named: "Umbau", carryChanges: false)
        let added = try book.addScene(toChapter: c1, after: b)
        try edit(book, added.id, "Neu am Ende von Kapitel eins.\n")
        try book.updateManifest { $0.moveScene(c, toChapter: c1, at: 0) }  // c moves to chapter 1
        try await book.saveVersion()

        try await book.switchTo("main")
        try book.updateManifest { m in
            m.updateChapter(c1) { $0.sceneIDs = [b, a] }  // reordered
            m.updateChapter(c2) { $0.title = "Zwei (neu)" }  // renamed
        }
        try await book.saveVersion()

        let result = try await book.adopt(branch)
        guard case .adopted = result else { return XCTFail("\(result)") }
        // The new scene follows b (as in the experiment), even though the main version moved b up.
        XCTAssertEqual(book.manifest.chapter(withID: c1)?.sceneIDs, [c, b, added.id, a])
        XCTAssertEqual(book.manifest.chapter(withID: c2)?.sceneIDs, [])
        XCTAssertEqual(book.manifest.chapter(withID: c2)?.title, "Zwei (neu)")
    }

    func testSceneDeletedInMainButEditedInExperiment() async throws {
        let book = try await makeBook()
        let (_, _, c) = ids(book)
        let branch = try await book.startExperiment(named: "Rettung", carryChanges: false)
        try edit(book, c, "C lebt weiter.\n")
        try await book.saveVersion()
        try await book.switchTo("main")
        try book.deleteScene(c)
        try await book.saveVersion()

        let result = try await book.adopt(branch)
        guard case .conflicts(let conflicts) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(conflicts.map(\.kind), [.deletedInMain])
        try await book.resolve(conflicts[0].path, with: .keep)
        try await book.finishAdoption()
        XCTAssertEqual(try body(book, c), "C lebt weiter.\n")
        XCTAssertTrue(book.manifest.sceneIDs.contains(c), "a kept scene is back in the book")
    }

    func testAdoptSelectedScenes() async throws {
        let book = try await makeBook()
        let (a, b, _) = ids(book)
        let branch = try await book.startExperiment(named: "Auswahl", carryChanges: false)
        let added = try book.addScene(toChapter: book.manifest.chapters[0].id, after: a)
        try edit(book, added.id, "Neue Szene nach A.\n", title: "Nach A")
        try edit(book, b, "B, im Experiment verändert.\n")
        try await book.saveVersion()

        let result = try await book.adoptScenes([added.id], from: branch)
        let current = await book.currentBranch()
        XCTAssertEqual(current, "main")
        XCTAssertEqual(result?.subject, "Aus Experiment „Auswahl“ übernommen: „Nach A“ · +4 Wörter")
        XCTAssertEqual(book.manifest.chapters[0].sceneIDs, [a, added.id, b])
        XCTAssertEqual(try body(book, b), "Erster Absatz von B.\n\nZweiter Absatz von B.\n", "not selected, not adopted")
        let head = try await book.git.log(limit: 1)[0]
        XCTAssertTrue(head.trailers["Adopted-From"]?.hasPrefix(branch) == true)
    }

    // MARK: Milestones

    func testMilestones() async throws {
        let book = try await makeBook()
        let (a, _, _) = ids(book)
        try edit(book, a, "Fassung für den Club.\n")
        let milestone = try await book.setMilestone(name: "An den Club geschickt", note: "Als PDF")
        let head = await book.git.headCommit()
        XCTAssertEqual(milestone?.name, "An den Club geschickt")
        XCTAssertEqual(milestone?.note, "Als PDF")
        XCTAssertEqual(milestone?.commit, head, "pending changes were saved first")
        XCTAssertEqual(milestone?.tag, "milestone/An-den-Club-geschickt")
        let second = try await book.setMilestone(name: "An den Club geschickt")
        XCTAssertEqual(second?.tag, "milestone/An-den-Club-geschickt-2")
        let all = await book.milestones()
        XCTAssertEqual(all.count, 2)
    }
}

final class MergeHelperTests: XCTestCase {
    func testMergeList() {
        XCTAssertEqual(Manifest.mergeList(base: ["a", "b"], ours: ["a", "b"], theirs: ["b", "a"]), ["b", "a"])
        // Removing beats moving.
        XCTAssertEqual(Manifest.mergeList(base: ["a", "b", "c"], ours: ["c", "a", "b"], theirs: ["a", "x", "b"]), ["a", "x", "b"])
        // A new entry follows its predecessor, wherever the other side moved it.
        XCTAssertEqual(Manifest.mergeList(base: ["a", "b", "c"], ours: ["c", "a", "b"], theirs: ["a", "b", "c", "x"]), ["c", "x", "a", "b"])
        XCTAssertEqual(Manifest.mergeList(base: ["a", "b"], ours: ["a", "b", "o"], theirs: ["t", "b"]), ["t", "b", "o"])
    }

    func testParseConflictMarkers() {
        let text = "---\ntitle: A\n---\nGleich.\n<<<<<<< HEAD\nHaupt.\n=======\nExperiment.\n>>>>>>> experiments/x\nAuch gleich."
        XCTAssertEqual(ConflictSegment.parse(text), [
            .same("---\ntitle: A\n---\nGleich.\n"),
            .conflict(main: "Haupt.\n", experiment: "Experiment.\n"),
            .same("Auch gleich."),
        ])
        XCTAssertNil(ConflictSegment.parse("Keine Marker."))
        XCTAssertNil(ConflictSegment.parse("<<<<<<< HEAD\nkaputt"))
        let diff3 = "<<<<<<< HEAD\nA\n||||||| base\nB\n=======\nC\n>>>>>>> x\n"
        XCTAssertEqual(ConflictSegment.parse(diff3), [.conflict(main: "A\n", experiment: "C\n")])
    }
}
