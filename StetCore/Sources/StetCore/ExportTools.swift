import CryptoKit
import Foundation

/// One official release of a tool Stet exports with, for one kind of Mac.
public struct ToolPackage: Equatable {
    public let tool: String
    public let version: String
    public let url: URL
    /// SHA-256 of the archive, as published with the release; the download must match it.
    public let sha256: String
    public let size: Int
    /// The program inside the archive.
    public let binary: String
    /// License files inside the archive, kept next to the program.
    public let extras: [String]
}

/// Pandoc and Typst on demand: Stet downloads the official release for this Mac from GitHub,
/// checks it against the checksum pinned here, and keeps it in Application Support. Versions
/// installed with Homebrew are still used when Stet hasn't installed its own.
public enum ExportTools {
    /// Where installed tools live (`<tool>-<version>/<tool>`). Overridable for tests.
    public static var folder: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Stet/Tools", isDirectory: true)

    public static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    private static func github(_ path: String) -> URL { URL(string: "https://github.com/" + path)! }

    /// The versions Stet's export is tested with. To update: new URLs, sizes and the SHA-256
    /// digests GitHub lists for the release assets.
    public static var catalog: [String: [String: ToolPackage]] = [
        "pandoc": [
            "arm64": ToolPackage(tool: "pandoc", version: "3.14",
                                 url: github("jgm/pandoc/releases/download/3.14/pandoc-3.14-arm64-macOS.zip"),
                                 sha256: "58d6593884fec9d4424b641b92503c316d9c36decb2891ff8d73ae74dd3b6304", size: 43_712_865,
                                 binary: "pandoc-3.14-arm64/bin/pandoc", extras: []),
            "x86_64": ToolPackage(tool: "pandoc", version: "3.14",
                                  url: github("jgm/pandoc/releases/download/3.14/pandoc-3.14-x86_64-macOS.zip"),
                                  sha256: "891708579061e7b1c1a6ce0df30ebb3cb2b6d0ca045ed3c8554ab830c1e0c270", size: 27_490_795,
                                  binary: "pandoc-3.14-x86_64/bin/pandoc", extras: []),
        ],
        "typst": [
            "arm64": ToolPackage(tool: "typst", version: "0.15.1",
                                 url: github("typst/typst/releases/download/v0.15.1/typst-aarch64-apple-darwin.tar.xz"),
                                 sha256: "48f62ed034aa3a7978309579ac6ca00045e2ef0da73114e8af27cfd8e74dc05a", size: 14_438_168,
                                 binary: "typst-aarch64-apple-darwin/typst",
                                 extras: ["typst-aarch64-apple-darwin/LICENSE", "typst-aarch64-apple-darwin/NOTICE"]),
            "x86_64": ToolPackage(tool: "typst", version: "0.15.1",
                                  url: github("typst/typst/releases/download/v0.15.1/typst-x86_64-apple-darwin.tar.xz"),
                                  sha256: "7f9fdd9584866245de9a79e0add8f9236fae6f40a8a45e2c4771ccc14db4e0fa", size: 15_635_600,
                                  binary: "typst-x86_64-apple-darwin/typst",
                                  extras: ["typst-x86_64-apple-darwin/LICENSE", "typst-x86_64-apple-darwin/NOTICE"]),
        ],
    ]

    public static func package(for tool: String) -> ToolPackage? { catalog[tool]?[architecture] }

    /// Stet's own copy of a tool, if installed.
    public static func installed(_ tool: String) -> URL? {
        guard let package = package(for: tool) else { return nil }
        let binary = folder.appendingPathComponent("\(tool)-\(package.version)").appendingPathComponent(tool)
        return FileManager.default.isExecutableFile(atPath: binary.path) ? binary : nil
    }

    /// Bytes to download for these tools.
    public static func downloadSize(for tools: [String]) -> Int {
        tools.compactMap(package(for:)).reduce(0) { $0 + $1.size }
    }

    public enum InstallError: Error, LocalizedError, Equatable {
        case notAvailable(String)
        case download(String, String)
        case checksum(String)
        case unpack(String)
        case notWorking(String)

