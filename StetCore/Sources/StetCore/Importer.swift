import Foundation
import Yams

/// Turns a folder of Markdown scenes into a `.stet` book.
///
/// Understands a `book.yaml` (chapters → scene names, metadata, cover, CSS); without one,
/// every `.md` file becomes a scene of a single chapter. If the folder is a git repository,
/// its whole history and other branches are kept: the book is a clone, and the conversion
/// is one ordinary commit on top. The source folder is never modified.
public enum Importer {
    public struct Report: Equatable {
        public var title = ""
        public var chapters = 0
        public var scenes = 0
        public var words = 0
        public var commitsKept = 0
        public var experiments: [String] = []
        /// Branches whose work is already in the main version; kept, but set aside.
        public var shelvedExperiments: [String] = []
        public var formerRemotes: [String] = []
        public var moved: [String] = []
        public var removed: [String] = []
        public var warnings: [String] = []
    }

    public enum ImportError: Error, LocalizedError {
        case noScenes(URL)
        case destinationExists(URL)

        public var errorDescription: String? {
            switch self {
            case .noScenes(let url): "In „\(url.lastPathComponent)“ wurden keine Markdown-Szenen gefunden."
            case .destinationExists(let url): "„\(url.lastPathComponent)“ existiert bereits."
            }
        }
    }

    /// Tooling of the old layout that Stet replaces. Removed in the conversion commit (still in history).
    static let replacedFiles: Set<String> = ["book.yaml", "build_book.py", "Makefile", "makefile", "README.md", ".gitignore"]

    public static func importFolder(_ source: URL, to destination: URL) async throws -> Report {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw ImportError.destinationExists(destination) }

        var report = Report()
        let sourceGit = Git(directory: source)
        // A repository whose top level is exactly this folder (an empty prefix).
        let isRepository = (try? await sourceGit.run(["rev-parse", "--show-prefix"]))?
            .string.trimmingCharacters(in: .whitespacesAndNewlines) == ""
        let git = Git(directory: destination)

        // 1. Copy, keeping history if there is one.
        if isRepository {
            try await Git(directory: destination.deletingLastPathComponent())
                .run(["clone", "--quiet", "--no-hardlinks", source.path, destination.path])
            report.experiments = try await carryOverBranches(from: sourceGit, into: git)
            report.formerRemotes = try await sourceGit.run(["remote", "-v"]).string
                .split(separator: "\n").filter { $0.hasSuffix("(push)") }
                .map { $0.replacingOccurrences(of: " (push)", with: "") }
            try await git.run(["remote", "remove", "origin"])
            // Uncommitted work in the source is carried over too (it ends up in the conversion commit).
            let dirty = try await sourceGit.run(["status", "--porcelain"]).string
            if !dirty.isEmpty {
                try await copyWorkingFiles(from: source, sourceGit: sourceGit, to: destination)
                report.warnings.append("Nicht gesicherte Änderungen aus dem Originalordner wurden mit übernommen.")
            }
            report.commitsKept = Int(try await git.run(["rev-list", "--count", "HEAD"]).string
                .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        } else {
            try fm.createDirectory(at: destination, withIntermediateDirectories: false)
            try await copyWorkingFiles(from: source, sourceGit: nil, to: destination)
            try await git.initRepository()
        }

        // 2. Convert the layout in the copy and save that as one version.
        var ids = IDMap()
        guard let summary = try await convertWorkingTree(destination, sourceName: source.lastPathComponent, ids: &ids, report: &report) else {
            try? fm.removeItem(at: destination)
            throw ImportError.noScenes(source)
        }
        report.title = summary.title
        report.chapters = summary.chapters
        report.scenes = summary.scenes
        report.words = summary.words

        // 3. Other branches: already merged ones are shelved; the rest become experiments,
        //    converted with the same scene and chapter IDs so they can be adopted later.
        if isRepository, !report.experiments.isEmpty {
            let main = await git.currentBranch() ?? "main"
            var active: [String] = []
            for name in report.experiments {
                let branch = Book.experimentPrefix + name
                let merged = try await git.run(["merge-base", "--is-ancestor", branch, "HEAD"], allowedStatus: [0, 1]).status == 0
                if merged {
                    try await git.run(["branch", "--move", branch, Book.shelvedPrefix + name])
                    report.shelvedExperiments.append(name)
                    continue
                }
                try await git.run(["switch", "--quiet", branch])
                if !fm.fileExists(atPath: destination.appendingPathComponent(Manifest.fileName).path) {
                    var branchReport = Report()
                    _ = try await convertWorkingTree(destination, sourceName: source.lastPathComponent, ids: &ids, report: &branchReport)
                }
                active.append(name)
            }
            try await git.run(["switch", "--quiet", main])
            report.experiments = active
        }
        return report
    }

