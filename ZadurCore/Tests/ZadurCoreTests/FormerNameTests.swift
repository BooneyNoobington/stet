import Foundation
import XCTest
@testable import ZadurCore

/// What people have from when Zadur was called Stet keeps working.
final class FormerNameTests: TempDirTestCase {
    func testStoredSigningSetupIsStillRead() throws {
        let stored = #"{"method":{"stetKey":{"path":"/k/signatur_ed25519"}},"label":"Stet-Schlüssel dieses Macs","fingerprint":"SHA256:x"}"#
        let setup = try JSONDecoder().decode(SigningSetup.self, from: Data(stored.utf8))
        XCTAssertEqual(setup.method, .zadurKey(path: "/k/signatur_ed25519"))
        let again = try JSONEncoder().encode(setup)
        XCTAssertTrue(String(decoding: again, as: UTF8.self).contains("stetKey"), "stored the same way, so an older version reads it")
        let smime = #"{"method":{"smime":{"program":"/p","certificateID":"c"}},"label":"S/MIME","fingerprint":"f"}"#
        XCTAssertEqual(try JSONDecoder().decode(SigningSetup.self, from: Data(smime.utf8)).method, .smime(program: "/p", certificateID: "c"))
        XCTAssertEqual(SigningOption.Kind.zadurKey.rawValue, "stetKey")
    }

    func testIdentifiersThatMustNotChange() {
        XCTAssertEqual(Book.legacyTrailerPrefix, "Stet-")
        XCTAssertEqual(Receipt.legacyHeader, "Stet-Beleg 1")
        XCTAssertEqual(Signing.proofNamespace, "stet-nachweis")
        XCTAssertTrue(SSHKey.folder.path.hasSuffix("/Application Support/Stet/Keys"))
        XCTAssertEqual(Book.readableExtensions, ["crea", "stet"])
        XCTAssertEqual(Book.fileExtension, "crea")
    }

    func testBooksAndBackupsEndingInStet() async throws {
        let book = try await Book.create(at: temp.appendingPathComponent("Alt.stet"), title: "Alt", author: "Test")
        XCTAssertNoThrow(try Book(url: book.url))
        let folder = temp.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let new = try await Backup.create(book, in: folder, date: Date(timeIntervalSince1970: 1_795_000_000))
        XCTAssertTrue(new.lastPathComponent.hasSuffix(".crea.zip"))
        let old = folder.appendingPathComponent(new.lastPathComponent.replacingOccurrences(of: ".crea.zip", with: ".stet.zip")
            .replacingOccurrences(of: "2026", with: "2025"))
        try FileManager.default.copyItem(at: new, to: old)
        XCTAssertEqual(Backup.list(in: folder, for: book).map(\.url.lastPathComponent), [new.lastPathComponent, old.lastPathComponent])
        let restored = try await Backup.restore(old, into: temp.appendingPathComponent("Zurück"))
        XCTAssertEqual(restored.lastPathComponent, "Alt.stet", "named as it was")
        // Both kinds count when only the newest are kept.
        XCTAssertEqual(try Backup.rotate(in: folder, for: book, keep: 1).map(\.lastPathComponent), [old.lastPathComponent])
    }
}
