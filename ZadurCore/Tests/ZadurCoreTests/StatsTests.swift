import Foundation
import XCTest
@testable import ZadurCore

/// Writing statistics from the history (made-up texts).
final class StatsTests: TempDirTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text)!
    }

    func testDaysAndStreak() {
        let days = WritingStats.days(from: [
            (date("2026-11-16T09:00:00+01:00"), 300, 40),
            (date("2026-11-16T21:00:00+01:00"), -50, 10),
            (date("2026-11-18T08:00:00+01:00"), 200, 25),
            (date("2026-11-19T23:30:00+01:00"), 120, 15),
            (date("2026-11-20T00:30:00+01:00"), 80, 5),
        ], calendar: calendar)
        XCTAssertEqual(days.map(\.words), [250, 200, 120, 80])
        XCTAssertEqual(days.first?.minutes, 50)
        XCTAssertEqual(days.first?.versions, 2)

        let stats = WritingStats(progress: [], days: days)
        XCTAssertEqual(stats.streak(until: date("2026-11-20T18:00:00+01:00"), calendar: calendar), 3)
        // Nothing written yet today: yesterday's streak still counts.
        XCTAssertEqual(stats.streak(until: date("2026-11-21T08:00:00+01:00"), calendar: calendar), 3)
        XCTAssertEqual(stats.streak(until: date("2026-11-22T08:00:00+01:00"), calendar: calendar), 0)

        let week = stats.total(from: date("2026-11-16T00:00:00+01:00"), to: date("2026-11-23T00:00:00+01:00"))
        XCTAssertEqual(week.words, 650)
        XCTAssertEqual(week.days, 4)
    }

    func testStatsFromSavedVersions() async throws {
        let book = try await Book.create(at: temp.appendingPathComponent("Buch.crea"), title: "Buch", author: "Test")
        let id = book.manifest.sceneIDs[0]
        var scene = try book.readScene(id)
        scene.body = "Eins zwei drei vier fünf.\n"
        try book.writeScene(scene)
        try await book.saveVersion(activeMinutes: 12)
        scene.body = "Eins zwei drei.\n"
        try book.writeScene(scene)
        try await book.saveVersion(activeMinutes: 3)

        let stats = try await book.writingStats()
        let today = try XCTUnwrap(stats.day(Date()))
        XCTAssertEqual(today.words, 3)  // +5, then −2
        XCTAssertEqual(today.minutes, 15)
        XCTAssertEqual(stats.progress.last?.words, 3)
        XCTAssertEqual(stats.progress.count, 3)

        // Experiments count for the days, but the progress line follows the open version.
        try await book.startExperiment(named: "Andere Fassung", carryChanges: false)
        scene = try book.readScene(id)
        scene.body = "Eins zwei drei vier fünf sechs sieben.\n"
        try book.writeScene(scene)
        try await book.saveVersion(activeMinutes: 5)
        try await book.switchTo(await book.mainBranch())
        let withExperiment = try await book.writingStats()
        XCTAssertEqual(withExperiment.day(Date())?.words, 7)
        XCTAssertEqual(withExperiment.progress.last?.words, 3)
    }

    func testVersionsFromBeforeZadurAreCounted() async throws {
        let source = temp.appendingPathComponent("roman")
        try write("book:\n  source: \"Szenen\"\nmetadata:\n  title: \"Roman\"\nchapters:\n  - title: \"Eins\"\n    scenes:\n      - \"Anfang\"\n", to: "book.yaml", in: source)
        try write("Der Wind kam.\n", to: "Szenen/Anfang.md", in: source)
        try write("# Notizen\n\nViele viele Wörter, die nicht zum Roman gehören.\n", to: "Notizen.md", in: source)
        let env = ["GIT_AUTHOR_DATE": "2026-03-01T10:00:00+01:00", "GIT_COMMITTER_DATE": "2026-03-01T10:00:00+01:00"]
        let git = Git(directory: source)
        try await git.run(["init", "--quiet", "--initial-branch=main"])
        try await git.run(["add", "-A"])
        try await git.run(["-c", "user.name=T", "-c", "user.email=t@x", "commit", "--quiet", "-m", "Anfang"], environment: env)
        try write("Der Wind kam von Westen. Er roch nach Tang.\n", to: "Szenen/Anfang.md", in: source)
        let later = ["GIT_AUTHOR_DATE": "2026-03-03T10:00:00+01:00", "GIT_COMMITTER_DATE": "2026-03-03T10:00:00+01:00"]
        try await git.run(["-c", "user.name=T", "-c", "user.email=t@x", "commit", "--quiet", "-am", "Mehr"], environment: later)

        _ = try await Importer.importFolder(source, to: temp.appendingPathComponent("Roman.crea"))
        let book = try Book(url: temp.appendingPathComponent("Roman.crea"))
        let stats = try await book.writingStats(calendar: calendar)
        XCTAssertEqual(Array(stats.progress.prefix(2).map(\.words)), [3, 9], "only the scenes folder counts, not the notes")
        XCTAssertEqual(stats.day(date("2026-03-01T12:00:00+01:00"), calendar: calendar)?.words, 3)
        XCTAssertEqual(stats.day(date("2026-03-03T12:00:00+01:00"), calendar: calendar)?.words, 6)
        XCTAssertFalse(book.loadWordCounts().isEmpty, "counted once, then remembered")
        let again = try await book.writingStats(calendar: calendar)
        XCTAssertEqual(again, stats)
    }

    func testWordGoalIsStored() async throws {
        let book = try await Book.create(at: temp.appendingPathComponent("Buch.crea"), title: "Buch", author: "Test")
        try book.updateManifest { $0.goal = 80_000 }
        XCTAssertEqual(try Book(url: book.url).manifest.goal, 80_000)
        try book.updateManifest { $0.goal = 0 }
        XCTAssertNil(try Book(url: book.url).manifest.goal)
    }
}
