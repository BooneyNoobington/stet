import Foundation

/// An experiment: a branch `experiments/<slug>` (or `shelved/<slug>` once set aside).
public struct Experiment: Identifiable, Equatable {
    public let branch: String
    public let name: String
    public let isShelved: Bool
    public let tip: String
    public let lastChange: Date
    /// Versions in the experiment that the main version doesn't have.
    public let ahead: Int
    /// Versions in the main version that the experiment doesn't have.
    public let behind: Int
    /// False for branches from before Zadur (no manuscript.yaml); those can't be opened.
    public let isZadurBook: Bool

    public var id: String { branch }
    /// Everything in it is already part of the main version.
    public var isAdopted: Bool { ahead == 0 }
}

/// A named point in the history (annotated tag `milestone/<slug>`), e.g. "An den Club geschickt".
public struct Milestone: Identifiable, Equatable {
    public let tag: String
    public let name: String
    public let note: String?
    public let commit: String
    public let date: Date
    public var id: String { tag }
    /// Set automatically by an export (`export/…`), not by the writer.
    public var isExport: Bool { tag.hasPrefix("export/") }
}

/// What an experiment changed since it started, for the "adopt" overview.
public struct ExperimentChanges: Equatable {
    public struct SceneChange: Identifiable, Equatable {
        public enum Kind: Equatable { case added, edited, removed }
        public let id: String
        public let title: String
        public let kind: Kind
        public let wordsDelta: Int
    }

    public var scenes: [SceneChange] = []
    public var structureChanged = false
    public var otherFiles: [String] = []
    /// How many scenes the main version changed in the meantime.
    public var mainChangedScenes = 0
    public var isEmpty: Bool { scenes.isEmpty && !structureChanged && otherFiles.isEmpty }
}

public enum ExperimentError: Error, LocalizedError {
    case noSuchVersion(String)
    case notAZadurVersion(String)
    case adoptionInProgress
    case unresolvedConflicts
    case emptyName

    public var errorDescription: String? {
        switch self {
        case .noSuchVersion(let name): "„\(name)“ gibt es nicht."
        case .notAZadurVersion(let name): "„\(name)“ stammt aus der Zeit vor Zadur und kann nicht geöffnet werden. Übernehmen lässt es sich trotzdem."
        case .adoptionInProgress: "Gerade läuft eine Übernahme. Schließ sie zuerst ab oder brich sie ab."
        case .unresolvedConflicts: "Es sind noch nicht alle Stellen geklärt."
        case .emptyName: "Das Experiment braucht einen Namen."
        }
    }
}

extension Book {
    public static let experimentPrefix = "experiments/"
    public static let shelvedPrefix = "shelved/"
    public static let milestonePrefix = "milestone/"

    // MARK: Branch basics

    /// The main version's branch (`main`, or `master` in older repositories).
    public func mainBranch() async -> String {
        for candidate in ["main", "master"] where await git.resolve("refs/heads/\(candidate)") != nil {
            return candidate
        }
        return await git.currentBranch() ?? "main"
    }

    public func currentBranch() async -> String {
        await git.currentBranch() ?? "main"
    }

