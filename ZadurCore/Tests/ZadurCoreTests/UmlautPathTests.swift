import Foundation
import XCTest
@testable import ZadurCore

/// Books in folders with umlauts, in both ways they can be spelled (ä as one character, or
/// a + ¨ as macOS passes paths to programs): git works on them, and the health check doesn't
/// call them damaged (it did: `git fsck` compared the two spellings of the book's path).
final class UmlautPathTests: TempDirTestCase {
    func testBooksWithUmlautsInTheirPathAreHealthy() async throws {
        for (folder, name) in [("Bücher", "Märchen.crea"), ("Bu\u{0308}cher", "Ma\u{0308}rchen zwei.crea"), ("Bücher", "Plain.crea")] {
            let book = try await Book.create(at: temp.appendingPathComponent("\(folder)/\(name)"), title: "Märchen", author: "Test")
            var scene = try book.readScene(book.manifest.sceneIDs[0])
            scene.body = "Es war einmal.\n"
            try book.writeScene(scene)
            let changed = try await book.git.changedPaths()
            XCTAssertEqual(changed.count, 1, name)
            try await book.saveVersion()
            _ = try await book.snapshot(device: "a")
            let report = await HealthCheck.run(book)
            XCTAssertTrue(report.isHealthy, "\(name): \(report.integrityProblem ?? "")")

            // Opened again under the other spelling (e.g. from the recent list).
            let other = URL(fileURLWithPath: book.url.path.decomposedStringWithCanonicalMapping == book.url.path
                            ? book.url.path.precomposedStringWithCanonicalMapping : book.url.path.decomposedStringWithCanonicalMapping)
            let again = try Book(url: other)
            let problem = await again.git.integrityProblem()
            XCTAssertNil(problem, name)
            let log = try await again.git.log()
            XCTAssertEqual(log.count, 2, name)
        }
    }
}
