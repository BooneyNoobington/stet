import Foundation

/// Backups: the whole book – history, experiments, milestones, feedback – as one ZIP file.
///
/// One file is what file-sync services handle well, so unlike a live book, a backup may sit in
/// Nextcloud, Dropbox or iCloud. The ZIP is written to a temporary place, checked, and only then
/// moved into the target folder, so a half-written backup never appears there.
/// Per-device state (`.local/`) is left out.
public enum Backup {
    public struct Info: Equatable, Identifiable {
        public let url: URL
        public let date: Date
        public let size: Int
        public var id: String { url.path }
    }

    public enum BackupError: Error, LocalizedError {
        case toolFailed(String, String)
        case damaged(URL)
        case noBookInside(URL)
        case folderUnavailable(URL)

        public var errorDescription: String? {
            switch self {
            case .toolFailed(let tool, let detail): "\(tool) ist gescheitert: \(detail)"
            case .damaged(let url): "Das Backup „\(url.lastPathComponent)“ ist beschädigt."
            case .noBookInside(let url): "In „\(url.lastPathComponent)“ steckt kein Zadur-Buch."
            case .folderUnavailable(let url): "Der Backup-Ordner „\(url.path)“ ist nicht erreichbar (z. B. Platte nicht angeschlossen)."
            }
        }
    }

    static let suffix = ".crea.zip"
    /// Backups from when Zadur was called Stet.
    static let legacySuffix = ".stet.zip"
    static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmm"
        return f
    }()

    /// "Schnee im September – Backup 2026-11-20 1430.crea.zip"
    public static func fileName(for book: Book, date: Date = Date()) -> String {
        "\(prefix(for: book))\(stampFormatter.string(from: date))\(suffix)"
    }

    static func prefix(for book: Book) -> String {
        let title = book.manifest.title.isEmpty ? book.url.deletingPathExtension().lastPathComponent : book.manifest.title
        let safe = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "\(safe) – Backup "
    }

    /// Creates a backup in `folder` with the standard name.
    @discardableResult
    public static func create(_ book: Book, in folder: URL, date: Date = Date()) async throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BackupError.folderUnavailable(folder)
        }
        var target = folder.appendingPathComponent(fileName(for: book, date: date))
        var counter = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent(fileName(for: book, date: date).replacingOccurrences(of: suffix, with: " (\(counter))\(suffix)"))
            counter += 1
        }
        return try await create(book, to: target)
    }

    /// Creates a backup at exactly `file` (replacing it).
    @discardableResult
    public static func create(_ book: Book, to file: URL) async throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("zadur-backup-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let name = book.url.lastPathComponent
        let zip = work.appendingPathComponent("backup.zip")
        try await run("/usr/bin/zip", ["-q", "-r", "-y", "-X", zip.path, name,
                                       "-x", "\(name)/\(Book.localFolder)/*", "*.DS_Store"],
                      in: book.url.deletingLastPathComponent())
        try await verify(zip)

        if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
        try fm.moveItem(at: zip, to: file)
        return file
    }

    /// Checks that a backup's archive is intact.
    public static func verify(_ zip: URL) async throws {
        do {
            try await run("/usr/bin/unzip", ["-tqq", zip.path], in: zip.deletingLastPathComponent())
        } catch {
            throw BackupError.damaged(zip)
        }
    }

    /// This book's backups in `folder`, newest first.
    public static func list(in folder: URL, for book: Book) -> [Info] {
        let fm = FileManager.default
        let prefix = prefix(for: book)
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey])) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix(prefix) && ($0.lastPathComponent.hasSuffix(suffix) || $0.lastPathComponent.hasSuffix(legacySuffix)) }
            .map { url in
                let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
                let stamp = url.lastPathComponent.dropFirst(prefix.count).prefix(15)
                let date = stampFormatter.date(from: String(stamp)) ?? values?.creationDate ?? .distantPast
                return Info(url: url, date: date, size: values?.fileSize ?? 0)
            }
            .sorted { $0.date > $1.date || ($0.date == $1.date && $0.url.lastPathComponent > $1.url.lastPathComponent) }
    }

    /// Keeps the newest `keep` backups of this book in `folder`; returns what was removed.
    @discardableResult
    public static func rotate(in folder: URL, for book: Book, keep: Int) throws -> [URL] {
        let old = list(in: folder, for: book).dropFirst(max(1, keep)).map(\.url)
        for url in old { try FileManager.default.removeItem(at: url) }
        return old
    }

    /// Unpacks a backup into `folder` and returns the book. An existing book of the same name stays.
    public static func restore(_ zip: URL, into folder: URL) async throws -> URL {
        try await verify(zip)
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("zadur-restore-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        try await run("/usr/bin/unzip", ["-qq", zip.path, "-d", work.path], in: work)

        guard let inside = (try? fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil))?
            .first(where: { Book.readableExtensions.contains($0.pathExtension) && fm.fileExists(atPath: $0.appendingPathComponent(Manifest.fileName).path) })
        else { throw BackupError.noBookInside(zip) }

        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var target = folder.appendingPathComponent(inside.lastPathComponent)
        var counter = 2
        while fm.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(inside.deletingPathExtension().lastPathComponent) (wiederhergestellt\(counter > 2 ? " \(counter - 1)" : "")).\(inside.pathExtension)")
            counter += 1
        }
        try fm.moveItem(at: inside, to: target)
        _ = try Book(url: target)  // valid book; also sets the Finder bundle bit
        return target
    }

    static func run(_ tool: String, _ arguments: [String], in folder: URL) async throws {
        let result: (Int32, String) = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: tool)
                process.arguments = arguments
                process.currentDirectoryURL = folder
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
            throw BackupError.toolFailed(URL(fileURLWithPath: tool).lastPathComponent, result.1.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
