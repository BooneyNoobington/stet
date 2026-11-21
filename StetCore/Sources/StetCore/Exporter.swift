import Foundation

public enum ExportError: Error, LocalizedError {
    case missingTools([String])
    case toolFailed(String, String)
    case missingResource(String)

    public var errorDescription: String? {
        switch self {
        case .missingTools(let tools):
            "Für diesen Export fehlt \(tools.joined(separator: " und ")). Im Terminal installieren mit: brew install \(tools.joined(separator: " "))"
        case .toolFailed(let tool, let detail):
            "\(tool) ist beim Export gescheitert: \(detail)"
        case .missingResource(let name):
            "Die Vorlage „\(name)“ fehlt in Stet."
        }
    }
}

public struct ExportResult: Equatable {
    public let file: URL
    public let stamp: ExportStamp
    public let tag: String
}

/// Turns a book into PDF (Typst), ePUB, docx, odt (Pandoc) or one Markdown file.
///
/// Pending changes are saved as a version first, so the stamp in the document names exactly
/// the text it contains; afterwards an `export/…` tag marks that version in the history.
public enum Exporter {
    public static var searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    /// Stet's own copy first (see ExportTools), then Homebrew and the PATH.
    public static func tool(_ name: String) -> URL? {
        if let own = ExportTools.installed(name) { return own }
        let path = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        for folder in searchPaths + path {
            let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    public static func missingTools(for format: ExportFormat) -> [String] {
        var missing: [String] = []
        if format.needsPandoc, tool("pandoc") == nil { missing.append("pandoc") }
        if format.needsTypst, tool("typst") == nil { missing.append("typst") }
        return missing
    }

    static func resource(_ name: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources") else {
            throw ExportError.missingResource(name)
        }
        return url
    }

    @discardableResult
    public static func export(_ book: Book, options: ExportOptions, to destination: URL) async throws -> ExportResult {
        let missing = missingTools(for: options.format)
        guard missing.isEmpty else { throw ExportError.missingTools(missing) }

        _ = try await book.saveVersion()
        let stamp = ExportStamp(
            commit: await book.git.headCommit() ?? "",
            date: Date(),
            versionName: await book.displayName(ofBranch: await book.currentBranch()),
            words: book.totalWords()
        )

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("stet-export-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let hasParts = book.manifest.structure.contains { if case .part = $0 { return true } else { return false } }
        var extra: [String: String] = [:]
        if hasParts { extra["stet-has-parts"] = "true" }
        let cover = book.manifest.cover.map { book.url.appendingPathComponent($0) }.flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil }
        if let cover, options.format == .pdfBook {
            let name = "cover." + cover.pathExtension.lowercased()
            try fm.copyItem(at: cover, to: work.appendingPathComponent(name))
            extra["stet-cover"] = name
        }

        let markdown = CombinedMarkdown.build(book, options: options, stamp: stamp, extra: extra)
        let source = work.appendingPathComponent("buch.md")
        try Data(markdown.utf8).write(to: source)
        let output = work.appendingPathComponent("ausgabe." + options.format.fileExtension)
        try fm.copyItem(at: try resource("stet.lua"), to: work.appendingPathComponent("stet.lua"))
        let pandoc = ["--from=markdown-smart", "--wrap=none", "--lua-filter=stet.lua", "buch.md"]

        switch options.format {
        case .markdown:
            try fm.copyItem(at: source, to: output)

        case .pdfManuscript, .pdfBook:
            let template = options.format == .pdfBook ? "book.typ" : "manuscript.typ"
            try fm.copyItem(at: try resource(template), to: work.appendingPathComponent("vorlage.typ"))
            try await run("pandoc", pandoc + ["--to=typst", "--template=vorlage.typ", "--output=buch.typ"], in: work)
            try await run("typst", ["compile", "--root", work.path, "buch.typ", output.lastPathComponent], in: work)

        case .epub:
            var css = ""
            if let own = book.manifest.epubCSS.map({ book.url.appendingPathComponent($0) }),
               let text = try? String(contentsOf: own, encoding: .utf8)
            {
                css += text + "\n"
            }
            css += try String(contentsOf: try resource("epub.css"), encoding: .utf8)
            try Data(css.utf8).write(to: work.appendingPathComponent("stil.css"))
            var args = pandoc + [
                "--to=epub3", "--toc", "--toc-depth=\(hasParts ? 2 : 1)", "--split-level=\(hasParts ? 2 : 1)",
                "--css=stil.css", "--output=\(output.lastPathComponent)",
            ]
            if let cover { args.append("--epub-cover-image=\(cover.path)") }
            try await run("pandoc", args, in: work)

        case .docx:
            try fm.copyItem(at: try resource("reference.docx"), to: work.appendingPathComponent("vorlage.docx"))
            try await run("pandoc", pandoc + ["--to=docx", "--reference-doc=vorlage.docx", "--output=\(output.lastPathComponent)"], in: work)

        case .odt:
            try await run("pandoc", pandoc + ["--to=odt", "--output=\(output.lastPathComponent)"], in: work)
        }

        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: output, to: destination)

        let tag = try await book.tagExport(options.format, fileName: destination.lastPathComponent)
        return ExportResult(file: destination, stamp: stamp, tag: tag)
    }

    static func run(_ name: String, _ arguments: [String], in folder: URL) async throws {
        guard let executable = tool(name) else { throw ExportError.missingTools([name]) }
        let result: (Int32, String) = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.currentDirectoryURL = folder
                var env = ProcessInfo.processInfo.environment
                let own = ["pandoc", "typst"].compactMap { ExportTools.installed($0)?.deletingLastPathComponent().path }
                env["PATH"] = (own + searchPaths + [env["PATH"] ?? ""]).joined(separator: ":")
                process.environment = env
                let errors = Pipe()
                process.standardError = errors
                process.standardOutput = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let data = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
        guard result.0 == 0 else {
            let lines = result.1.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            throw ExportError.toolFailed(name, lines.suffix(6).joined(separator: "\n"))
        }
    }
}

extension Book {
    public static let exportPrefix = "export/"

    /// Marks the exported version: annotated tag `export/<date>-<format>`.
    func tagExport(_ format: ExportFormat, fileName: String) async throws -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let slug = "\(formatter.string(from: Date()))-\(format.tagName)"
        let name = Self.exportPrefix + (await uniqueRefName(prefix: Self.exportPrefix, slug: slug, namespace: ["tags/" + Self.exportPrefix]))
        let message = "Export: \(format.label)\n\nDatei: \(fileName)\n"
        let identity = await git.identityArguments(fallbackName: manifest.authors.first ?? "Stet")
        try await git.run(identity + ["tag", "--annotate", "--file=-", name, "HEAD"], input: Data(message.utf8))
        return name
    }
}
