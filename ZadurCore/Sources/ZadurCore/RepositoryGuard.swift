import Foundation

/// A book may come from someone else, and its `.git` with it. Git settings can start programs
/// (filters, merge drivers, hooks, an ssh command …), so in a book only settings known to be
/// harmless stay: everything else is taken out of `.git/config` before git runs there. The
/// original file is kept next to it. Checked before every git command (only the file's bytes
/// are compared, unless it changed), since a sync service may bring a new one at any time.
public enum RepositoryGuard {
    public enum Problem: Error, LocalizedError, Equatable {
        case pointsElsewhere(String)
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case .pointsElsewhere(let name):
                "Der Verlauf von „\(name)“ liegt nicht im Buch selbst, sondern verweist auf einen anderen Ordner. So ein Buch öffnet Zadur nicht."
            case .unreadable(let name):
                "Die Git-Einstellungen von „\(name)“ lassen sich nicht lesen."
            }
        }
    }

    /// Hears which settings were taken out of a book (their names), to tell the writer.
    public static var onRemoved: ((URL, [String]) -> Void)?

    private static let lock = NSLock()
    /// The configuration last found to be harmless, by book.
    private static var checked: [String: Data] = [:]

    /// Makes sure git can run in `book`: its `.git` is a real folder, with harmless settings only.
    public static func secure(_ book: URL) throws {
        let folder = book.appendingPathComponent(".git")
        guard let kind = fileType(folder) else { return }  // no history (yet)
        guard kind == .typeDirectory, fileType(folder.appendingPathComponent("commondir")) == nil else {
            throw Problem.pointsElsewhere(book.lastPathComponent)
        }
        let file = folder.appendingPathComponent("config")
        guard let fileKind = fileType(file) else { return }
        guard fileKind == .typeRegular else { throw Problem.pointsElsewhere(book.lastPathComponent) }

        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: file) else { throw Problem.unreadable(book.lastPathComponent) }
        if checked[folder.path] == data { return }
        guard let settings = list(file) else { throw Problem.unreadable(book.lastPathComponent) }
        let kept = settings.filter(isHarmless)
        guard kept.count < settings.count else {
            checked[folder.path] = data
            return
        }
        let clean = Data(render(kept).utf8)
        var copy = folder.appendingPathComponent("config.entfernt")
        var number = 2
        while fileType(copy) != nil {
            copy = folder.appendingPathComponent("config.entfernt-\(number)")
            number += 1
        }
        try data.write(to: copy, options: .withoutOverwriting)
        try clean.write(to: file, options: .atomic)
        guard let result = list(file), result == kept else { throw Problem.unreadable(book.lastPathComponent) }
        checked[folder.path] = clean
        var seen = Set<String>()
        let removed = settings.filter { !isHarmless($0) }.map(\.key).filter { seen.insert($0).inserted }
        onRemoved?(book, removed)
    }

    // MARK: Settings

    struct Setting: Equatable {
        /// As git lists it: section and name in lower case, the part between as written.
        var key: String
        /// nil: a name without `=` (true).
        var value: String?

        var section: String { String(key.prefix { $0 != "." }).lowercased() }
        var name: String { String(key.split(separator: ".").last ?? "").lowercased() }
        /// The quoted part of `[section "…"]`.
        var subsection: String? {
            guard let first = key.firstIndex(of: "."), let last = key.lastIndex(of: "."), first < last else { return nil }
            return String(key[key.index(after: first)..<last])
        }
    }

    /// Settings that can't start a program, connect anywhere on their own or point outside the book.
    static func isHarmless(_ setting: Setting) -> Bool {
        let value = (setting.value ?? "true").lowercased()
        switch (setting.section, setting.subsection, setting.name) {
        case ("core", nil, "repositoryformatversion"): return value == "0" || value == "1"
        case ("core", nil, "bare"): return ["false", "no", "off", "0"].contains(value)
        case ("core", nil, "sshcommand"): return SSHKey.isOwnCommand(setting.value ?? "")
        case ("core", nil, let name):
            return ["filemode", "logallrefupdates", "ignorecase", "precomposeunicode", "symlinks", "protecthfs", "protectntfs",
                    "autocrlf", "eol", "safecrlf", "quotepath", "abbrev", "compression", "loosecompression", "bigfilethreshold",
                    "trustctime", "checkstat", "untrackedcache", "commitgraph", "preloadindex"].contains(name)
        case ("extensions", nil, let name): return ["objectformat", "refstorage", "compatobjectformat", "noop", "preciousobjects"].contains(name)
        // The address itself is asked about before anything connects (ServerTrust).
        case ("remote", .some, let name): return ["url", "fetch", "prune", "tagopt"].contains(name)
        case ("branch", .some, let name): return ["description", "remote", "merge", "rebase"].contains(name)
        case ("user", nil, let name), ("author", nil, let name), ("committer", nil, let name): return ["name", "email"].contains(name)
        case ("stet", nil, _), ("zadur", nil, _): return true
        case ("push", nil, let name): return ["default", "autosetupremote", "followtags"].contains(name)
        case ("pull", nil, let name): return ["rebase", "ff"].contains(name)
        case ("merge", nil, let name): return ["conflictstyle", "ff"].contains(name)
        case ("rerere", nil, let name): return ["enabled", "autoupdate"].contains(name)
        case ("diff", nil, let name): return ["algorithm", "renames", "mnemonicprefix", "colormoved"].contains(name)
        case ("notes", nil, "mergestrategy"), ("init", nil, "defaultbranch"), ("index", nil, "version"), ("gpg", nil, "format"),
             ("commit", nil, "gpgsign"), ("tag", nil, "gpgsign"): return true
        case ("gc", nil, let name): return ["auto", "autopacklimit", "autodetach", "pruneexpire", "reflogexpire"].contains(name)
        case ("pack", nil, let name): return ["window", "depth", "threads", "compression"].contains(name)
        case ("i18n", nil, _), ("color", _, _), ("column", nil, _), ("advice", nil, _): return true
        default: return false
        }
    }

    /// The settings in `file` (no included files), or nil if git can't read it. Runs outside any
    /// repository, so nothing in the book is in effect.
    static func list(_ file: URL) -> [Setting]? {
        let process = Process()
        process.executableURL = Git.executable
        process.arguments = ["config", "--file", file.path, "--no-includes", "--null", "--list"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        var environment = ProcessInfo.processInfo.environment
        for name in ["GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR"] { environment[name] = nil }
        environment["GIT_CEILING_DIRECTORIES"] = "/"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\0").map { entry in
            guard let end = entry.firstIndex(of: "\n") else { return Setting(key: String(entry), value: nil) }
            return Setting(key: String(entry[..<end]), value: String(entry[entry.index(after: end)...]))
        }
    }

    static func render(_ settings: [Setting]) -> String {
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t") + "\""
        }
        var text = ""
        var header = ""
        for setting in settings {
            let wanted = setting.subsection.map {
                "[\(setting.section) \"\($0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"]"
            } ?? "[\(setting.section)]"
            if wanted != header {
                text += wanted + "\n"
                header = wanted
            }
            text += "\t" + setting.name + (setting.value.map { " = " + quoted($0) } ?? "") + "\n"
        }
        return text
    }

    private static func fileType(_ url: URL) -> FileAttributeType? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
    }
}

