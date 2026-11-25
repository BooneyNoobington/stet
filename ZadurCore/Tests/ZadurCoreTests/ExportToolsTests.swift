import Foundation
import XCTest
@testable import ZadurCore

/// Pandoc and Typst on demand. The archives here are made up (a tiny script per "tool"); the real
/// releases are only fetched with ZADUR_LIVE_TOOLS=1.
final class ExportToolsTests: TempDirTestCase {
    private var savedFolder: URL!
    private var savedCatalog: [String: [String: ToolPackage]]!

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedFolder = ExportTools.folder
        savedCatalog = ExportTools.catalog
        ExportTools.folder = temp.appendingPathComponent("Tools")
    }

    override func tearDownWithError() throws {
        ExportTools.folder = savedFolder
        ExportTools.catalog = savedCatalog
        try super.tearDownWithError()
    }

    /// An archive with `<root>/bin/<tool>`, a script that prints "<tool> <version>".
    private func archive(_ tool: String, version: String, printing printed: String? = nil, zip: Bool) throws -> (URL, String) {
        let root = "\(tool)-\(version)-test"
        let staging = temp.appendingPathComponent("staging-\(tool)")
        try write("#!/bin/sh\necho \"\(printed ?? "\(tool) \(version)")\"\n", to: "\(root)/bin/\(tool)", in: staging)
        try write("License text\n", to: "\(root)/LICENSE", in: staging)
        _ = try Tools.run(URL(fileURLWithPath: "/bin/chmod"), ["+x", staging.appendingPathComponent("\(root)/bin/\(tool)").path])
        let file = temp.appendingPathComponent("\(tool).\(zip ? "zip" : "tar.xz")")
        let result = zip
            ? try Tools.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-c", "-k", "--keepParent", root, file.path], in: staging)
            : try Tools.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-cJf", file.path, root], in: staging)
        XCTAssertEqual(result.status, 0, result.errors)
        return (file, try ExportTools.sha256(of: file))
    }

    private func register(_ tool: String, version: String, file: URL, sha: String) {
        let package = ToolPackage(tool: tool, version: version, url: URL(string: "https://example.com/\(file.lastPathComponent)")!,
                                  sha256: sha, size: 1000, binary: "\(tool)-\(version)-test/bin/\(tool)",
                                  extras: ["\(tool)-\(version)-test/LICENSE"])
        ExportTools.catalog[tool] = [ExportTools.architecture: package]
    }

    /// Hands out a copy of the local archive, like a download would.
    private func localDownload(_ files: [String: URL]) -> ExportTools.Download {
        { url, progress in
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("zadur-test-\(UUID().uuidString)")
            try FileManager.default.copyItem(at: files[url.lastPathComponent]!, to: copy)
            progress(1)
            return copy
        }
    }

    func testInstallsCheckedToolsAndExportUsesThem() async throws {
        let (zip, zipSHA) = try archive("pandoc", version: "9.1", zip: true)
        let (xz, xzSHA) = try archive("typst", version: "9.2", zip: false)
        register("pandoc", version: "9.1", file: zip, sha: zipSHA)
        register("typst", version: "9.2", file: xz, sha: xzSHA)
        XCTAssertNil(ExportTools.installed("pandoc"))
        XCTAssertEqual(ExportTools.downloadSize(for: ["pandoc", "typst"]), 2000)

        var reported: [Double] = []
        try await ExportTools.install(["pandoc", "typst"], download: localDownload([zip.lastPathComponent: zip, xz.lastPathComponent: xz])) {
            reported.append($0)
        }
        XCTAssertEqual(reported.last, 1)
        let pandoc = try XCTUnwrap(ExportTools.installed("pandoc"))
        XCTAssertEqual(pandoc.path, ExportTools.folder.appendingPathComponent("pandoc-9.1/pandoc").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ExportTools.folder.appendingPathComponent("typst-9.2/LICENSE").path))
        XCTAssertEqual(Exporter.tool("pandoc"), pandoc, "Zadur's own copy comes first")
        XCTAssertTrue(Exporter.missingTools(for: .pdfBook).isEmpty)

        try ExportTools.uninstall()
        XCTAssertNil(ExportTools.installed("typst"))
    }

    func testRejectsAWrongChecksumAndABrokenProgram() async throws {
        let (zip, _) = try archive("pandoc", version: "9.1", zip: true)
        register("pandoc", version: "9.1", file: zip, sha: String(repeating: "0", count: 64))
        do {
            try await ExportTools.install(["pandoc"], download: localDownload([zip.lastPathComponent: zip]))
            XCTFail("installed despite a wrong checksum")
        } catch let error as ExportTools.InstallError {
            XCTAssertEqual(error, .checksum("pandoc"))
        }
        XCTAssertNil(ExportTools.installed("pandoc"))

        let (broken, brokenSHA) = try archive("typst", version: "9.2", printing: "something else", zip: false)
        register("typst", version: "9.2", file: broken, sha: brokenSHA)
        do {
            try await ExportTools.install(["typst"], download: localDownload([broken.lastPathComponent: broken]))
            XCTFail("installed a program that doesn't report its version")
        } catch let error as ExportTools.InstallError {
            XCTAssertEqual(error, .notWorking("typst"))
        }
        XCTAssertNil(ExportTools.installed("typst"))
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: ExportTools.folder.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "\(leftovers)")
    }

    func testDownloadFailureIsExplained() async throws {
        let (zip, sha) = try archive("pandoc", version: "9.1", zip: true)
        register("pandoc", version: "9.1", file: zip, sha: sha)
        do {
            try await ExportTools.install(["pandoc"], download: { _, _ in throw URLError(.notConnectedToInternet) })
            XCTFail("no error while offline")
        } catch let error as ExportTools.InstallError {
            guard case .download("pandoc", _) = error else { return XCTFail("\(error)") }
        }
    }

    func testCatalogCoversBothKindsOfMac() {
        for tool in ["pandoc", "typst"] {
            for arch in ["arm64", "x86_64"] {
                let package = savedCatalog[tool]?[arch]
                XCTAssertNotNil(package, "\(tool) \(arch)")
                XCTAssertEqual(package?.sha256.count, 64)
                XCTAssertEqual(package?.url.host, "github.com")
            }
        }
    }

    // MARK: The real releases (only on request)

    func testLiveInstallAndExport() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ZADUR_LIVE_TOOLS"] == "1", "set ZADUR_LIVE_TOOLS=1 to download the real releases")
        ExportTools.catalog = savedCatalog
        var last = 0.0
        try await ExportTools.install(["pandoc", "typst"]) { last = $0 }
        XCTAssertEqual(last, 1, accuracy: 0.001)
        let pandoc = try XCTUnwrap(ExportTools.installed("pandoc"))
        let typst = try XCTUnwrap(ExportTools.installed("typst"))
        XCTAssertEqual(Exporter.tool("pandoc"), pandoc)
        XCTAssertEqual(Exporter.tool("typst"), typst)

        let book = try await Book.create(at: temp.appendingPathComponent("Probe.crea"), title: "Probe", author: "Test")
        var scene = try book.readScene(book.manifest.sceneIDs[0])
        scene.body = "Ein kurzer Satz für den Export.\n"
        try book.writeScene(scene)
        for format in [ExportFormat.pdfBook, .docx, .epub] {
            let result = try await Exporter.export(book, options: ExportOptions(format: format, quotes: .de),
                                                   to: temp.appendingPathComponent("Probe.\(format.fileExtension)"))
            let size = (try FileManager.default.attributesOfItem(atPath: result.file.path)[.size] as? NSNumber)?.intValue ?? 0
            XCTAssertGreaterThan(size, 1000, "\(format)")
            print("LIVE export \(format.rawValue): \(size) bytes with \(pandoc.path.contains("/Tools/") ? "Zadur's tools" : "other tools")")
        }
    }
}