    /// Scene and chapter IDs by name, shared between the conversions of all branches.
    struct IDMap {
        var scenes: [String: String] = [:]
        var chapters: [String: String] = [:]
        var all: Set<String> { Set(scenes.values).union(chapters.values) }

        mutating func scene(_ name: String) -> String {
            let key = name.precomposedStringWithCanonicalMapping
            if let id = scenes[key] { return id }
            let id = StetID.make(avoiding: all)
            scenes[key] = id
            return id
        }

        mutating func chapter(_ title: String) -> String {
            if let id = chapters[title] { return id }
            let id = StetID.make(prefix: "c", avoiding: all)
            chapters[title] = id
            return id
        }
    }

    /// Converts the checked-out tree into Stet's layout and commits it.
    /// Returns nil (and changes nothing) if there are no scenes.
    static func convertWorkingTree(_ destination: URL, sourceName: String, ids: inout IDMap, report: inout Report) async throws
        -> (title: String, chapters: Int, scenes: Int, words: Int)?
    {
        let fm = FileManager.default
        let config = readBookConfig(in: destination)
        let sceneFolderName = config?.sceneFolder ?? ""
        let sceneFolder = sceneFolderName.isEmpty ? destination : destination.appendingPathComponent(sceneFolderName)
        let available = markdownFiles(in: sceneFolder)
        var used = Set<String>()
        var structure: [StructureNode] = []
        var moves: [(file: String, title: String, id: String)] = []

        func plan(_ name: String) -> String? {
            guard let file = match(name, in: available), !used.contains(file) else {
                report.warnings.append("Szene „\(name)“ steht in book.yaml, die Datei fehlt.")
                return nil
            }
            used.insert(file)
            let id = ids.scene(name)
            moves.append((file, name, id))
            return id
        }

        if let config, !config.chapters.isEmpty {
            for chapter in config.chapters {
                let sceneIDs = chapter.scenes.compactMap(plan)
                structure.append(.chapter(Chapter(id: ids.chapter(chapter.title), title: chapter.title, sceneIDs: sceneIDs)))
            }
        }
        let leftovers = available.filter { !used.contains($0) && !(sceneFolderName.isEmpty && isRootDocument($0)) }
        if !leftovers.isEmpty {
            let title = structure.isEmpty ? "Kapitel 1" : "Nicht zugeordnet"
            let sceneIDs = leftovers.compactMap { plan(String($0.dropLast(3))) }
            structure.append(.chapter(Chapter(id: ids.chapter(title), title: title, sceneIDs: sceneIDs)))
            if config != nil, title != "Kapitel 1" {
                report.warnings.append("\(leftovers.count) Szene(n) standen in keinem Kapitel und liegen jetzt in „\(title)“.")
            }
        }
        guard !moves.isEmpty else { return nil }

        try fm.createDirectory(at: destination.appendingPathComponent(Book.scenesFolder), withIntermediateDirectories: true)
        for move in moves {
            try moveScene(file: sceneFolder.appendingPathComponent(move.file), title: move.title, id: move.id, into: destination, report: &report)
        }
        if !sceneFolderName.isEmpty, (try? fm.contentsOfDirectory(atPath: sceneFolder.path))?.filter({ $0 != ".DS_Store" }).isEmpty == true {
            try? fm.removeItem(at: sceneFolder)
        }

        var manifest = Manifest(
            title: config?.title ?? URL(fileURLWithPath: sourceName).deletingPathExtension().lastPathComponent,
            authors: config?.authors ?? [],
            language: config?.language ?? "de",
            structure: structure
        )
        try tidyRemainingFiles(in: destination, keep: [sceneFolderName], config: config, manifest: &manifest, report: &report)
        try Data(manifest.yaml().utf8).write(to: destination.appendingPathComponent(Manifest.fileName))
        try Book.writeGitignore(in: destination)

        let book = try Book(url: destination)
        let words = book.totalWords()
        let chapters = manifest.chapters.count, scenes = manifest.sceneIDs.count

        var body = ["Übernommen aus „\(sourceName)“: \(chapters) Kapitel, \(scenes) Szenen."]
        if !report.removed.isEmpty { body.append("Ersetzt durch Stet (bleiben in der Historie): " + report.removed.joined(separator: ", ")) }
        let message = "Nach Stet übernommen\n\n" + body.joined(separator: "\n") + "\n\nStet-Words: \(words)\nStet-Imported-From: \(sourceName)\n"
        let git = Git(directory: destination)
        let identity = await git.identityArguments(fallbackName: manifest.authors.first ?? "Stet")
        _ = try await git.commitAll(message: message, identity: identity)
        return (manifest.title, chapters, scenes, words)
    }