// MARK: - Servers

/// The servers the writer has set up or agreed to on this Mac. A book from someone else may name
/// a server of theirs (or a folder with hooks of its own): Zadur only connects to one after asking.
public protocol ServerTrustStore: AnyObject {
    func isTrusted(_ address: String) -> Bool
    func trust(_ address: String)
}

public final class MemoryServerTrust: ServerTrustStore {
    private let lock = NSLock()
    private var addresses = Set<String>()
    public init() {}

    public func isTrusted(_ address: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return addresses.contains(address)
    }

    public func trust(_ address: String) {
        lock.lock()
        defer { lock.unlock() }
        addresses.insert(address)
    }
}

public final class DefaultsServerTrust: ServerTrustStore {
    private let defaults: UserDefaults
    private static let key = "TrustedServers"
    public init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Whether anything was ever recorded (false right after updating from a version without it).
    public var hasRecords: Bool { defaults.object(forKey: Self.key) != nil }

    public func isTrusted(_ address: String) -> Bool { (defaults.stringArray(forKey: Self.key) ?? []).contains(address) }

    public func trust(_ address: String) {
        let known = defaults.stringArray(forKey: Self.key) ?? []
        if !known.contains(address) { defaults.set(known + [address], forKey: Self.key) }
    }

    /// Books opened before this existed: their servers were set up here.
    public func begin(with addresses: [String]) {
        guard !hasRecords else { return }
        defaults.set(Array(Set(addresses)).sorted(), forKey: Self.key)
    }
}

public enum ServerTrust {
    public static var store: ServerTrustStore = MemoryServerTrust()
}
