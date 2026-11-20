import Foundation

public enum BookError: Error, LocalizedError {
    case notABook(URL)
    case alreadyExists(URL)
    case missingScene(String)

    public var errorDescription: String? {
        switch self {
        case .notABook(let url): "„\(url.lastPathComponent)“ ist kein Stet-Buch (manuscript.yaml fehlt)."
        case .alreadyExists(let url): "„\(url.lastPathComponent)“ existiert bereits."
        case .missingScene(let id): "Die Szenendatei scenes/\(id).md fehlt."
        }
    }
}

/// An open `.stet` book: the package on disk plus its git repository.
///
/// Files are written in place, one at a time and only when their bytes changed, never by
/// replacing the whole package (which would copy the entire history on every save).
public final class Book {
    public static let fileExtension = "stet"
    public static let scenesFolder = "scenes"
    public static let localFolder = ".local"

    public let url: URL
    public let git: Git
    public private(set) var manifest: Manifest
    private var writtenManifestYAML: String

    // MARK: Opening and creating

    public init(url: URL) throws {
        let manifestURL = url.appendingPathComponent(Manifest.fileName)
        guard let yaml = try? String(contentsOf: manifestURL, encoding: .utf8) else {
            throw BookError.notABook(url)
        }
        self.url = url
        self.git = Git(directory: url)
        self.manifest = try Manifest.parse(yaml)
        self.writtenManifestYAML = yaml
        Self.markAsPackage(url)
    }

    /// Sets the Finder "bundle bit", so the book shows as a single file even on Macs where
    /// Stet (and with it the `.stet` type) isn't installed. It lives in an extended attribute:
    /// Finder copies, AirDrop and Time Machine keep it; git and most sync services don't.
    public static func markAsPackage(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isPackage = true
        try? target.setResourceValues(values)
    }

    /// Creates a new book with one chapter and one empty scene, and makes the first version.
    public static func create(at url: URL, title: String, author: String, language: String = "de") async throws -> Book {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else { throw BookError.alreadyExists(url) }
        try fm.createDirectory(at: url.appendingPathComponent(scenesFolder), withIntermediateDirectories: true)

        let sceneID = StetID.make()
        let chapter = Chapter(id: StetID.make(prefix: "c"), title: "Kapitel 1", sceneIDs: [sceneID])
        let manifest = Manifest(
            title: title,
            authors: author.isEmpty ? [] : [author],
            language: language,
            year: Calendar.current.component(.year, from: Date()),
            structure: [.chapter(chapter)]
        )
        try Data(manifest.yaml().utf8).write(to: url.appendingPathComponent(Manifest.fileName))
        try Data(SceneFile(id: sceneID).serialized().utf8).write(to: sceneURL(sceneID, in: url))
        try writeGitignore(in: url)

        let git = Git(directory: url)
        try await git.initRepository()
        let identity = await git.identityArguments(fallbackName: author.isEmpty ? "Stet" : author)
        _ = try await git.commitAll(message: "Neues Buch „\(title)“ angelegt\n\nStet-Words: 0\n", identity: identity)
        return try Book(url: url)
    }

    static func writeGitignore(in url: URL) throws {
        try Data("# Per-device state (cursor, window, display settings)\n\(localFolder)/\n.DS_Store\n".utf8)
            .write(to: url.appendingPathComponent(".gitignore"))
    }

    // MARK: Scenes

    static func sceneURL(_ id: String, in bookURL: URL) -> URL {
        bookURL.appendingPathComponent(scenesFolder).appendingPathComponent("\(id).md")
    }

    public static func scenePath(_ id: String) -> String { "\(scenesFolder)/\(id).md" }

    public func sceneURL(_ id: String) -> URL { Self.sceneURL(id, in: url) }

    public func readScene(_ id: String) throws -> SceneFile {
        guard let data = FileManager.default.contents(atPath: sceneURL(id).path) else {
            throw BookError.missingScene(id)
        }
        return SceneFile.parse(id: id, text: String(decoding: data, as: UTF8.self))
    }