        public var errorDescription: String? {
            switch self {
            case .notAvailable(let tool): "Für \(tool) gibt es keine Version für diesen Mac."
            case .download(let tool, let detail): "\(tool) konnte nicht geladen werden: \(detail)"
            case .checksum(let tool): "Die geladene Datei von \(tool) ist nicht die erwartete (Prüfsumme stimmt nicht). Sie wurde verworfen."
            case .unpack(let tool): "\(tool) ließ sich nicht auspacken."
            case .notWorking(let tool): "\(tool) wurde geladen, startet aber nicht."
            }
        }
    }

    /// Fetches a URL into a temporary file, reporting progress from 0 to 1.
    public typealias Download = (URL, @escaping (Double) -> Void) async throws -> URL

    /// Installs the tools (skipping installed ones). Progress covers all of them, by size.
    public static func install(_ tools: [String], download: Download = urlSessionDownload,
                               progress: @escaping (Double) -> Void = { _ in }) async throws {
        let packages = try tools.filter { installed($0) == nil }.map { tool -> ToolPackage in
            guard let package = package(for: tool) else { throw InstallError.notAvailable(tool) }
            return package
        }
        let total = Double(max(1, packages.reduce(0) { $0 + $1.size }))
        var done = 0.0
        for package in packages {
            let base = done
            let archive: URL
            do {
                archive = try await download(package.url) { fraction in progress((base + fraction * Double(package.size)) / total) }
            } catch {
                throw InstallError.download(package.tool, error.localizedDescription)
            }
            defer { try? FileManager.default.removeItem(at: archive) }
            try place(package, from: archive)
            done += Double(package.size)
            progress(done / total)
        }
    }

    /// Checks, unpacks and installs one downloaded archive.
    static func place(_ package: ToolPackage, from archive: URL) throws {
        let fm = FileManager.default
        guard try sha256(of: archive) == package.sha256 else { throw InstallError.checksum(package.tool) }
        let unpacked = fm.temporaryDirectory.appendingPathComponent("stet-tool-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: unpacked) }
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
        let isZip = package.url.lastPathComponent.hasSuffix(".zip")
        let result = isZip
            ? try Tools.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", archive.path, unpacked.path])
            : try Tools.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xJf", archive.path, "-C", unpacked.path])
        let binary = unpacked.appendingPathComponent(package.binary)
        guard result.status == 0, fm.isExecutableFile(atPath: binary.path) else { throw InstallError.unpack(package.tool) }

        let target = folder.appendingPathComponent("\(package.tool)-\(package.version)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let staging = folder.appendingPathComponent(".\(package.tool)-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try fm.moveItem(at: binary, to: staging.appendingPathComponent(package.tool))
        for extra in package.extras where fm.fileExists(atPath: unpacked.appendingPathComponent(extra).path) {
            try fm.moveItem(at: unpacked.appendingPathComponent(extra), to: staging.appendingPathComponent((extra as NSString).lastPathComponent))
        }
        let installedBinary = staging.appendingPathComponent(package.tool)
        _ = try? Tools.run(URL(fileURLWithPath: "/usr/bin/xattr"), ["-d", "com.apple.quarantine", installedBinary.path])
        let check = try? Tools.run(installedBinary, ["--version"])
        guard let check, check.status == 0, check.text.contains(package.version) else {
            try? fm.removeItem(at: staging)
            throw InstallError.notWorking(package.tool)
        }
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.moveItem(at: staging, to: target)
    }

    /// Removes Stet's copies (Homebrew's are untouched).
    public static func uninstall() throws {
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func urlSessionDownload(_ url: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            var observation: NSKeyValueObservation?
            let task = URLSession.shared.downloadTask(with: url) { location, response, error in
                observation?.invalidate()
                if let error { return continuation.resume(throwing: error) }
                guard let location, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    return continuation.resume(throwing: URLError(.badServerResponse))
                }
                // The file is gone once this handler returns: keep it.
                let kept = FileManager.default.temporaryDirectory.appendingPathComponent("stet-download-\(UUID().uuidString)")
                do {
                    try FileManager.default.moveItem(at: location, to: kept)
                    continuation.resume(returning: kept)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            observation = task.progress.observe(\.fractionCompleted) { value, _ in progress(value.fractionCompleted) }
            task.resume()
        }
    }
}