    /// A branch-name-safe slug that keeps umlauts and case: "Kapitel 3 aus Maras Sicht" → "Kapitel-3-aus-Maras-Sicht".
    public static func slug(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "~^:?*[]\\@{}/.\"'`!$&()<>|;,#%")
            .union(.controlCharacters).union(.illegalCharacters)
        let words = name.precomposedStringWithCanonicalMapping
            .components(separatedBy: .whitespacesAndNewlines)
            .map { String(String.UnicodeScalarView($0.unicodeScalars.filter { !forbidden.contains($0) })) }
            .filter { !$0.isEmpty }
        var slug = words.joined(separator: "-")
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "experiment" : slug
    }

    func uniqueRefName(prefix: String, slug: String, namespace: [String]) async -> String {
        var candidate = slug
        var counter = 2
        while true {
            var taken = false
            for space in namespace where await git.resolve("refs/\(space)\(candidate)") != nil { taken = true }
            if !taken { return candidate }
            candidate = "\(slug)-\(counter)"
            counter += 1
        }
    }

    /// The name the writer gave a branch (stored as its git description), or one derived from its slug.
    public func displayName(ofBranch branch: String) async -> String {
        if branch == (await mainBranch()) { return "Hauptfassung" }
        let description = try? await git.run(["config", "--get", "branch.\(branch).description"], allowedStatus: [0, 1])
        if let text = description?.string.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return text }
        let short = branch.hasPrefix(Self.experimentPrefix) ? String(branch.dropFirst(Self.experimentPrefix.count))
            : branch.hasPrefix(Self.shelvedPrefix) ? String(branch.dropFirst(Self.shelvedPrefix.count)) : branch
        return short.replacingOccurrences(of: "-", with: " ")
    }

    /// Re-reads manuscript.yaml (after switching versions or merging).
    public func reload() throws {
        let yaml = try String(contentsOf: url.appendingPathComponent(Manifest.fileName), encoding: .utf8)
        replaceManifest(try Manifest.parse(yaml), yaml: yaml)
    }

    // MARK: Listing

    public func experiments() async -> [Experiment] {
        let main = await mainBranch()
        guard let output = try? await git.run([
            "for-each-ref", "--sort=-committerdate",
            "--format=%(refname:short)%1f%(objectname)%1f%(committerdate:iso-strict)",
            "refs/heads/experiments", "refs/heads/shelved",
        ]) else { return [] }
        let formatter = ISO8601DateFormatter()
        var result: [Experiment] = []
        for line in output.string.split(separator: "\n") {
            let fields = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3 else { continue }
            let branch = fields[0]
            let counts = (try? await git.run(["rev-list", "--left-right", "--count", "\(main)...\(branch)"]))?.string
                .split(whereSeparator: \.isWhitespace).compactMap { Int($0) } ?? [0, 0]
            let isZadur = (try? await git.run(["cat-file", "-e", "\(branch):\(Manifest.fileName)"], allowedStatus: [0, 1, 128]))?.status == 0
            result.append(Experiment(
                branch: branch,
                name: await displayName(ofBranch: branch),
                isShelved: branch.hasPrefix(Self.shelvedPrefix),
                tip: fields[1],
                lastChange: formatter.date(from: fields[2]) ?? .distantPast,
                ahead: counts.count == 2 ? counts[1] : 0,
                behind: counts.count == 2 ? counts[0] : 0,
                isZadurBook: isZadur
            ))
        }
        return result
    }

    // MARK: Starting, switching, shelving

    /// Starts an experiment from the current version. With `carryChanges`, unsaved changes move
    /// into the experiment; otherwise they are saved as a version where they are first.
    @discardableResult
    public func startExperiment(named name: String, carryChanges: Bool) async throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ExperimentError.emptyName }
        guard await git.resolve("MERGE_HEAD") == nil else { throw ExperimentError.adoptionInProgress }
        if !carryChanges { _ = try await saveVersion() }
        let slug = await uniqueRefName(prefix: Self.experimentPrefix, slug: Self.slug(trimmed),
                                       namespace: ["heads/" + Self.experimentPrefix, "heads/" + Self.shelvedPrefix])
        let branch = Self.experimentPrefix + slug
        try await git.run(["switch", "--quiet", "--create", branch])
        try await git.run(["config", "branch.\(branch).description", trimmed])
        return branch
    }

    /// Saves pending changes as a version where they are, then opens `branch`.
    public func switchTo(_ branch: String) async throws {
        guard await git.resolve("MERGE_HEAD") == nil else { throw ExperimentError.adoptionInProgress }
        guard await git.resolve("refs/heads/\(branch)") != nil else { throw ExperimentError.noSuchVersion(branch) }
        guard branch != (await currentBranch()) else { return }
        let isZadur = try await git.run(["cat-file", "-e", "\(branch):\(Manifest.fileName)"], allowedStatus: [0, 1, 128]).status == 0
        guard isZadur else { throw ExperimentError.notAZadurVersion(await displayName(ofBranch: branch)) }
        _ = try await saveVersion()
        try await git.run(["switch", "--quiet", branch])
        try reload()
    }

    /// Sets an experiment aside (`shelved/…`). Nothing is deleted.
    public func shelve(_ branch: String) async throws {
        guard branch.hasPrefix(Self.experimentPrefix) else { return }
        if branch == (await currentBranch()) { try await switchTo(await mainBranch()) }
        let slug = String(branch.dropFirst(Self.experimentPrefix.count))
        let target = Self.shelvedPrefix + (await uniqueRefName(prefix: Self.shelvedPrefix, slug: slug, namespace: ["heads/" + Self.shelvedPrefix]))
        try await git.run(["branch", "--move", branch, target])
    }

    /// Brings a shelved experiment back.
    public func unshelve(_ branch: String) async throws {
        guard branch.hasPrefix(Self.shelvedPrefix) else { return }
        let slug = String(branch.dropFirst(Self.shelvedPrefix.count))
        let target = Self.experimentPrefix + (await uniqueRefName(prefix: Self.experimentPrefix, slug: slug, namespace: ["heads/" + Self.experimentPrefix]))
        try await git.run(["branch", "--move", branch, target])
    }

    // MARK: What an experiment changed

    public func changes(in branch: String) async throws -> ExperimentChanges {
        let main = await mainBranch()
        let base = try await git.run(["merge-base", main, branch]).string.trimmingCharacters(in: .whitespacesAndNewlines)
        var changes = ExperimentChanges()

        let diff = try await git.run(["diff", "--name-status", "-z", "--no-renames", base, branch]).string
        let parts = diff.split(separator: "\0").map(String.init)
        var index = 0
        while index + 1 < parts.count {
            let status = parts[index], path = parts[index + 1]
            index += 2
            if path == Manifest.fileName { changes.structureChanged = true; continue }
            guard path.hasPrefix(Self.scenesFolder + "/"), path.hasSuffix(".md") else {
                changes.otherFiles.append(path)
                continue
            }
            let id = String(path.dropFirst(Self.scenesFolder.count + 1).dropLast(3))
            let before = await git.show(path, at: base).map { SceneFile.parse(id: id, text: String(decoding: $0, as: UTF8.self)) }
            let after = await git.show(path, at: branch).map { SceneFile.parse(id: id, text: String(decoding: $0, as: UTF8.self)) }
            let kind: ExperimentChanges.SceneChange.Kind = status.hasPrefix("A") ? .added : status.hasPrefix("D") ? .removed : .edited
            let delta = (after.map { TextStats.words(in: $0.body) } ?? 0) - (before.map { TextStats.words(in: $0.body) } ?? 0)
            changes.scenes.append(.init(id: id, title: (after ?? before)?.displayTitle ?? id, kind: kind, wordsDelta: delta))
        }

        let mainDiff = try await git.run(["diff", "--name-only", "-z", base, main]).string
        changes.mainChangedScenes = mainDiff.split(separator: "\0").filter { $0.hasPrefix(Self.scenesFolder + "/") }.count
        return changes
    }

    // MARK: Milestones

    public func milestones() async -> [Milestone] {
        guard let output = try? await git.run([
            "for-each-ref", "--sort=-creatordate",
            "--format=%(refname:short)%1f%(*objectname)%1f%(objectname)%1f%(creatordate:iso-strict)%1f%(contents:subject)%1f%(contents:body)%1e",
            "refs/tags/" + Self.milestonePrefix.dropLast(),
            "refs/tags/export",
        ]) else { return [] }
        let formatter = ISO8601DateFormatter()
        return output.string.split(separator: "\u{1e}").compactMap { record in
            let fields = record.trimmingCharacters(in: .newlines).split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 6 else { return nil }
            let note = fields[5].trimmingCharacters(in: .whitespacesAndNewlines)
            return Milestone(
                tag: fields[0],
                name: fields[4],
                note: note.isEmpty ? nil : note,
                commit: fields[1].isEmpty ? fields[2] : fields[1],
                date: formatter.date(from: fields[3]) ?? .distantPast
            )
        }
    }

    /// Marks the current version (saving pending changes first) with a milestone.
    @discardableResult
    public func setMilestone(name: String, note: String? = nil) async throws -> Milestone? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ExperimentError.emptyName }
        _ = try await saveVersion()
        let slug = await uniqueRefName(prefix: Self.milestonePrefix, slug: Self.slug(trimmed), namespace: ["tags/" + Self.milestonePrefix])
        let tag = Self.milestonePrefix + slug
        var message = trimmed
        if let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty { message += "\n\n" + note }
        let identity = await git.identityArguments(fallbackName: manifest.authors.first ?? "Zadur")
        try await git.run(identity + ["tag", "--annotate", "--file=-", tag, "HEAD"], input: Data((message + "\n").utf8))
        return await milestones().first { $0.tag == tag }
    }
}
