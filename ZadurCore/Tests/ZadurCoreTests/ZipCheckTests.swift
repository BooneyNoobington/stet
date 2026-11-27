import Foundation
import XCTest
@testable import ZadurCore

/// A backup to restore or a wiki to import may come from someone else: nothing in the ZIP may
/// land outside the target or point at another file on this Mac.
final class ZipCheckTests: TempDirTestCase {
    /// A ZIP of what `setUp` puts into a fresh folder (links stored as links).
    private func zipped(_ name: String, _ setUp: (URL) throws -> Void) async throws -> URL {
        let folder = temp.appendingPathComponent("Bau-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try setUp(folder)
        let zip = temp.appendingPathComponent(name)
        try await Backup.run("/usr/bin/zip", ["-q", "-r", "-y", zip.path, "."], in: folder)
        return zip
    }

    private func link(_ relative: String, in folder: URL, to target: String) throws {
        let url = folder.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
    }

    /// Changes a name in both places a ZIP keeps it (local header and central directory).
    private func rename(_ old: String, to new: String, in zip: URL) throws {
        var data = try Data(contentsOf: zip)
        var replaced = 0
        while let range = data.range(of: Data(old.utf8)) {
            data.replaceSubrange(range, with: Data(new.utf8))
            replaced += 1
        }
        XCTAssertEqual(replaced, 2)
        try data.write(to: zip)
    }

    func testAWikiWithALinkIsRefused() async throws {
        let zip = try await zipped("Wiki.zip") { folder in
            try self.write("---\ntitle: Lene\n---\nDie Wärterin.\n", to: "Wiki/lene.md", in: folder)
            try self.link("Wiki/schluessel.md", in: folder, to: NSHomeDirectory() + "/.ssh/id_rsa")
        }
        XCTAssertThrowsError(try Book.wikiEntries(at: zip)) { error in
            XCTAssertEqual(error as? ZipCheck.Problem, .unsafeEntry(zip, "Wiki/schluessel.md"))
        }

        let plain = try await zipped("Wiki ohne Link.zip") { folder in
            try self.write("---\ntitle: Lene\n---\nDie Wärterin.\n", to: "Wiki/lene.md", in: folder)
        }
        XCTAssertEqual(try Book.wikiEntries(at: plain).map(\.id), ["lene"])
    }

    func testABackupThatReachesOutIsNotRestored() async throws {
        let target = temp.appendingPathComponent("Wiederhergestellt")
        let linked = try await zipped("Fremd – Backup.crea.zip") { folder in
            try self.write("title: Fremd\n", to: "Fremd.crea/manuscript.yaml", in: folder)
            try self.link("Fremd.crea/scenes/k3v9qa.md", in: folder, to: NSHomeDirectory() + "/.zshrc")
        }
        do {
            _ = try await Backup.restore(linked, into: target)
            XCTFail("restored a link")
        } catch {
            XCTAssertEqual(error as? ZipCheck.Problem, .unsafeEntry(linked, "Fremd.crea/scenes/k3v9qa.md"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "nothing unpacked")

        let upward = try await zipped("Nach oben.crea.zip") { folder in
            try self.write("title: Fremd\n", to: "Fremd.crea/manuscript.yaml", in: folder)
            try self.write("x\n", to: "aa/boese.txt", in: folder)
        }
        try rename("aa/boese.txt", to: "../boese.txt", in: upward)
        do {
            _ = try await Backup.restore(upward, into: target)
            XCTFail("restored a path out")
        } catch {
            XCTAssertEqual(error as? ZipCheck.Problem, .unsafeEntry(upward, "../boese.txt"))
        }
    }

    func testOnlyHarmlessZipsPass() async throws {
        let absolute = try await zipped("Absolut.zip") { try self.write("x\n", to: "xtmp-boese.txt", in: $0) }
        try rename("xtmp-boese.txt", to: "/tmp-boese.txt", in: absolute)
        XCTAssertThrowsError(try ZipCheck.check(absolute)) { XCTAssertEqual($0 as? ZipCheck.Problem, .unsafeEntry(absolute, "/tmp-boese.txt")) }

        let source = temp.appendingPathComponent("Geheim")
        try write("x\n", to: "notiz.txt", in: source)
        let locked = temp.appendingPathComponent("Verschlüsselt.zip")
        try await Backup.run("/usr/bin/zip", ["-q", "-P", "geheim", locked.path, "notiz.txt"], in: source)
        XCTAssertThrowsError(try ZipCheck.check(locked)) { XCTAssertEqual($0 as? ZipCheck.Problem, .encrypted(locked)) }

        let text = temp.appendingPathComponent("Text.zip")
        try write("Nur Text.\n", to: text.lastPathComponent)
        XCTAssertThrowsError(try ZipCheck.check(text)) { XCTAssertEqual($0 as? ZipCheck.Problem, .notAZip(text)) }

        let book = try await Book.create(at: temp.appendingPathComponent("Echt.crea"), title: "Echt", author: "Test")
        let backup = try await Backup.create(book, to: temp.appendingPathComponent("Echt.crea.zip"))
        XCTAssertNoThrow(try ZipCheck.check(backup), "a real backup, with its whole history")
    }
}
