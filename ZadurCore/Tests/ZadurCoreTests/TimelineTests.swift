import Foundation
import XCTest
@testable import ZadurCore

/// Story time from scene facts, inherited facts, and the timeline (made-up texts).
final class TimelineTests: TempDirTestCase {
    func testParsesTheWaysWritersWriteDates() {
        XCTAssertEqual(StoryTime.parse(date: "14.7.1998"), StoryTime(year: 1998, month: 7, day: 14))
        XCTAssertEqual(StoryTime.parse(date: "14. Juli 1998", time: "23:30"), StoryTime(year: 1998, month: 7, day: 14, minutes: 1410))
        XCTAssertEqual(StoryTime.parse(date: "1998-07-14", time: "7 Uhr"), StoryTime(year: 1998, month: 7, day: 14, minutes: 420))
        XCTAssertEqual(StoryTime.parse(date: "Juli 1998"), StoryTime(year: 1998, month: 7))
        XCTAssertEqual(StoryTime.parse(date: "Sommer 1978"), StoryTime(year: 1978, month: 7))
        XCTAssertEqual(StoryTime.parse(date: "1978"), StoryTime(year: 1978))
        XCTAssertEqual(StoryTime.parse(date: "3/1953"), StoryTime(year: 1953, month: 3))
        XCTAssertNil(StoryTime.parse(date: "am nächsten Morgen"))
        XCTAssertNil(StoryTime.parse(date: "31.13.1998"))
        XCTAssertNil(StoryTime.parseTime("23"), "a bare number isn't a time")

        XCTAssertLessThan(StoryTime.parse(date: "1998")!, StoryTime.parse(date: "Juli 1998")!)
        XCTAssertLessThan(StoryTime.parse(date: "14.7.1998", time: "10:15")!, StoryTime.parse(date: "14.7.1998", time: "16:00")!)
    }

    func testChaptersAndPartsPassTheirFactsOn() async throws {
        let book = try await Book.create(at: temp.appendingPathComponent("Buch.crea"), title: "Buch", author: "Test")
        let chapter = book.manifest.chapters[0]
        let scene = book.manifest.sceneIDs[0]
        try book.updateManifest { $0.updateChapter(chapter.id) { $0.facts = [Fact("Datum", "Juli 1998"), Fact("Ort", "See")] } }
        let reread = try Book(url: book.url)
        XCTAssertEqual(reread.manifest.chapters[0].facts, [Fact("Datum", "Juli 1998"), Fact("Ort", "See")], "kept in manuscript.yaml")
        XCTAssertEqual(book.manifest.effectiveFacts(ofScene: scene, own: [Fact("Ort", "Steg")]),
                       [Fact("Datum", "Juli 1998"), Fact("Ort", "Steg")], "the scene's own fact wins")

        // Merging keeps one side's change of the chapter's facts.
        var base = book.manifest
        base.updateChapter(chapter.id) { $0.facts = [] }
        var ours = base
        ours.updateChapter(chapter.id) { $0.facts = [Fact("Datum", "1999")] }
        XCTAssertEqual(Manifest.merge(base: base, ours: ours, theirs: base).chapters[0].facts, [Fact("Datum", "1999")])
    }

    func testTimelineShowsFlashbacks() async throws {
        let book = try await SampleBook.create(at: temp.appendingPathComponent("Beispiel.crea"))
        let timeline = book.timeline()
        XCTAssertEqual(timeline.map(\.position), [1, 2, 3, 4])
        XCTAssertEqual(timeline.map(\.isFlashback), [false, true, false, false])
        XCTAssertEqual(timeline[1].timeText, "Sommer 1978")
        XCTAssertEqual(timeline[1].place, "Seehaus")
        let inStoryOrder = timeline.compactMap { entry in entry.time.map { (entry.title, $0) } }.sorted { $0.1 < $1.1 }.map(\.0)
        XCTAssertEqual(inStoryOrder.first, "Damals")
    }
}

/// The graphical history's lanes.
final class HistoryGraphTests: TempDirTestCase {
    private func commit(_ hash: String, _ parents: [String]) -> Git.Commit {
        Git.Commit(hash: hash, parents: parents, date: Date(), author: "T", subject: hash, body: "", note: nil, path: nil)
    }

    func testLanesForAnExperimentThatWasAdopted() {
        // m3 adopts the experiment (e2, e1) that branched off at m1; m2 happened meanwhile.
        let commits = [commit("m3", ["m2", "e2"]), commit("e2", ["e1"]), commit("m2", ["m1"]), commit("e1", ["m1"]), commit("m1", ["m0"]), commit("m0", [])]
        let rows = HistoryLayout.rows(commits)
        XCTAssertEqual(rows.map(\.lane), [0, 1, 0, 1, 0, 0])
        XCTAssertEqual(rows[0].outgoing, [0, 1], "the adoption has two parents: two lanes go down")
        XCTAssertEqual(rows[1].incoming, [1])
        XCTAssertEqual(rows[2].passing, [1], "the experiment's lane runs past m2")
        XCTAssertEqual(rows[4].incoming, [0, 1], "both lanes meet at the branch point")
        XCTAssertEqual(rows[5].outgoing, [], "the first version has no parent")
    }

    func testGraphOfTheSampleBook() async throws {
        let book = try await SampleBook.create(at: temp.appendingPathComponent("Beispiel.crea"))
        let rows = try await book.historyGraph()
        XCTAssertEqual(rows.count, 4, "3 versions of the main version, 1 in the experiment")
        XCTAssertEqual(rows.filter(\.isMain).count, 3)
        XCTAssertTrue(rows.contains { $0.branches.contains("Hauptfassung") })
        XCTAssertTrue(rows.contains { $0.branches.contains("Anderes Ende") && !$0.isMain })
        XCTAssertTrue(rows.contains { $0.milestones.contains { $0.name == "Erste Fassung" } })
        XCTAssertEqual(Set(rows.map(\.lane)).count, 2)
    }
}