    // MARK: - book.yaml

    struct BookConfig {
        var sceneFolder: String
        var title: String?
        var authors: [String]
        var language: String?
        var cover: String?
        var css: String?
        var chapters: [(title: String, scenes: [String])]
    }

    static func readBookConfig(in folder: URL) -> BookConfig? {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("book.yaml"), encoding: .utf8),
              let root = try? Yams.compose(yaml: text)?.mapping
        else { return nil }
        let book = root["book"]?.mapping
        let metadata = root["metadata"]?.mapping
        let authors: [String] = metadata?["author"]?.string.map { [$0] } ?? metadata?["author"]?.sequence?.compactMap(\.string) ?? []
        let chapters: [(String, [String])] = root["chapters"]?.sequence?.compactMap { node in
            guard let map = node.mapping, let title = map["title"]?.string else { return nil }
            return (title, map["scenes"]?.sequence?.compactMap(\.string) ?? [])
        } ?? []
        return BookConfig(
            sceneFolder: book?["source"]?.string ?? "Szenen",
            title: metadata?["title"]?.string,
            authors: authors,
            language: metadata?["lang"]?.string,
            cover: book?["cover"]?.string,
            css: book?["css"]?.string,
            chapters: chapters
        )
    }

    // MARK: - Helpers

    static func markdownFiles(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".md") && !$0.hasPrefix(".") }
            .sorted { $0.precomposedStringWithCanonicalMapping < $1.precomposedStringWithCanonicalMapping }
    }

    /// Finds `name` or `name.md`, tolerating NFC/NFD differences in file names.
    static func match(_ name: String, in files: [String]) -> String? {
        let wanted = (name.lowercased().hasSuffix(".md") ? name : name + ".md").precomposedStringWithCanonicalMapping
        return files.first { $0.precomposedStringWithCanonicalMapping == wanted }
    }

    static func isRootDocument(_ file: String) -> Bool {
        ["readme.md", "license.md", "changelog.md"].contains(file.lowercased())
    }

    static func moveScene(file: URL, title: String, id: String, into book: URL, report: inout Report) throws {
        var text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        if text.contains("\r\n") {
            text = text.replacingOccurrences(of: "\r\n", with: "\n")
            report.warnings.append("„\(title)“: Windows-Zeilenumbrüche wurden in Mac-Zeilenumbrüche umgewandelt.")
        }
        let existing = SceneFile.parse(id: id, text: text)
        var scene = SceneFile(id: id, body: existing.body, title: existing.title ?? title)
        if existing.title != nil { scene = existing }
        try Data(scene.serialized().utf8).write(to: Book.sceneURL(id, in: book))
        try FileManager.default.removeItem(at: file)
    }

    static func tidyRemainingFiles(in book: URL, keep: Set<String>, config: BookConfig?, manifest: inout Manifest, report: inout Report) throws {
        let fm = FileManager.default
        let reserved: Set<String> = [".git", Book.scenesFolder, Manifest.fileName, ".DS_Store"]
        let entries = try fm.contentsOfDirectory(atPath: book.path).sorted()
        func move(_ name: String, to folder: String) throws -> String {
            let target = book.appendingPathComponent(folder)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            try fm.moveItem(at: book.appendingPathComponent(name), to: target.appendingPathComponent(name))
            report.moved.append("\(name) → \(folder)/\(name)")
            return "\(folder)/\(name)"
        }
        for name in entries where !reserved.contains(name) && !keep.contains(name) {
            let lower = name.lowercased()
            if replacedFiles.contains(name) {
                try fm.removeItem(at: book.appendingPathComponent(name))
                if name != ".gitignore" { report.removed.append(name) }
            } else if name == config?.cover || (config?.cover == nil && lower.hasPrefix("cover.")) {
                manifest.cover = try move(name, to: "assets")
            } else if name == config?.css || lower.hasSuffix(".css") {
                let path = try move(name, to: "assets")
                if manifest.epubCSS == nil { manifest.epubCSS = path }
            } else if lower.hasSuffix(".md") {
                _ = try move(name, to: "wiki")
            } else if ["jpg", "jpeg", "png", "gif", "webp", "heic", "svg"].contains((name as NSString).pathExtension.lowercased()) {
                _ = try move(name, to: "assets")
            } else {
                _ = try move(name, to: "imported")
            }
        }
    }

    /// Branches other than the current one become experiments (`experiments/<name>`).
    static func carryOverBranches(from source: Git, into git: Git) async throws -> [String] {
        let current = await source.currentBranch()
        let refs = await source.refs(matching: "refs/heads") + (await source.refs(matching: "refs/remotes"))
        var names: [String: String] = [:]  // short name → full source ref
        for ref in refs {
            let short: String
            if ref.hasPrefix("refs/heads/") {
                short = String(ref.dropFirst("refs/heads/".count))
            } else {
                let parts = ref.dropFirst("refs/remotes/".count).split(separator: "/", maxSplits: 1)
                guard parts.count == 2, parts[1] != "HEAD" else { continue }
                short = String(parts[1])
            }
            guard short != current, names[short] == nil || ref.hasPrefix("refs/heads/") else { continue }
            names[short] = ref
        }
        let specs = names.sorted { $0.key < $1.key }.map { "+\($0.value):refs/heads/experiments/\($0.key)" }
        guard !specs.isEmpty else { return [] }
        try await git.run(["fetch", "--quiet", "--no-tags", source.directory.path] + specs)
        return names.keys.sorted()
    }

    static func copyWorkingFiles(from source: URL, sourceGit: Git?, to destination: URL) async throws {
        let fm = FileManager.default
        let files: [String]
        if let sourceGit {
            files = try await sourceGit.run(["ls-files", "-z", "--cached", "--others", "--exclude-standard"]).string
                .split(separator: "\0").map(String.init)
        } else {
            let enumerator = fm.enumerator(atPath: source.path)
            files = (enumerator?.allObjects as? [String] ?? []).filter { path in
                var isDirectory: ObjCBool = false
                fm.fileExists(atPath: source.appendingPathComponent(path).path, isDirectory: &isDirectory)
                return !isDirectory.boolValue && !path.hasPrefix(".git/") && !path.hasSuffix(".DS_Store")
            }
        }
        for relative in files {
            let from = source.appendingPathComponent(relative)
            let to = destination.appendingPathComponent(relative)
            guard fm.fileExists(atPath: from.path) else {
                try? fm.removeItem(at: to)  // deleted in the working tree
                continue
            }
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
            try fm.copyItem(at: from, to: to)
        }
    }
}
