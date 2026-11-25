import XCTest
@testable import ZadurCore

final class NotesTests: XCTestCase {
    func testNotesWithUTF16Offsets() {
        let body = "Grüße 🌊 vorab. {==Die Lichter==}{>>@Gisela: Zu früh?<<} Und {>>TODO: Tide prüfen<<} dann {>>Nur so<<}."
        let notes = CriticMarkup.notes(in: body, sceneID: "s", sceneTitle: "Szene")
        XCTAssertEqual(notes.map(\.kind), [.comment, .todo, .comment])
        XCTAssertEqual(notes[0].author, "Gisela")
        XCTAssertEqual(notes[0].text, "Zu früh?")
        XCTAssertEqual(notes[0].highlighted, "Die Lichter")
        XCTAssertEqual(notes[1].text, "Tide prüfen")
        XCTAssertNil(notes[2].author)
        // Offsets count UTF-16 code units, like the editor: the wave emoji is two.
        let ns = body as NSString
        XCTAssertEqual(ns.substring(with: NSRange(location: notes[0].from, length: notes[0].to - notes[0].from)),
                       "{==Die Lichter==}{>>@Gisela: Zu früh?<<}")
    }

    func testRemovingKeepsHighlightedText() {
        let body = "A {==B==}{>>c<<} D {>>e<<}F"
        let notes = CriticMarkup.notes(in: body, sceneID: "s", sceneTitle: "")
        XCTAssertEqual(CriticMarkup.removing(notes[0], from: body), "A B D {>>e<<}F")
        XCTAssertEqual(CriticMarkup.removing(notes[1], from: body), "A {==B==}{>>c<<} D F")
        XCTAssertNil(CriticMarkup.removing(notes[1], from: "anders"), "text changed meanwhile")
    }

    func testCommentSyntax() {
        XCTAssertEqual(CriticMarkup.comment("Zu lang\nfinde ich", author: "Gisela"), "{>>@Gisela: Zu lang finde ich<<}")
        XCTAssertEqual(CriticMarkup.comment("Gut", author: nil, around: "Satz"), "{==Satz==}{>>Gut<<}")
    }