    /// Writes the scene only if its bytes differ from what's on disk. Returns true if written.
    @discardableResult
    public func writeScene(_ scene: SceneFile) throws -> Bool {
        let data = Data(scene.serialized().utf8)
        let target = sceneURL(scene.id)
        if FileManager.default.contents(atPath: target.path) == data { return false }
        try data.write(to: target, options: .atomic)
        return true
    }

    /// Scene files in scenes/ that the manifest doesn't mention.
    public func unplacedSceneIDs() -> [String] {
        let folder = url.appendingPathComponent(Self.scenesFolder)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let known = Set(manifest.sceneIDs)
        return files.filter { $0.hasSuffix(".md") }
            .map { String($0.dropLast(3)) }
            .filter { !known.contains($0) }
            .sorted()
    }

    // MARK: Structure

    public func updateManifest(_ change: (inout Manifest) -> Void) throws {
        change(&manifest)
        try saveManifest()
    }

    func replaceManifest(_ manifest: Manifest, yaml: String) {
        self.manifest = manifest
        self.writtenManifestYAML = yaml
    }

    private func saveManifest() throws {
        let yaml = manifest.yaml()
        guard yaml != writtenManifestYAML else { return }
        try Data(yaml.utf8).write(to: url.appendingPathComponent(Manifest.fileName), options: .atomic)
        writtenManifestYAML = yaml
    }

    /// Adds an empty scene to `chapterID`, after `afterSceneID` (or at the end).
    public func addScene(toChapter chapterID: String, after afterSceneID: String? = nil) throws -> SceneFile {
        let scene = SceneFile(id: StetID.make(avoiding: manifest.allIDs.union(unplacedSceneIDs())))
        try writeScene(scene)
        if !FileManager.default.fileExists(atPath: sceneURL(scene.id).path) {
            try Data().write(to: sceneURL(scene.id))
        }
        try updateManifest { manifest in
            let index = manifest.chapter(withID: chapterID)?.sceneIDs.firstIndex { $0 == afterSceneID }.map { $0 + 1 }
            manifest.moveScene(scene.id, toChapter: chapterID, at: index ?? .max)
        }
        return scene
    }

    public func addChapter(title: String, after afterChapterID: String?) throws -> Chapter {
        let sceneID = StetID.make(avoiding: manifest.allIDs.union(unplacedSceneIDs()))
        try Data().write(to: sceneURL(sceneID))
        let chapter = Chapter(id: StetID.make(prefix: "c", avoiding: manifest.allIDs), title: title, sceneIDs: [sceneID])
        try updateManifest { $0.insertChapter(chapter, after: afterChapterID) }
        return chapter
    }

    /// Removes a scene from the book. The file is deleted; every saved version stays in the history.
    public func deleteScene(_ id: String) throws {
        try updateManifest { $0.removeScene(id) }
        try? FileManager.default.removeItem(at: sceneURL(id))
    }

    // MARK: Words

    public func words(ofScene id: String) -> Int {
        (try? readScene(id)).map { TextStats.words(in: $0.body) } ?? 0
    }

    public func totalWords() -> Int {
        manifest.sceneIDs.reduce(0) { $0 + words(ofScene: $1) }
    }
}

// MARK: - Saving versions

extension Book {
    public struct SaveResult: Equatable {
        public let commit: String
        public let subject: String
        public let wordsDelta: Int
    }

