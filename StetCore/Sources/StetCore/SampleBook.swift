import Foundation

/// A small book to try Stet with: two chapters, four scenes, a comment and a TODO, a wiki
/// with a figure and a place, scene facts (one scene is a flashback), two versions, a milestone
/// and an experiment with another ending. The text is Stet's own.
public enum SampleBook {
    public static let title = "Ein Sommer am See"

    public static func create(at url: URL) async throws -> Book {
        let book = try await Book.create(at: url, title: title, author: "Stet")
        let firstChapter = try required(book.manifest.chapters.first)
        try book.updateManifest { $0.updateChapter(firstChapter.id) { $0.title = "Ankunft" } }

        let arrival = try required(book.manifest.sceneIDs.first)
        try write(book, arrival, title: "Am Steg", facts: [Fact("Datum", "14.7.1998"), Fact("Uhrzeit", "10:15"), Fact("Ort", "Steg")], body: """
        Der Bus hielt nur einmal am Tag am See, und Lene war die Einzige, die ausstieg. Sie stellte den Koffer auf den Steg und sah zum Seehaus hinüber. Die Fensterläden waren geschlossen, wie damals.

        Im Schilf rief ein Vogel.{>>Vielleicht noch ein Geräusch vom Wasser? Es ist sehr still hier.<<} Lene kannte den Ruf, aber nicht den Namen.

        """)
        let past = try book.addScene(toChapter: firstChapter.id, after: arrival)
        try write(book, past.id, title: "Damals", facts: [Fact("Datum", "Sommer 1978"), Fact("Ort", "[[Seehaus]]")], body: """
        Der Vater hatte das Boot jedes Frühjahr selbst gestrichen, jedes Mal in einer anderen Farbe. In dem Sommer, in dem Lene sieben wurde, war es gelb, und sie durfte zum ersten Mal allein hinausrudern.

        """)

        let storm = try book.addChapter(title: "Gewitter", after: firstChapter.id)
        let warning = try required(storm.sceneIDs.first)
        try write(book, warning, title: "Die Warnung", facts: [Fact("Datum", "14.7.1998"), Fact("Uhrzeit", "16:00"), Fact("Ort", "Steg")], body: """
        Am Nachmittag kam der Fischer vorbei und zeigte zum Himmel. »Heute Nacht wird es laut«, sagte er. »Schließ die Läden.«

        Lene lachte, aber am Abend zog sie die Läden trotzdem zu.{>>TODO: Einen Namen für den Fischer finden.<<}

        """)
        let night = try book.addScene(toChapter: storm.id, after: warning)
        try write(book, night.id, title: "Nacht im Seehaus", facts: [Fact("Datum", "14.7.1998"), Fact("Uhrzeit", "23:30"), Fact("Ort", "[[Seehaus]]")], body: """
        Der Donner kam über das Wasser wie ein schwerer Wagen. Lene saß im Dunkeln und zählte die Sekunden zwischen Blitz und Knall, so wie es ihr der Vater beigebracht hatte.

        Bei drei hörte sie auf zu zählen. Jemand klopfte an die Tür.

        """)

        var lene = try book.createWiki(title: "Lene", kind: .character)
        lene.facts = [Fact("Alter", "34"), Fact("Beruf", "Fotografin"), Fact("Zuhause", "[[Seehaus]]")]
        lene.body = "Kommt nach zwanzig Jahren zurück an den See. Fotografiert lieber, als dass sie redet.\n"
        try book.saveWiki(lene)
        var house = try book.createWiki(title: "Seehaus", kind: .place)
        house.facts = [Fact("Lage", "Ostufer, am Ende des Stegs")]
        house.body = "Das Ferienhaus der Familie. Seit dem Tod des Vaters steht es leer.\n"
        try book.saveWiki(house)
        try await book.saveVersion(activeMinutes: 25, subject: "Erste Fassung aller Szenen")

        var scene = try book.readScene(arrival)
        scene.body += "Sie nahm den Schlüssel aus der Jackentasche. Er war kleiner, als sie ihn in Erinnerung hatte.\n"
        try book.writeScene(scene)
        try await book.saveVersion(activeMinutes: 8)
        try await book.setMilestone(name: "Erste Fassung", note: "Zum Ausprobieren: Diese Markierung steht im Verlauf.")

        // An experiment with another ending, next to the main version.
        let main = await book.currentBranch() ?? "main"
        try await book.startExperiment(named: "Anderes Ende", carryChanges: false)
        var ending = try book.readScene(night.id)
        ending.body = ending.body.replacingOccurrences(of: "Jemand klopfte an die Tür.", with: "Das Gewitter zog weiter, und mit ihm die Angst.")
        try book.writeScene(ending)
        try await book.saveVersion(activeMinutes: 6)
        try await book.switchTo(main)
        return try Book(url: url)
    }

    private static func write(_ book: Book, _ id: String, title: String, facts: [Fact], body: String) throws {
        var scene = try book.readScene(id)
        scene.title = title
        scene.factList = facts
        scene.body = body
        try book.writeScene(scene)
    }

    private struct Missing: Error {}

    private static func required<T>(_ value: T?) throws -> T {
        guard let value else { throw Missing() }
        return value
    }
}
