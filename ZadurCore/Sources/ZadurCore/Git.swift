import Foundation

public struct GitError: Error, LocalizedError {
    public let arguments: [String]
    public let status: Int32
    public let stderr: String

    public var errorDescription: String? {
        "git \(arguments.first ?? "") fehlgeschlagen (\(status)): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}

/// Thin wrapper around the system `git`.
///
/// Every call is isolated from the user's own git setup where it would change behaviour
/// (hooks, autocrlf, signing, rebase-on-pull …) and only machine-readable output is parsed.
public final class Git {
    public static var executable = URL(fileURLWithPath: "/usr/bin/git")

    static let isolation = [
        "-c", "core.hooksPath=/dev/null",
        "-c", "core.quotePath=false",
        "-c", "core.autocrlf=false",
        "-c", "core.precomposeunicode=true",
        "-c", "core.fsmonitor=false",
        "-c", "protocol.ext.allow=never",
        "-c", "log.showSignature=false",
        // Repositories nested in a book are never looked into (they'd bring settings of their own).
        "-c", "diff.ignoreSubmodules=all",
        "-c", "submodule.recurse=false",
        "-c", "fetch.recurseSubmodules=false",
        "-c", "commit.gpgsign=false",
        "-c", "tag.gpgsign=false",
        "-c", "pull.rebase=false",
        "-c", "init.defaultBranch=main",
        "-c", "advice.detachedHead=false",
        "-c", "color.ui=false",
    ]

    public let directory: URL

    /// For a book: git uses exactly its `.git`, so a book without one can't end up in the
    /// repository of a folder around it (e.g. a writing folder under git), and its settings are
    /// checked first (see RepositoryGuard).
    public let isRepositoryRoot: Bool

    public init(directory: URL, isRepositoryRoot: Bool = false) {
        self.isRepositoryRoot = isRepositoryRoot
        self.directory = directory
    }

    public struct Output {
        public let status: Int32
        public let data: Data
        public let stderr: String
        public var string: String { String(decoding: data, as: UTF8.self) }
    }

    /// Runs git with `arguments` in `directory`. Throws on a non-zero exit unless it is in `allowedStatus`.
    ///
    /// A call that signs (see `identityArguments`) and fails because of the signature is run
    /// again unsigned, so a locked agent or a missing key never costs a version;
    /// `Signing.onFailure` hears about it.
    @discardableResult
    public func run(
        _ arguments: [String],
        input: Data? = nil,
        environment: [String: String] = [:],
        allowedStatus: Set<Int32> = [0],
        retryUnsigned: Bool = true
    ) async throws -> Output {
        let signs = arguments.contains(Signing.marker)
        var environment = environment
        if signs, let signing = Signing.current?.environment {
            environment.merge(signing) { explicit, _ in explicit }
        }
        do {
            return try await runOnce(arguments, input: input, environment: environment, allowedStatus: allowedStatus)
        } catch let error as GitError where signs && retryUnsigned {
            // If it works without the signature, the signature was the problem.
            guard let output = try? await runOnce(Signing.unsigned(arguments), input: input, environment: environment, allowedStatus: allowedStatus)
            else { throw error }
            Signing.onFailure?(Signing.explain(error.stderr))
            return output
        }
    }

    private func runOnce(
        _ arguments: [String],
        input: Data?,
        environment: [String: String],
        allowedStatus: Set<Int32>
    ) async throws -> Output {
        let directory = directory
        let ceiling = isRepositoryRoot ? directory.deletingLastPathComponent().path : nil
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                if self.isRepositoryRoot {
                    do {
                        try RepositoryGuard.secure(directory)
                    } catch {
                        continuation.resume(throwing: error)
                        return
                    }
                }
                let process = Process()
                process.executableURL = Git.executable
                process.arguments = Git.isolation + arguments
                process.currentDirectoryURL = directory
                var env = ProcessInfo.processInfo.environment
                env["GIT_TERMINAL_PROMPT"] = "0"
                env["LC_MESSAGES"] = "C"
                env["GIT_PAGER"] = "cat"
                if let ceiling {
                    env["GIT_CEILING_DIRECTORIES"] = ceiling
                    env["GIT_DIR"] = directory.appendingPathComponent(".git").path
                    env["GIT_WORK_TREE"] = directory.path
                }
                env.merge(environment) { _, new in new }
                process.environment = env

                let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
                process.standardInput = stdin
                process.standardOutput = stdout
                process.standardError = stderr

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                if let input { stdin.fileHandleForWriting.write(input) }
                try? stdin.fileHandleForWriting.close()

                let out = Buffer(), err = Buffer()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    out.data = stdout.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    err.data = stderr.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                process.waitUntilExit()
                group.wait()

                let output = Output(
                    status: process.terminationStatus,
                    data: out.data,
                    stderr: String(decoding: err.data, as: UTF8.self)
                )
                if allowedStatus.contains(output.status) {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(throwing: GitError(arguments: arguments, status: output.status, stderr: output.stderr))
                }
            }
        }
    }

