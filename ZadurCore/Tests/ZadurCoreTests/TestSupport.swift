import Foundation
import XCTest
@testable import ZadurCore

/// A fresh temporary directory per test, removed afterwards.
class TempDirTestCase: XCTestCase {
    var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZadurCoreTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    func write(_ text: String, to relative: String, in root: URL? = nil) throws {
        let url = (root ?? temp).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ relative: String, in root: URL) throws -> String {
        String(decoding: try Data(contentsOf: root.appendingPathComponent(relative)), as: UTF8.self)
    }

    /// Runs git with a fixed test identity.
    @discardableResult
    func git(_ args: [String], in dir: URL) async throws -> String {
        try await Git(directory: dir).run(["-c", "user.name=Test", "-c", "user.email=test@example.com"] + args).string
    }
}
