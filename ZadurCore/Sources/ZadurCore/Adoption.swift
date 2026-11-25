import Foundation

// MARK: - Three-way merge of the book structure

extension Manifest {
    /// Merges two edited versions of a manifest against their common ancestor, the way a writer
    /// would expect: each side's additions, removals, moves and renames are kept. Where both
    /// sides changed the same field, the main version (`ours`) wins.
    public static func merge(base: Manifest?, ours: Manifest, theirs: Manifest) -> Manifest {
        // Without a common ancestor (both sides created the file, e.g. two imported branches),
        // assume only what both share was there before: nothing gets lost.
        let base = base ?? commonPart(ours, theirs)
        func pick<T: Equatable>(_ b: T, _ o: T, _ t: T) -> T { o == b ? t : o }

        var result = ours
        result.title = pick(base.title, ours.title, theirs.title)
        result.authors = pick(base.authors, ours.authors, theirs.authors)
        result.language = pick(base.language, ours.language, theirs.language)
        result.year = pick(base.year, ours.year, theirs.year)
        result.cover = pick(base.cover, ours.cover, theirs.cover)
        result.epubCSS = pick(base.epubCSS, ours.epubCSS, theirs.epubCSS)
        result.factFields = pick(base.factFields, ours.factFields, theirs.factFields)
        result.wordGoal = pick(base.wordGoal, ours.wordGoal, theirs.wordGoal)
        // Both sides' new words are kept (and both sides' removals).
        let mergedWords = mergeList(base: base.words ?? [], ours: ours.words ?? [], theirs: theirs.words ?? [])
        result.words = mergedWords.isEmpty ? nil : Manifest.sortedWords(mergedWords)

        func nodes(_ m: Manifest) -> [String: StructureNode] {
            Dictionary(m.structure.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        let (b, o, t) = (nodes(base), nodes(ours), nodes(theirs))

        func mergeChapter(_ b: Chapter?, _ o: Chapter?, _ t: Chapter?) -> Chapter? {
            guard let any = o ?? t else { return nil }
            return Chapter(
                id: any.id,
                title: pick(b?.title ?? any.title, o?.title ?? any.title, t?.title ?? any.title),
                sceneIDs: mergeList(base: b?.sceneIDs ?? [], ours: o?.sceneIDs ?? [], theirs: t?.sceneIDs ?? []),
                facts: pick(b?.facts ?? any.facts, o?.facts ?? any.facts, t?.facts ?? any.facts)
            )
        }

        let order = mergeList(base: base.structure.map(\.id), ours: ours.structure.map(\.id), theirs: theirs.structure.map(\.id))
        result.structure = order.compactMap { id -> StructureNode? in
            switch (b[id], o[id], t[id]) {
            case (_, .part(let op)?, _), (_, nil, .part(let op)?):
                let bp: Part? = { if case .part(let p)? = b[id] { return p }; return nil }()
                let opart: Part? = { if case .part(let p)? = o[id] { return p }; return nil }()
                let tp: Part? = { if case .part(let p)? = t[id] { return p }; return nil }()
                func chapters(_ p: Part?) -> [String: Chapter] { Dictionary((p?.chapters ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }
                let chapterOrder = mergeList(base: bp?.chapters.map(\.id) ?? [], ours: opart?.chapters.map(\.id) ?? [], theirs: tp?.chapters.map(\.id) ?? [])
                let merged = chapterOrder.compactMap { mergeChapter(chapters(bp)[$0], chapters(opart)[$0], chapters(tp)[$0]) }
                return .part(Part(id: id, title: pick(bp?.title ?? op.title, opart?.title ?? op.title, tp?.title ?? op.title), chapters: merged,
                                  facts: pick(bp?.facts ?? op.facts, opart?.facts ?? op.facts, tp?.facts ?? op.facts)))
            default:
                func chapter(_ n: StructureNode?) -> Chapter? { if case .chapter(let c)? = n { return c }; return nil }
                return mergeChapter(chapter(b[id]), chapter(o[id]), chapter(t[id])).map(StructureNode.chapter)
            }
        }

        // A scene moved to different places on both sides ends up once, at its first place.
        var seen = Set<String>()
        for chapter in result.chapters {
            let unique = chapter.sceneIDs.filter { seen.insert($0).inserted }
            if unique != chapter.sceneIDs { result.updateChapter(chapter.id) { $0.sceneIDs = unique } }
        }
        return result
    }

    /// What two manifests share: their common chapters (by ID) with their common scenes, in `a`'s order.
    static func commonPart(_ a: Manifest, _ b: Manifest) -> Manifest {
        var common = a
        let bWords = Set(b.words ?? [])
        common.words = a.words?.filter { bWords.contains($0) }
        let bChapters = Dictionary(b.chapters.map { ($0.id, Set($0.sceneIDs)) }, uniquingKeysWith: { x, _ in x })
        let bNodes = Set(b.structure.map(\.id))
        common.structure = a.structure.filter { bNodes.contains($0.id) }.map { node in
            func shared(_ c: Chapter) -> Chapter {
                var c = c
                c.sceneIDs = c.sceneIDs.filter { bChapters[c.id]?.contains($0) == true }
                return c
            }
            switch node {
            case .chapter(let c): return .chapter(shared(c))
            case .part(var p):
                p.chapters = p.chapters.filter { bChapters[$0.id] != nil }.map(shared)
                return .part(p)
            }
        }
        return common
    }

    /// Three-way merge of an ordered list of IDs: keeps both sides' additions (at their place)
    /// and removals; if only one side reordered, its order wins.
    static func mergeList(base: [String], ours: [String], theirs: [String]) -> [String] {
        if ours == base { return theirs }
        if theirs == base { return ours }
        let baseSet = Set(base), theirSet = Set(theirs)
        var result = ours.filter { !(baseSet.contains($0) && !theirSet.contains($0)) }
        for (index, id) in theirs.enumerated() where !baseSet.contains(id) && !result.contains(id) {
            let predecessor = theirs[..<index].reversed().first { result.contains($0) }
            let position = predecessor.flatMap { result.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            result.insert(id, at: position)
        }
        return result
    }
}

extension Manifest {
    /// Adds a scene where `other` has it (after the same predecessor, in the same chapter),
    /// or at the end of the last chapter if that chapter doesn't exist here.
    public mutating func place(_ id: String, like other: Manifest?) {
        if let chapter = other?.chapter(containing: id), let ours = self.chapter(withID: chapter.id) {
            let order = chapter.sceneIDs
            let predecessor = order[..<(order.firstIndex(of: id) ?? 0)].reversed().first { ours.sceneIDs.contains($0) }
            let position = predecessor.flatMap { ours.sceneIDs.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            moveScene(id, toChapter: chapter.id, at: position)
        } else if let last = chapters.last {
            moveScene(id, toChapter: last.id, at: .max)
        }
    }
}

extension StructureNode {
    public var id: String {
        switch self {
        case .chapter(let c): c.id
        case .part(let p): p.id
        }
    }
}

// MARK: - Conflicts

/// A file with conflict markers, split into agreed text and places where both sides differ.
public enum ConflictSegment: Equatable {
    case same(String)
    case conflict(main: String, experiment: String)

    /// Parses git's conflict markers; nil if there are none (or they're malformed).
    public static func parse(_ text: String) -> [ConflictSegment]? {
        enum State { case normal, main, base, experiment }
        var segments: [ConflictSegment] = []
        var same = "", main = "", experiment = ""
        var state = State.normal
        var found = false
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            let full = String(line) + (index < lines.count - 1 ? "\n" : "")
            switch state {
            case .normal:
                if line.hasPrefix("<<<<<<<") {
                    if !same.isEmpty { segments.append(.same(same)); same = "" }
                    state = .main
                    found = true
                } else {
                    same += full
                }
            case .main:
                if line.hasPrefix("|||||||") { state = .base }
                else if line == "=======" { state = .experiment }
                else { main += full }
            case .base:
                if line == "=======" { state = .experiment }
            case .experiment:
                if line.hasPrefix(">>>>>>>") {
                    segments.append(.conflict(main: main, experiment: experiment))
                    main = ""; experiment = ""
                    state = .normal
                } else {
                    experiment += full
                }
            }
        }
        guard found, state == .normal else { return nil }
        if !same.isEmpty { segments.append(.same(same)) }
        return segments
    }
}

public struct MergeConflict: Identifiable, Equatable {
    public enum Kind: Equatable {
        /// Both sides changed the same paragraphs.
        case text([ConflictSegment])
        /// Deleted in the main version, edited in the experiment.
        case deletedInMain
        /// Edited in the main version, deleted in the experiment.
        case deletedInExperiment
        /// Can't be merged line by line (e.g. an image): pick one side.
        case whole
    }

    public let path: String
    public let kind: Kind
    public var id: String { path }

    public var sceneID: String? {
        guard path.hasPrefix(Book.scenesFolder + "/"), path.hasSuffix(".md") else { return nil }
        return String(path.dropFirst(Book.scenesFolder.count + 1).dropLast(3))
    }
}

public enum ConflictResolution: Equatable {
    case text(String)
    case keep
    case delete
    case main
    case experiment
}

public enum AdoptionResult: Equatable {
    case adopted(commit: String)
    case conflicts([MergeConflict])
    case nothingNew
}

// MARK: - Adopting experiments

extension Book {
    private var adoptionMarkerURL: URL { url.appendingPathComponent(".git/STET_ADOPTING") }

    /// What is being merged, if a merge (adoption or server sync) was started and not yet finished
    /// or cancelled. `fromServer` is true when the main version is being merged with the server's.
    public func adoptionInProgress() async -> (branch: String, name: String, fromServer: Bool)? {
        guard await git.resolve("MERGE_HEAD") != nil else { return nil }
        let marker = (try? String(contentsOf: adoptionMarkerURL, encoding: .utf8)) ?? "?"
        let branch = marker.split(separator: "\n").first.map(String.init) ?? "?"
        let fromServer = branch.hasPrefix(Self.remoteName + "/")
        return (branch, fromServer ? "Server" : await displayName(ofBranch: branch), fromServer)
    }

    /// Merges an experiment into the main version. Pending changes are saved as versions first.
    /// Structure (manuscript.yaml) is merged by Zadur; what's left for the writer comes back as conflicts.
    public func adopt(_ branch: String) async throws -> AdoptionResult {
        guard await git.resolve("refs/heads/\(branch)") != nil else { throw ExperimentError.noSuchVersion(branch) }
        return try await merge(branch)
    }

    /// Merges `ref` (a local branch, or the server's main version) into the main version.
    func merge(_ branch: String) async throws -> AdoptionResult {
        guard await adoptionInProgress() == nil else { throw ExperimentError.adoptionInProgress }
        guard await git.resolve(branch) != nil else { throw ExperimentError.noSuchVersion(branch) }
        let main = await mainBranch()
        if await currentBranch() != main { try await switchTo(main) } else { _ = try await saveVersion() }

        let contained = try await git.run(["merge-base", "--is-ancestor", branch, "HEAD"], allowedStatus: [0, 1])
        if contained.status == 0 { return .nothingNew }
        let base = try await git.run(["merge-base", "HEAD", branch]).string.trimmingCharacters(in: .whitespacesAndNewlines)

        try Data(branch.utf8).write(to: adoptionMarkerURL)
        let identity = await git.identityArguments(fallbackName: manifest.authors.first ?? "Zadur")
        try await git.run(identity + ["merge", "--no-ff", "--no-commit", "--quiet", branch], allowedStatus: [0, 1])
        guard await git.resolve("MERGE_HEAD") != nil else {
            try? FileManager.default.removeItem(at: adoptionMarkerURL)
            throw GitError(arguments: ["merge"], status: 1, stderr: "git hat die Übernahme nicht begonnen")
        }
        try await mergeManifest(base: base, branch: branch)
        try await mergeScenesSeparately()

        let conflicts = try await currentConflicts()
        if conflicts.isEmpty { return .adopted(commit: try await finishAdoption()) }
        return .conflicts(conflicts)
    }

    /// If both sides changed the structure, replace git's text merge with a structural one.
    private func mergeManifest(base: String, branch: String) async throws {
        func manifest(at revision: String) async -> Manifest? {
            guard let data = await git.show(Manifest.fileName, at: revision) else { return nil }
            return try? Manifest.parse(String(decoding: data, as: UTF8.self))
        }
        let b = await manifest(at: base)
        guard let o = await manifest(at: "HEAD"), let t = await manifest(at: branch) else { return }
        if o != b && t != b {
            let merged = Manifest.merge(base: b, ours: o, theirs: t)
            try Data(merged.yaml().utf8).write(to: url.appendingPathComponent(Manifest.fileName), options: .atomic)
            try await git.run(["add", "--", Manifest.fileName])
        }
        try reload()
    }

    /// For conflicted scenes, merges the front matter and the prose on their own. The title block
    /// sits right above the first paragraph, so a title change on one side and an edit of the
    /// opening on the other would otherwise collide. What still conflicts is then only prose.
    private func mergeScenesSeparately() async throws {
        for conflict in try await currentConflicts() {
            guard case .text = conflict.kind, let id = conflict.sceneID else { continue }
            func stage(_ n: Int) async -> SceneFile? {
                await git.show(conflict.path, at: ":\(n)").map { SceneFile.parse(id: id, text: String(decoding: $0, as: UTF8.self)) }
            }
            guard let ours = await stage(2), let theirs = await stage(3) else { continue }
            var base = await stage(1)
            if base == nil, let title = ours.title ?? theirs.title {
                base = await preZadurVersion(ofSceneTitled: title, id: id)
            }

            var merged = SceneFile.mergingFrontMatter(base: base, ours: ours, theirs: theirs)
            var clean = true
            if ours.body == theirs.body || base?.body == theirs.body {
                merged.body = ours.body
            } else if base?.body == ours.body {
                merged.body = theirs.body
            } else {
                (merged.body, clean) = try await mergeText(base: base?.body ?? "", ours: ours.body, theirs: theirs.body)
            }
            try Data(merged.serialized().utf8).write(to: url.appendingPathComponent(conflict.path), options: .atomic)
            if clean { try await git.run(["add", "--", conflict.path]) }
        }
    }

    /// Both sides of a merge may have converted the same pre-Zadur file into a scene (two imported
    /// branches). When git doesn't pair them up as a rename (small files), the common ancestor is
    /// the old file named after the scene's title, e.g. `Szenen/Ankunft.md`.
    private func preZadurVersion(ofSceneTitled title: String, id: String) async -> SceneFile? {
        guard let base = try? await git.run(["merge-base", "HEAD", "MERGE_HEAD"]).string
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let files = try? await git.run(["ls-tree", "-r", "-z", "--name-only", base]).string
        else { return nil }
        let wanted = (title + ".md").precomposedStringWithCanonicalMapping
        let candidates = files.split(separator: "\0").map(String.init).filter {
            URL(fileURLWithPath: $0).lastPathComponent.precomposedStringWithCanonicalMapping == wanted
        }
        guard candidates.count == 1, let data = await git.show(candidates[0], at: base) else { return nil }
        return SceneFile.parse(id: id, text: String(decoding: data, as: UTF8.self))
    }

    /// Line (= paragraph) based three-way merge of two texts; markers where they collide.
    private func mergeText(base: String, ours: String, theirs: String) async throws -> (String, Bool) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zadur-merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = [("ours", ours), ("base", base), ("theirs", theirs)].map { name, text -> String in
            let file = folder.appendingPathComponent(name)
            try? Data(text.utf8).write(to: file)
            return file.path
        }
        let output = try await git.run(
            ["merge-file", "-p", "-L", "Hauptfassung", "-L", "Ursprung", "-L", "Experiment"] + files,
            allowedStatus: Set(0...127)
        )
        return (output.string, output.status == 0)
    }

    /// Places the writer still has to decide, during an adoption.
    public func currentConflicts() async throws -> [MergeConflict] {
        let output = try await git.run(["status", "--porcelain=v2", "-z", "--ignore-submodules=all"])
        var conflicts: [MergeConflict] = []
        for record in output.string.split(separator: "\0") where record.hasPrefix("u ") {
            let fields = record.split(separator: " ", maxSplits: 10)
            guard fields.count == 11 else { continue }
            let xy = String(fields[1]), path = String(fields[10])
            switch xy {
            case "DU": conflicts.append(MergeConflict(path: path, kind: .deletedInMain))
            case "UD": conflicts.append(MergeConflict(path: path, kind: .deletedInExperiment))
            case "DD":
                try await git.run(["rm", "--quiet", "--cached", "--ignore-unmatch", "--", path])
            default:
                let text = FileManager.default.contents(atPath: url.appendingPathComponent(path).path)
                    .map { String(decoding: $0, as: UTF8.self) }
                if let text, let segments = ConflictSegment.parse(text) {
                    conflicts.append(MergeConflict(path: path, kind: .text(segments)))
                } else {
                    conflicts.append(MergeConflict(path: path, kind: .whole))
                }
            }
        }
        return conflicts.sorted { $0.path < $1.path }
    }

    public func resolve(_ path: String, with resolution: ConflictResolution) async throws {
        switch resolution {
        case .text(let text):
            try Data(text.utf8).write(to: url.appendingPathComponent(path), options: .atomic)
            try await git.run(["add", "--", path])
        case .keep:
            try await git.run(["add", "--", path])
            // A scene the main version had deleted comes back where the experiment has it.
            if let id = MergeConflict(path: path, kind: .whole).sceneID, !manifest.sceneIDs.contains(id),
               let branch = await adoptionInProgress()?.branch
            {
                let theirs = await git.show(Manifest.fileName, at: branch).flatMap { try? Manifest.parse(String(decoding: $0, as: UTF8.self)) }
                try updateManifest { $0.place(id, like: theirs) }
                try await git.run(["add", "--", Manifest.fileName])
            }
        case .delete:
            try await git.run(["rm", "--quiet", "--force", "--", path])
        case .main:
            try await git.run(["checkout", "--ours", "--", path])
            try await git.run(["add", "--", path])
        case .experiment:
            try await git.run(["checkout", "--theirs", "--", path])
            try await git.run(["add", "--", path])
        }
    }

    /// Completes the adoption with one version that has both histories as parents.
    @discardableResult
    public func finishAdoption() async throws -> String {
        guard let info = await adoptionInProgress() else { throw ExperimentError.noSuchVersion("Übernahme") }
        guard try await currentConflicts().isEmpty else { throw ExperimentError.unresolvedConflicts }

        // Keep structure and files consistent: no entries for deleted scenes.
        try reload()
        let missing = manifest.sceneIDs.filter { !FileManager.default.fileExists(atPath: sceneURL($0).path) }
        if !missing.isEmpty {
            try updateManifest { manifest in missing.forEach { manifest.removeScene($0) } }
        }

        let tip = await git.resolve("MERGE_HEAD") ?? ""
        let message = info.fromServer
            ? "Mit dem Server zusammengeführt\n\nCrea-Words: \(totalWords())\nCrea-Merged-From: \(info.branch) \(tip)\n"
            : "Experiment „\(info.name)“ übernommen\n\nCrea-Words: \(totalWords())\nCrea-Adopted-From: \(info.branch) \(tip)\n"
        let identity = await git.identityArguments(fallbackName: manifest.authors.first ?? "Zadur")
        try await git.run(["add", "--all"])
        try await git.run(identity + ["commit", "--quiet", "--file=-"], input: Data(message.utf8))
        try? FileManager.default.removeItem(at: adoptionMarkerURL)
        try reload()
        return await git.headCommit() ?? ""
    }

    /// Cancels the adoption; the main version is exactly as before.
    public func abortAdoption() async throws {
        if await git.resolve("MERGE_HEAD") != nil {
            try await git.run(["merge", "--abort"])
        }
        try? FileManager.default.removeItem(at: adoptionMarkerURL)
        try reload()
    }

    /// Copies selected scenes from an experiment into the main version as one normal version.
    /// New scenes are placed where they are in the experiment, if that chapter exists.
    @discardableResult
    public func adoptScenes(_ ids: [String], from branch: String) async throws -> SaveResult? {
        guard await adoptionInProgress() == nil else { throw ExperimentError.adoptionInProgress }
        let main = await mainBranch()
        if await currentBranch() != main { try await switchTo(main) } else { _ = try await saveVersion() }

        let theirs = await git.show(Manifest.fileName, at: branch).flatMap { try? Manifest.parse(String(decoding: $0, as: UTF8.self)) }
        var titles: [String] = []
        for id in ids {
            guard let data = await git.show(Self.scenePath(id), at: branch) else { continue }
            try data.write(to: sceneURL(id), options: .atomic)
            titles.append(SceneFile.parse(id: id, text: String(decoding: data, as: UTF8.self)).displayTitle)
            guard !manifest.sceneIDs.contains(id) else { continue }
            try updateManifest { $0.place(id, like: theirs) }
        }
        let name = await displayName(ofBranch: branch)
        let tip = await git.resolve(branch) ?? ""
        return try await saveVersion(
            subject: "Aus Experiment „\(name)“ übernommen: " + Self.list(titles),
            extraTrailers: ["Crea-Adopted-From: \(branch) \(tip)"]
        )
    }
}