    /// Commits everything as a new version. Returns nil when nothing changed since the last one.
    /// `subject` replaces the generated description (the word delta is still appended).
    public func saveVersion(activeMinutes: Int? = nil, subject customSubject: String? = nil, extraTrailers: [String] = []) async throws -> SaveResult? {
        guard await git.resolve("MERGE_HEAD") == nil else { throw ExperimentError.adoptionInProgress }
        let changed = try await git.changedPaths()
        guard !changed.isEmpty else { return nil }

        var edited: [String] = [], added: [String] = [], removed: [String] = []
        var delta = 0
        var structureChanged = false
        var feedbackChanged = false
        var wikiChanged = false
        var signersChanged = false
        var touchedScenes: [String] = []

        var wordsChanged = false
        for path in Set(changed).sorted() {
            if path == Manifest.fileName {
                // Only the spelling word list changed? Then say so instead of "Struktur geändert".
                let before = await git.show(Manifest.fileName, at: "HEAD").flatMap { try? Manifest.parse(String(decoding: $0, as: UTF8.self)) }
                var comparable = manifest
                comparable.words = before?.words
                if let before, comparable == before { wordsChanged = true } else { structureChanged = true }
                continue
            }
            if path.hasPrefix(FeedbackEntry.folder + "/") { feedbackChanged = true; continue }
            if path.hasPrefix(WikiEntry.folder + "/") { wikiChanged = true; continue }
            if path.hasPrefix(Self.signersFolder + "/") { signersChanged = true; continue }
            guard path.hasPrefix(Self.scenesFolder + "/"), path.hasSuffix(".md") else { continue }
            let id = String(path.dropFirst(Self.scenesFolder.count + 1).dropLast(3))
            touchedScenes.append(id)

            let before = await git.show(path, at: "HEAD").map { SceneFile.parse(id: id, text: String(decoding: $0, as: UTF8.self)) }
            let now = try? readScene(id)
            delta += (now.map { TextStats.words(in: $0.body) } ?? 0) - (before.map { TextStats.words(in: $0.body) } ?? 0)

            switch (before, now) {
            case (nil, let now?): added.append(now.displayTitle)
            case (let before?, nil): removed.append(before.displayTitle)
            case (_, let now?): edited.append(now.displayTitle)
            default: break
            }
        }

        var parts: [String] = []
        if !edited.isEmpty { parts.append("Bearbeitet: " + Self.list(edited)) }
        if !added.isEmpty { parts.append("Neu: " + Self.list(added)) }
        if !removed.isEmpty { parts.append("Entfernt: " + Self.list(removed)) }
        if structureChanged { parts.append("Struktur geändert") }
        if feedbackChanged { parts.append("Feedback") }
        if wikiChanged { parts.append("Wiki") }
        if signersChanged { parts.append("Signatur-Schlüssel") }
        if wordsChanged { parts.append("Wörterbuch") }
        if parts.isEmpty { parts.append("Sonstige Änderungen") }
        if let customSubject { parts = [customSubject] }
        if delta != 0 { parts.append(Self.signed(delta) + " Wörter") }
        let subject = parts.joined(separator: " · ")

        var trailers = ["Stet-Words: \(totalWords())", "Stet-Words-Delta: \(Self.signed(delta))"]
        if let activeMinutes, activeMinutes > 0 { trailers.append("Stet-Active-Minutes: \(activeMinutes)") }
        if !touchedScenes.isEmpty { trailers.append("Stet-Scenes: \(touchedScenes.joined(separator: ","))") }
        trailers += extraTrailers

        let identity = await git.identityArguments(fallbackName: manifest.authors.first ?? "Stet")
        let commit = try await git.commitAll(message: subject + "\n\n" + trailers.joined(separator: "\n") + "\n", identity: identity)
        return SaveResult(commit: commit, subject: subject, wordsDelta: delta)
    }

    public static func list(_ titles: [String]) -> String {
        let quoted = titles.map { "„\($0)“" }
        guard quoted.count > 3 else { return quoted.joined(separator: ", ") }
        return quoted.prefix(2).joined(separator: ", ") + " und \(quoted.count - 2) weitere"
    }

    static func signed(_ n: Int) -> String { n > 0 ? "+\(n)" : "\(n)" }
}

// MARK: - Safety-net snapshots

extension Book {
    public static func snapshotRef(device: String) -> String { "refs/stet/snapshots/\(device)" }