    private final class Buffer {
        var data = Data()
    }

    // MARK: Basics

    public func initRepository() async throws {
        try await run(["init", "--quiet", "--initial-branch=main"])
    }

    public func headCommit() async -> String? {
        guard let output = try? await run(["rev-parse", "--verify", "--quiet", "HEAD"], allowedStatus: [0, 1]),
              output.status == 0
        else { return nil }
        return output.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func currentBranch() async -> String? {
        let output = try? await run(["symbolic-ref", "--quiet", "--short", "HEAD"], allowedStatus: [0, 1])
        let name = output?.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name : nil
    }

    /// Changed paths in the working tree compared with HEAD (including untracked files).
    public func changedPaths() async throws -> [String] {
        let output = try await run(["status", "--porcelain=v2", "-z", "--untracked-files=all", "--ignore-submodules=all"])
        var paths: [String] = []
        var records = output.string.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        while let record = records.next() {
            switch record.first {
            case "1":
                paths.append(String(record.split(separator: " ", maxSplits: 8)[8]))
            case "2":
                paths.append(String(record.split(separator: " ", maxSplits: 9)[9]))
                if let original = records.next() { paths.append(String(original)) }
            case "u":
                paths.append(String(record.split(separator: " ", maxSplits: 10)[10]))
            case "?":
                paths.append(String(record.dropFirst(2)))
            default:
                continue
            }
        }
        return paths
    }

    /// Who makes a version: a fallback identity when the user has no git name/email configured,
    /// and (unless `sign` is false, e.g. for snapshots) this Mac's signing setup.
    public func identityArguments(fallbackName: String, sign: Bool = true) async -> [String] {
        let name = try? await run(["config", "user.name"], allowedStatus: [0, 1])
        let email = try? await run(["config", "user.email"], allowedStatus: [0, 1])
        var args: [String] = []
        if name?.status != 0 || name?.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            args += ["-c", "user.name=\(fallbackName)"]
        }
        if email?.status != 0 || email?.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            args += ["-c", "user.email=zadur@localhost"]
        }
        if sign, let signing = Signing.current { args += signing.gitArguments }
        return args
    }

    /// Stages everything and commits. Returns the new commit hash.
    public func commitAll(message: String, identity: [String] = []) async throws -> String {
        try await run(["add", "--all"])
        try await run(identity + ["commit", "--quiet", "--file=-"], input: Data(message.utf8))
        return await headCommit() ?? ""
    }

    public func addNote(_ text: String, to commit: String) async throws {
        try await run(["notes", "add", "--force", "--file=-", commit], input: Data(text.utf8))
    }

    /// Contents of `path` at `revision`, or nil if it doesn't exist there.
    public func show(_ path: String, at revision: String) async -> Data? {
        guard let output = try? await run(["show", "\(revision):\(path)"], allowedStatus: [0, 128]),
              output.status == 0
        else { return nil }
        return output.data
    }

    /// Contents of blobs by object id (one `cat-file --batch` for all of them).
    func blobs(_ ids: [String]) async throws -> [String: Data] {
        guard !ids.isEmpty else { return [:] }
        let output = try await run(["cat-file", "--batch"], input: Data((ids.joined(separator: "\n") + "\n").utf8))
        let bytes = [UInt8](output.data)
        var result: [String: Data] = [:]
        var index = 0
        while index < bytes.count {
            guard let newline = bytes[index...].firstIndex(of: 0x0a) else { break }
            let header = String(decoding: bytes[index..<newline], as: UTF8.self).split(separator: " ")
            index = newline + 1
            guard header.count == 3, let size = Int(header[2]), index + size <= bytes.count else { continue }
            result[String(header[0])] = Data(bytes[index..<(index + size)])
            index += size + 1
        }
        return result
    }

    public func refs(matching pattern: String) async -> [String] {
        let output = try? await run(["for-each-ref", "--format=%(refname)", pattern])
        return output?.string.split(separator: "\n").map(String.init) ?? []
    }

    public func resolve(_ ref: String) async -> String? {
        guard let output = try? await run(["rev-parse", "--verify", "--quiet", ref], allowedStatus: [0, 1]),
              output.status == 0
        else { return nil }
        return output.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Log

    public struct Commit: Equatable, Identifiable {
        public let hash: String
        public let parents: [String]
        public let date: Date
        public let author: String
        public let subject: String
        public let body: String
        public let note: String?
        /// The file's path in this commit (for path-limited logs; follows renames).
        public let path: String?

        public var id: String { hash }
        public var shortHash: String { String(hash.prefix(7)) }

        /// The book's trailers from the message body, by name without prefix: `Crea-Words: 5`
        /// (and Stet 1.0's `Stet-Words: 5`) → `trailers["Words"] == "5"`. Crea's win.
        public var trailers: [String: String] {
            var result: [String: String] = [:]
            var fromCrea = Set<String>()
            for line in body.split(separator: "\n") {
                let prefix = line.hasPrefix(Book.trailerPrefix) ? Book.trailerPrefix : line.hasPrefix(Book.legacyTrailerPrefix) ? Book.legacyTrailerPrefix : nil
                guard let prefix, let colon = line.firstIndex(of: ":") else { continue }
                let key = String(line[line.index(line.startIndex, offsetBy: prefix.count)..<colon])
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if prefix == Book.trailerPrefix { fromCrea.insert(key) } else if fromCrea.contains(key) { continue }
                result[key] = value
            }
            return result
        }
    }

    /// History of `revision` (optionally limited to one path, following renames).
    public func log(_ revision: String = "HEAD", path: String? = nil, follow: Bool = true, limit: Int? = nil) async throws -> [Commit] {
        var args = ["log", "--format=%x1e%H%x1f%P%x1f%aI%x1f%an%x1f%s%x1f%b%x1f%N%x1f"]
        if let limit { args.append("--max-count=\(limit)") }
        if path != nil {
            args.append("--name-only")
            if follow { args.append("--follow") }
        }
        args.append(revision)
        if let path { args += ["--", path] }

        let output = try await run(args, allowedStatus: [0, 128])
        guard output.status == 0 else { return [] }  // e.g. no commits yet
        let formatter = ISO8601DateFormatter()
        return output.string.split(separator: "\u{1e}").compactMap { record in
            let fields = record.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard fields.count >= 8 else { return nil }
            let note = fields[6].trimmingCharacters(in: .whitespacesAndNewlines)
            let pathLine = fields[7].split(separator: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return Commit(
                hash: String(fields[0]),
                parents: fields[1].split(separator: " ").map(String.init),
                date: formatter.date(from: String(fields[2])) ?? .distantPast,
                author: String(fields[3]),
                subject: String(fields[4]),
                body: fields[5].trimmingCharacters(in: .whitespacesAndNewlines),
                note: note.isEmpty ? nil : note,
                path: pathLine.map(String.init)
            )
        }
    }

    // MARK: Integrity

    /// nil when the repository is intact, otherwise git's complaint.
    public func integrityProblem() async -> String? {
        guard await headCommit() != nil else { return nil }
        do {
            // Without checking the commit-graph and multi-pack-index files (optional speed-ups):
            // fsck hands their checks the book's path as an argument, git composes it (ä as one
            // character), while GIT_DIR keeps the decomposed form macOS passes on to programs
            // (a + ¨, whatever Zadur sends). The two don't match, and fsck called every book with
            // an umlaut in its path damaged. The history itself is still checked in full.
            let output = try await run(["-c", "core.commitGraph=false", "-c", "core.multiPackIndex=false",
                                        "fsck", "--connectivity-only", "--no-progress", "--no-dangling"], allowedStatus: [0, 1, 2])
            let message = (output.stderr + output.string).trimmingCharacters(in: .whitespacesAndNewlines)
            return output.status == 0 ? nil : (message.isEmpty ? "git fsck meldet Fehler" : message)
        } catch {
            return error.localizedDescription
        }
    }
}
