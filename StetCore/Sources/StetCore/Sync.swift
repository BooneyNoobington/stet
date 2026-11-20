import Foundation

/// Syncing a book with a git server (e.g. Gitea) as the source of truth.
///
/// Nothing is ever force-pushed except this Mac's own snapshot ref. If both sides wrote, the
/// main version is merged with the same machinery as adopting an experiment; experiments that
/// diverged are left alone and reported.
public struct SyncResult: Equatable {
    /// Versions of the main version that came from the server (fast-forward).
    public var pulledVersions = 0
    /// Experiments that came from the server or were updated from it.
    public var updatedExperiments: [String] = []
    public var pushed = false
    /// The main version and the server's both have new versions; they need to be merged.
    public var needsMerge = false
    /// The server has versions this Mac hasn't brought in yet (only when syncing without integrating).
    public var serverHasNew = false
    public var warnings: [String] = []

    public var changedFiles: Bool { pulledVersions > 0 || !updatedExperiments.isEmpty }
}

public enum RemoteCheck: Equatable {
    /// Nothing on the server yet: connecting sends the whole book.
    case empty
    /// The server holds this book's history (`behind` versions this Mac doesn't have, `ahead` the other way).
    case sameBook(ahead: Int, behind: Int, isStetBook: Bool)
    /// The server holds something else.
    case unrelated
}

public enum SyncError: Error, LocalizedError, Equatable {
    case notConnected
    case unreachable(String)
    case unrelatedServer
    case notAStetBook

    public var errorDescription: String? {
        switch self {
        case .notConnected: "Für dieses Buch ist kein Server eingerichtet."
        case .unreachable(let detail): "Der Server ist nicht erreichbar: \(detail)"
        case .unrelatedServer: "Auf dem Server liegt ein anderes Projekt, nicht dieses Buch."
        case .notAStetBook: "Auf dem Server liegt kein Stet-Buch."
        }
    }

    /// Turns git/ssh's English error output into something a writer can act on.
    static func explain(_ stderr: String) -> String {
        let text = stderr.lowercased()
        if text.contains("could not resolve hostname") || text.contains("name or service not known") {
            return "Der Servername ist unbekannt – Adresse prüfen oder Netzwerk/VPN verbinden."
        }
        if text.contains("connection timed out") || text.contains("operation timed out") || text.contains("network is unreachable") {
            return "Keine Verbindung zum Server (Zeitüberschreitung)."
        }
        if text.contains("connection refused") { return "Der Server lehnt die Verbindung ab." }
        if text.contains("host key verification failed") {
            return "Der Server ist diesem Mac noch unbekannt. Einmal im Terminal verbinden (z. B. mit „ssh“) und den Schlüssel bestätigen."
        }
        if text.contains("permission denied") || text.contains("authentication failed") || text.contains("could not read username") {
            return "Anmeldung abgelehnt – SSH-Schlüssel bzw. Zugangsdaten für diesen Server prüfen."
        }
        if text.contains("not found") || text.contains("does not appear to be a git repository") || text.contains("does not exist") {
            return "Unter dieser Adresse gibt es kein Repository. Bei Gitea muss es vorher angelegt sein (gern leer)."
        }
        let firstLine = stderr.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return firstLine.map(String.init) ?? "Unbekannter Fehler"
    }
}

/// Help with server addresses.
public enum ServerAddress {
    /// The short form `user@host:path` can't carry a port. An address like `git@host:2222/name/book.git`
    /// is read as path `2222/name/book.git` on port 22. Returns the `ssh://` form with the port then.
    public static func suggestionForPortInShortForm(_ address: String) -> String? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = try! NSRegularExpression(pattern: #"^([^\s/:]+@)?([^\s/:]+):(\d{1,5})/(.+)$"#)
        guard !trimmed.contains("://"),
              let match = pattern.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed))
        else { return nil }
        func group(_ index: Int) -> String {
            Range(match.range(at: index), in: trimmed).map { String(trimmed[$0]) } ?? ""
        }
        return "ssh://\(group(1))\(group(2)):\(group(3))/\(group(4))"
    }
}

extension Book {
    public static let remoteName = "origin"

    // MARK: Network environment

    /// SSH must never wait for input: no password prompts, no host-key questions, short timeout.
    func networkEnvironment() async -> [String: String] {
        let options = "-o BatchMode=yes -o ConnectTimeout=15"
        if let custom = ProcessInfo.processInfo.environment["GIT_SSH_COMMAND"], !custom.isEmpty {
            return ["GIT_SSH_COMMAND": "\(custom) \(options)"]
        }
        let configured = try? await git.run(["config", "--get", "core.sshCommand"], allowedStatus: [0, 1])
        let base = configured?.string.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ["GIT_SSH_COMMAND": "\(base.isEmpty ? "ssh" : base) \(options)"]
    }

