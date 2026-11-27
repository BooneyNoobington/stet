import Foundation

public enum CopyError: Error, LocalizedError, Equatable {
    case insideItself
    case busy
    case damaged(String)

    public var errorDescription: String? {
        switch self {
        case .insideItself: "Ein Buch lässt sich nicht in sich selbst sichern. Wähle einen Ort außerhalb des Buchs."
        case .busy: "Git arbeitet noch am Buch (z. B. ein Abgleich mit dem Server). Versuche es gleich noch einmal."
        case .damaged(let problem): "Die Kopie ist nicht vollständig geworden, deshalb hat Zadur sie verworfen: \(problem)"
        }
    }
}

extension Book {
    /// How often (every 100 ms) a copy waits for git to finish writing. Tests shorten it.
    static var lockChecks = 50

    /// Throws why `destination` can't take a copy of this book (taken, or inside the book).
    public func checkCopyDestination(_ destination: URL) throws {
        let source = url.standardizedFileURL.resolvingSymlinksInPath().path
        let parent = destination.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
        let target = parent + "/" + destination.lastPathComponent
        if target.hasPrefix(source + "/") { throw CopyError.insideItself }
        if FileManager.default.fileExists(atPath: destination.path) { throw BookError.alreadyExists(destination) }
    }

    /// "Sichern unter …": the whole book in another place – every version, experiment,
    /// milestone, note, snapshot and feedback, and this Mac's state for it (last scene, backups,
    /// timestamps still to fetch). The original stays exactly as it is.
    ///
    /// The copy is made under a hidden name next to the destination and only renamed when it is
    /// complete and its history checks out, so a half copy never looks like a book. On the same
    /// disk APFS shares the data until either side changes, so even a large book is copied at once.
    ///
    /// With `keepServer`, the copy is the same book in another place and syncs like a second Mac.
    /// Without, it forgets the server and its key (the key itself stays, the original uses it):
    /// an independent book that can be connected to another server later.
    @discardableResult
    public func copy(to destination: URL, keepServer: Bool) async throws -> URL {
        try checkCopyDestination(destination)
        // A git command still writing (e.g. a push finishing) would leave a lock in the copy.
        for _ in 0..<Self.lockChecks where hasGitLocks() { try await Task.sleep(for: .milliseconds(100)) }
        guard !hasGitLocks() else { throw CopyError.busy }

        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).zadur-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }  // only left if something failed
        try fm.copyItem(at: url, to: staging)

        if fm.fileExists(atPath: staging.appendingPathComponent(".git").path) {
            let copy = try Book(url: staging)
            if let problem = await copy.git.integrityProblem() { throw CopyError.damaged(problem) }
            if !keepServer {
                try await copy.disconnect()
                try await copy.forgetZadurKey()
            }
        }
        try fm.moveItem(at: staging, to: destination)
        Self.markAsPackage(destination)
        return destination
    }

    /// Lock files git leaves while it writes (the index, HEAD, settings, refs).
    func hasGitLocks() -> Bool {
        let fm = FileManager.default
        let gitFolder = url.appendingPathComponent(".git")
        if ["index.lock", "HEAD.lock", "config.lock", "packed-refs.lock", "shallow.lock"]
            .contains(where: { fm.fileExists(atPath: gitFolder.appendingPathComponent($0).path) }) {
            return true
        }
        let refs = fm.enumerator(atPath: gitFolder.appendingPathComponent("refs").path)
        while let path = refs?.nextObject() as? String {
            if path.hasSuffix(".lock") { return true }
        }
        return false
    }
}