    /// Records the working tree on a hidden per-device ref without touching the real index,
    /// branch or visible history. Returns the snapshot commit, or nil if nothing is new.
    @discardableResult
    public func snapshot(device: String) async throws -> String? {
        guard let head = await git.headCommit() else { return nil }
        let ref = Self.snapshotRef(device: device)
        let index = FileManager.default.temporaryDirectory.appendingPathComponent("stet-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: index) }
        let env = ["GIT_INDEX_FILE": index.path]

        try await git.run(["read-tree", "HEAD"], environment: env)
        try await git.run(["add", "--all"], environment: env)
        let tree = try await git.run(["write-tree"], environment: env).string.trimmingCharacters(in: .whitespacesAndNewlines)

        let headTree = await git.resolve("HEAD^{tree}")
        let previous = await git.resolve(ref)
        let previousTree = await git.resolve("\(ref)^{tree}")
        if tree == headTree || tree == previousTree { return nil }

        // Chain snapshots while HEAD stays the same; restart from HEAD after a new version.
        var parent = head
        if let previous, (try? await git.run(["merge-base", "--is-ancestor", head, previous], allowedStatus: [0, 1]))?.status == 0 {
            parent = previous
        }
        let identity = await git.identityArguments(fallbackName: manifest.authors.first ?? "Stet", sign: false)
        let commit = try await git.run(
            identity + ["commit-tree", tree, "-p", parent, "-F", "-"],
            input: Data("Schnappschuss\n\nStet-Snapshot: \(device)\n".utf8)
        ).string.trimmingCharacters(in: .whitespacesAndNewlines)
        try await git.run(["update-ref", ref, commit])
        return commit
    }
}

// MARK: - Scene history

extension Book {
    public struct SceneVersion: Identifiable, Equatable {
        public let commit: Git.Commit
        public let path: String
        public let isSnapshot: Bool
        public var id: String { commit.hash + (isSnapshot ? "-s" : "") }
    }

    /// Saved versions of a scene, newest first, following renames (e.g. from before an import),
    /// plus this device's snapshots that are newer than the last version.
    public func history(ofScene id: String, device: String? = nil) async throws -> [SceneVersion] {
        let path = Self.scenePath(id)
        let versions = try await git.log("HEAD", path: path).map {
            SceneVersion(commit: $0, path: $0.path ?? path, isSnapshot: false)
        }
        guard let device, await git.resolve(Self.snapshotRef(device: device)) != nil else { return versions }
        let snapshots = try await git.log("HEAD.." + Self.snapshotRef(device: device), path: path, follow: false).map {
            SceneVersion(commit: $0, path: $0.path ?? path, isSnapshot: true)
        }
        return snapshots + versions
    }

    /// The scene's prose as it was in `version`.
    public func text(of version: SceneVersion) async -> String? {
        guard let data = await git.show(version.path, at: version.commit.hash) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        // Files from before the import have no front matter; parse handles both.
        return SceneFile.parse(id: "", text: text).body
    }
}

// MARK: - Spelling word list

extension Manifest {
    /// Alphabetical, ignoring case and accents; no duplicates.
    static func sortedWords(_ words: [String]) -> [String] {
        var seen = Set<String>()
        return words.filter { seen.insert($0).inserted }
            .sorted { $0.compare($1, options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de")) == .orderedAscending }
    }
}

extension Book {
    /// Adds a word to the book's spelling word list (it travels with the book).
    public func allowWord(_ word: String) throws {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !(manifest.words ?? []).contains(trimmed) else { return }
        try updateManifest { $0.words = Manifest.sortedWords(($0.words ?? []) + [trimmed]) }
    }

    public func disallowWord(_ word: String) throws {
        try updateManifest { manifest in
            let rest = (manifest.words ?? []).filter { $0 != word }
            manifest.words = rest.isEmpty ? nil : rest
        }
    }
}