    func network(_ arguments: [String], allowedStatus: Set<Int32> = [0]) async throws -> Git.Output {
        let output = try await git.run(arguments, environment: await networkEnvironment(), allowedStatus: Set(0...128))
        guard allowedStatus.contains(output.status) else {
            throw SyncError.unreachable(SyncError.explain(output.stderr))
        }
        return output
    }

    // MARK: Connecting

    public func remoteURL() async -> String? {
        let output = try? await git.run(["remote", "get-url", Self.remoteName], allowedStatus: [0, 2, 128])
        guard output?.status == 0 else { return nil }
        let url = output?.string.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return url.isEmpty ? nil : url
    }

    /// Looks at what's on the server without changing anything here (except a temporary ref).
    public func checkRemote(_ url: String) async throws -> RemoteCheck {
        let probe = "refs/stet/probe/main"
        let listing = try await network(["ls-remote", "--heads", url])
        let heads = listing.string.split(separator: "\n").compactMap { $0.split(separator: "\t").last.map(String.init) }
        guard !heads.isEmpty else { return .empty }
        let remoteMain = heads.contains("refs/heads/main") ? "refs/heads/main" : heads.contains("refs/heads/master") ? "refs/heads/master" : heads[0]
        try await network(["fetch", "--quiet", "--no-tags", url, "+\(remoteMain):\(probe)"])
        let related = (try? await git.run(["merge-base", "HEAD", probe], allowedStatus: [0, 1]))?.status == 0
        let counts = related
            ? (try await git.run(["rev-list", "--left-right", "--count", "HEAD...\(probe)"]).string
                .split(whereSeparator: \.isWhitespace).compactMap { Int($0) })
            : []
        let isStet = (try? await git.run(["cat-file", "-e", "\(probe):\(Manifest.fileName)"], allowedStatus: [0, 1, 128]))?.status == 0
        try await git.run(["update-ref", "-d", probe])
        guard related else { return .unrelated }
        return .sameBook(ahead: counts.first ?? 0, behind: counts.last ?? 0, isStetBook: isStet)
    }

    /// Sets the server and syncs. Refuses servers that hold a different project.
    @discardableResult
    public func connect(to url: String, device: String) async throws -> SyncResult {
        let check = try await checkRemote(url)
        if check == .unrelated { throw SyncError.unrelatedServer }
        if await remoteURL() != nil {
            try await git.run(["remote", "set-url", Self.remoteName, url])
        } else {
            try await git.run(["remote", "add", Self.remoteName, url])
        }
        return try await sync(device: device)
    }

    public func disconnect() async throws {
        guard await remoteURL() != nil else { return }
        try await git.run(["remote", "remove", Self.remoteName])
    }

    // MARK: Syncing

    /// Fetches, brings in what the server has (unless `integrate` is false), and sends what this
    /// Mac has. Without integrating, nothing in the working tree changes: use that while the
    /// writer may be typing, and integrate on opening or on request.
    public func sync(device: String, integrate: Bool = true) async throws -> SyncResult {
        guard await remoteURL() != nil else { throw SyncError.notConnected }
        guard await adoptionInProgress() == nil else { throw ExperimentError.adoptionInProgress }
        var result = SyncResult()
        let remote = Self.remoteName

        // 1. Fetch branches, tags and notes.
        // Pruning only ever touches the remote-tracking branches. (With a tags refspec, --prune
        // would delete local milestones the server doesn't have yet.)
        let branches = try await network(["fetch", "--quiet", "--prune", remote, "+refs/heads/*:refs/remotes/\(remote)/*"], allowedStatus: [0, 1])
        if branches.status != 0 { result.warnings.append(SyncError.explain(branches.stderr)) }
        let extras = try await network([
            "fetch", "--quiet", remote, "refs/tags/*:refs/tags/*", "+refs/notes/*:refs/notes/\(remote)/*",
        ], allowedStatus: [0, 1])
        if extras.status != 0 { result.warnings.append(SyncError.explain(extras.stderr)) }
        try await mergeNotes()

        // 2. The main version.
        let main = await mainBranch()
        let current = await currentBranch()
        if !integrate {
            for ref in await git.refs(matching: "refs/heads") {
                let tracking = "refs/remotes/\(remote)/" + ref.dropFirst("refs/heads/".count)
                guard await git.resolve(tracking) != nil else { continue }
                switch try await relation(ref, tracking) {
                case .behind: result.serverHasNew = true
                case .diverged:
                    result.serverHasNew = true
                    if ref == "refs/heads/\(main)" { result.needsMerge = true }
                default: break
                }
            }
            try await push(device: device, result: &result)
            return result
        }
        if await git.resolve("refs/remotes/\(remote)/\(main)") != nil {
            switch try await relation("refs/heads/\(main)", "refs/remotes/\(remote)/\(main)") {
            case .behind(let count):
                if current == main {
                    _ = try await saveVersion()
                    if try await relation("refs/heads/\(main)", "refs/remotes/\(remote)/\(main)") == .behind(count) {
                        try await git.run(["merge", "--ff-only", "--quiet", "refs/remotes/\(remote)/\(main)"])
                        try reload()
                        result.pulledVersions = count
                    } else {
                        result.needsMerge = true
                    }
                } else {
                    try await git.run(["update-ref", "refs/heads/\(main)", "refs/remotes/\(remote)/\(main)"])
                    result.pulledVersions = count
                }
            case .diverged:
                result.needsMerge = true
            case .same, .ahead:
                break
            }
        }

        // 3. Experiments (and shelved ones) from other Macs.
        try await integrateExperiments(current: current, result: &result)

        // 4. Send everything that's new here.
        try await push(device: device, result: &result)
        return result
    }