    func testFindingPassagesDespiteTypography() {
        let prose = #"Er spuckte. "Wo ist der Wärter?", fragte sie -- es war *nicht* der Wind... {>>Notiz<<}Ende."#
        func found(_ passage: String) -> String? {
            PassageFinder.find(passage, in: prose).map { (prose as NSString).substring(with: NSRange(location: $0.lowerBound, length: $0.count)) }
        }
        XCTAssertEqual(found("„Wo ist der Wärter?“, fragte sie"), #""Wo ist der Wärter?", fragte sie"#)
        XCTAssertEqual(found("sie – es war nicht der Wind…"), "sie -- es war *nicht* der Wind...")
        XCTAssertEqual(found("Wind… Ende"), "Wind... {>>Notiz<<}Ende", "comments in between are invisible")
        XCTAssertEqual(found("WO IST"), #"Wo ist"#)
        XCTAssertNil(found("kommt nicht vor"))
        XCTAssertNil(found("Er"), "too short to be meaningful")
    }
}

final class FeedbackTests: TempDirTestCase {
    func makeBook() async throws -> Book {
        let book = try await Book.create(at: temp.appendingPathComponent("Feedback.crea"), title: "Der Leuchtturm", author: "Erika Muster")
        var scene = try book.readScene(book.manifest.sceneIDs[0])
        scene.body = #"Der Wind kam von Westen. "Wo ist der Wärter?", fragte sie. {>>@Gisela: Zu direkt?<<}"# + "\n\n"
            + "Er spuckte ins Wasser. {==Die Lichter waren verschwunden.==}{>>TODO: Uhrzeit prüfen<<}\n"
        try book.writeScene(scene)
        let second = try book.addScene(toChapter: book.manifest.chapters[0].id, after: scene.id)
        var s2 = try book.readScene(second.id)
        s2.body = "Am Abend klopfte es an der Tür.\n"
        try book.writeScene(s2)
        try await book.saveVersion()
        return book
    }

    func testNotesAcrossTheBookAndRemoving() async throws {
        let book = try await makeBook()
        let notes = book.notes()
        XCTAssertEqual(notes.map(\.kind), [.comment, .todo])
        XCTAssertEqual(notes.map(\.sceneID), [book.manifest.sceneIDs[0], book.manifest.sceneIDs[0]])
        try book.removeNote(notes[1])
        XCTAssertTrue(try book.readScene(notes[1].sceneID).body.contains("Er spuckte ins Wasser. Die Lichter waren verschwunden.\n"))
        XCTAssertEqual(book.notes().count, 1)
    }

    /// Keys another program wrote stay when Zadur saves the entry (Crea spec §8).
    func testFeedbackKeysOfOtherProgramsAreKept() async throws {
        let book = try await makeBook()
        var entry = try book.addFeedback(from: "Gisela", received: Date(timeIntervalSince1970: 1_795_000_000), refersTo: nil, text: "Gut.")
        let file = book.url.appendingPathComponent(entry.path)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("status: open\n"))
        try Data(text.replacingOccurrences(of: "status: open\n", with: "status: open\nleser-app-sterne: 4\n").utf8).write(to: file)
        entry = try XCTUnwrap(book.feedbackEntries().first)
        entry.isDone = true
        try book.saveFeedback(entry)
        let saved = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(saved.contains("leser-app-sterne: 4"), saved)
        XCTAssertTrue(saved.contains("status: done"))
    }

    func testFeedbackEntriesWithAttachments() async throws {
        let book = try await makeBook()
        let photo = temp.appendingPathComponent("Ausdruck Seite 3.jpg")
        try Data("JPEG".utf8).write(to: photo)
        let day = Date(timeIntervalSince1970: 1_795_000_000)
        let first = try book.addFeedback(from: "Gisela", received: day, refersTo: "export/2026-11-20-pdf-manuskript",
                                         text: "Der Anfang zieht sich.\nAber das Ende!", attachments: [photo])
        XCTAssertEqual(first.attachments.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.url.appendingPathComponent(first.attachments[0]).path))
        XCTAssertTrue(first.id.contains("Gisela"))

        var second = try book.addFeedback(from: "Horst", received: day.addingTimeInterval(86_400), refersTo: nil, text: "Schön.")
        var entries = book.feedbackEntries()
        XCTAssertEqual(entries.map(\.from), ["Horst", "Gisela"], "newest first")
        XCTAssertEqual(entries[1], first, "round trip through the file")

        second.isDone = true
        try book.saveFeedback(second)
        entries = book.feedbackEntries()
        XCTAssertEqual(entries.map(\.from), ["Gisela", "Horst"], "open ones first")

        try book.deleteFeedback(first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: book.url.appendingPathComponent(first.attachments[0]).path))
        XCTAssertEqual(book.feedbackEntries().map(\.from), ["Horst"])

        let saved = try await book.saveVersion()
        XCTAssertTrue(saved?.subject.contains("Feedback") == true)
    }

    /// Export to Word with comments, read them back, find their passages.
    func testWordRoundTrip() async throws {
        if !Exporter.missingTools(for: .docx).isEmpty { throw XCTSkip("needs pandoc") }
        let book = try await makeBook()
        var options = ExportOptions(format: .docx)
        options.commentsAsAnnotations = true
        let docx = try await Exporter.export(book, options: options, to: temp.appendingPathComponent("Rueck.docx"))

        let comments = try await Book.wordComments(in: docx.file)
        XCTAssertEqual(comments.map(\.author), ["Gisela", "Erika Muster"])
        XCTAssertEqual(comments.map(\.text), ["Zu direkt?", "TODO: Uhrzeit prüfen"])
        XCTAssertEqual(comments[1].anchor, "Die Lichter waren verschwunden.")

        let located = try XCTUnwrap(book.locate(comments[1].anchor))
        XCTAssertEqual(located.sceneID, book.manifest.sceneIDs[0])
        // The exported text had „…“; today's text has straight quotes – still found.
        XCTAssertNotNil(book.locate("„Wo ist der Wärter?“, fragte sie"))

        // The export's version of the scene can be compared with today.
        let version = await book.version(ofScene: book.manifest.sceneIDs[0], at: docx.stamp.commit)
        XCTAssertNotNil(version)
    }
}