    /// Merges the server's main version into this Mac's (both have new versions).
    public func mergeWithServer() async throws -> AdoptionResult {
        let main = await mainBranch()
        return try await merge("\(Self.remoteName)/\(main)")
    }

    enum Relation: Equatable { case same, ahead(Int), behind(Int), diverged }

    func relation(_ local: String, _ remote: String) async throws -> Relation {
        let counts = try await git.run(["rev-list", "--left-right", "--count", "\(local)...\(remote)"]).string
            .split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard counts.count == 2 else { return .same }
        switch (counts[0], counts[1]) {
        case (0, 0): return .same
        case (let ahead, 0): return .ahead(ahead)
        case (0, let behind): return .behind(behind)
        default: return .diverged
        }
    }

    private func integrateExperiments(current: String, result: inout SyncResult) async throws {
        let remote = Self.remoteName
        let remoteRefs = await git.refs(matching: "refs/remotes/\(remote)/\(Self.experimentPrefix.dropLast())")
            + (await git.refs(matching: "refs/remotes/\(remote)/\(Self.shelvedPrefix.dropLast())"))
        for remoteRef in remoteRefs {
            let branch = String(remoteRef.dropFirst("refs/remotes/\(remote)/".count))
            let local = "refs/heads/\(branch)"
            guard let remoteTip = await git.resolve(remoteRef) else { continue }

            if await git.resolve(local) == nil {
                // Shelved here, the old name is still on the server: don't bring it back.
                if branch.hasPrefix(Self.experimentPrefix) {
                    let shelvedHere = "refs/heads/" + Self.shelvedPrefix + branch.dropFirst(Self.experimentPrefix.count)
                    if let shelvedTip = await git.resolve(shelvedHere),
                       (try? await git.run(["merge-base", "--is-ancestor", remoteTip, shelvedTip], allowedStatus: [0, 1]))?.status == 0
                    {
                        continue
                    }
                }
                // Shelved on another Mac: the same experiment is still active here.
                if branch.hasPrefix(Self.shelvedPrefix) {
                    let active = "refs/heads/" + Self.experimentPrefix + branch.dropFirst(Self.shelvedPrefix.count)
                    if await git.resolve(active) == remoteTip, active != "refs/heads/\(current)" {
                        try await git.run(["branch", "--move", String(active.dropFirst("refs/heads/".count)), branch])
                        continue
                    }
                }
                try await git.run(["branch", "--quiet", branch, remoteTip])
                result.updatedExperiments.append(branch)
                continue
            }
            var state = try await relation(local, remoteRef)
            if case .behind = state, branch == current {
                _ = try await saveVersion()  // pending work here first
                state = try await relation(local, remoteRef)
            }
            switch state {
            case .behind:
                if branch == current {
                    try await git.run(["merge", "--ff-only", "--quiet", remoteRef])
                    try reload()
                } else {
                    try await git.run(["update-ref", local, remoteRef])
                }
                result.updatedExperiments.append(branch)
            case .diverged:
                result.warnings.append("„\(await displayName(ofBranch: branch))“ wurde auf mehreren Macs bearbeitet und wird erst einmal nicht abgeglichen.")
            case .same, .ahead:
                break
            }
        }
    }

    private func mergeNotes() async throws {
        let theirs = "refs/notes/\(Self.remoteName)/commits"
        guard let remoteNotes = await git.resolve(theirs) else { return }
        guard await git.resolve("refs/notes/commits") != nil else {
            try await git.run(["update-ref", "refs/notes/commits", remoteNotes])
            return
        }
        let identity = await git.identityArguments(fallbackName: manifest.authors.first ?? "Stet")
        try await git.run(identity + ["notes", "merge", "--quiet", "--strategy=cat_sort_uniq", theirs], allowedStatus: [0, 1])
    }

    private func push(device: String, result: inout SyncResult) async throws {
        let remote = Self.remoteName
        var specs: [String] = []
        let branches = await git.refs(matching: "refs/heads")
        for ref in branches {
            let name = String(ref.dropFirst("refs/heads/".count))
            let tracking = "refs/remotes/\(remote)/\(name)"
            if await git.resolve(tracking) != nil {
                // Only send what is ahead; behind or diverged branches can't be sent without losing work.
                guard case .ahead = try await relation(ref, tracking) else { continue }
            }
            specs.append("\(ref):\(ref)")
        }
        // An experiment shelved here: remove its old name from the server (the work is kept under shelved/).
        for ref in branches where ref.hasPrefix("refs/heads/" + Self.shelvedPrefix) {
            let active = Self.experimentPrefix + ref.dropFirst(("refs/heads/" + Self.shelvedPrefix).count)
            if let remoteTip = await git.resolve("refs/remotes/\(remote)/\(active)"), remoteTip == (await git.resolve(ref)),
               await git.resolve("refs/heads/\(active)") == nil
            {
                specs.append(":refs/heads/\(active)")
            }
        }
        specs.append("refs/tags/*:refs/tags/*")
        if await git.resolve("refs/notes/commits") != nil { specs.append("refs/notes/commits:refs/notes/commits") }
        let snapshot = Self.snapshotRef(device: device)
        if await git.resolve(snapshot) != nil { specs.append("+\(snapshot):\(snapshot)") }

        let output = try await network(["push", "--porcelain", remote] + specs, allowedStatus: [0, 1])
        for line in output.string.split(separator: "\n") where line.hasPrefix("!") {
            let fields = line.split(separator: "\t")
            let ref = fields.count > 1 ? String(fields[1].split(separator: ":").last ?? "") : String(line)
            if ref.hasPrefix("refs/stet/") { continue }  // a server that refuses custom refs: snapshots stay local
            result.warnings.append("Nicht gesendet: \(ref.replacingOccurrences(of: "refs/heads/", with: "")) (\(fields.last ?? ""))")
        }
        result.pushed = output.status == 0 || result.warnings.isEmpty
        // Keep the remote-tracking refs in step with what was just sent.
        _ = try? await network(["fetch", "--quiet", remote, "+refs/heads/*:refs/remotes/\(remote)/*"], allowedStatus: [0, 1])
    }

    // MARK: Fetching a book from a server

    /// Clones a book from a server (for a second Mac). Experiments come along as local branches.
    /// With `key`, that key is used for the clone and for the book's syncing afterwards.
    public static func clone(from url: String, to destination: URL, key: SSHKey? = nil) async throws -> Book {
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw BookError.alreadyExists(destination) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let parent = Git(directory: destination.deletingLastPathComponent())
        var probe = try Book.networkProbe(parent)
        if let key { probe["GIT_SSH_COMMAND"] = key.sshCommand + " -o BatchMode=yes -o ConnectTimeout=15" }
        let output = try await parent.run(["clone", "--quiet", url, destination.path], environment: probe, allowedStatus: Set(0...128))
        guard output.status == 0 else { throw SyncError.unreachable(SyncError.explain(output.stderr)) }
        guard FileManager.default.fileExists(atPath: destination.appendingPathComponent(Manifest.fileName).path) else {
            try? FileManager.default.removeItem(at: destination)
            throw SyncError.notAStetBook
        }
        let book = try Book(url: destination)
        if let key { try await book.use(key) }
        var result = SyncResult()
        try await book.integrateExperiments(current: await book.currentBranch(), result: &result)
        try await book.git.run(["fetch", "--quiet", remoteName, "+refs/notes/*:refs/notes/\(remoteName)/*"], environment: probe, allowedStatus: Set(0...128))
        try await book.mergeNotes()
        return book
    }

    static func networkProbe(_ git: Git) throws -> [String: String] {
        let custom = ProcessInfo.processInfo.environment["GIT_SSH_COMMAND"] ?? "ssh"
        return ["GIT_SSH_COMMAND": "\(custom) -o BatchMode=yes -o ConnectTimeout=15"]
    }
}
