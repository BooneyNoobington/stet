import Foundation

/// Detects whether a location is managed by a file-sync service (Nextcloud, Dropbox, iCloud …),
/// which can damage a book's history when two devices write to it.
public enum SyncLocation {
    public struct Finding: Equatable {
        public let service: String
        public let root: URL
    }

    public static func detect(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Finding? {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let homePath = home.standardizedFileURL.path

        // File Provider based services (Dropbox, OneDrive, Google Drive, newer Nextcloud, Box …)
        let cloudStorage = homePath + "/Library/CloudStorage/"
        if path.hasPrefix(cloudStorage) {
            let folder = path.dropFirst(cloudStorage.count).split(separator: "/").first.map(String.init) ?? ""
            let name = folder.split(separator: "-").first.map(String.init) ?? folder
            return Finding(service: prettyName(name), root: URL(fileURLWithPath: cloudStorage + folder))
        }
        let iCloud = homePath + "/Library/Mobile Documents"
        if path.hasPrefix(iCloud) {
            return Finding(service: "iCloud Drive", root: URL(fileURLWithPath: iCloud))
        }
        // "Desktop & Documents in iCloud" and other ubiquitous locations
        if (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true {
            return Finding(service: "iCloud Drive", root: url.deletingLastPathComponent())
        }
        // Classic sync clients configured with their own folder
        for root in nextcloudRoots(home: home) where path == root.path || path.hasPrefix(root.path + "/") {
            return Finding(service: "Nextcloud", root: root)
        }
        // Marker files in a parent folder
        var folder = url.deletingLastPathComponent()
        while folder.path.count > 1 {
            if let service = markerService(in: folder) {
                return Finding(service: service, root: folder)
            }
            folder.deleteLastPathComponent()
        }
        return nil
    }

    static func markerService(in folder: URL) -> String? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        for name in names {
            if (name.hasPrefix(".sync_") || name.hasPrefix("._sync_")) && name.hasSuffix(".db") { return "Nextcloud" }
            if name == ".owncloudsync.log" { return "Nextcloud" }
            if name == ".stfolder" { return "Syncthing" }
            if name == ".dropbox" || name == ".dropbox.cache" { return "Dropbox" }
            if name == ".SynologyWorkingDirectory" { return "Synology Drive" }
        }
        return nil
    }

    static func nextcloudRoots(home: URL) -> [URL] {
        let configs = ["Library/Preferences/Nextcloud/nextcloud.cfg", "Library/Preferences/ownCloud/owncloud.cfg"]
        return configs.flatMap { relative -> [URL] in
            guard let text = try? String(contentsOf: home.appendingPathComponent(relative), encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { line in
                guard let range = line.range(of: "localPath=") else { return nil }
                var value = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if value.hasSuffix("/") { value.removeLast() }
                return value.isEmpty ? nil : URL(fileURLWithPath: value)
            }
        }
    }

    static func prettyName(_ name: String) -> String {
        switch name.lowercased() {
        case "googledrive": "Google Drive"
        case "onedrive": "OneDrive"
        case "dropbox": "Dropbox"
        case "nextcloud": "Nextcloud"
        case "box": "Box"
        default: name
        }
    }
}

/// Checks run when a book is opened: sync-conflict copies and git integrity.
public enum HealthCheck {
    public struct Report: Equatable {
        public var conflictCopies: [String] = []
        public var integrityProblem: String?
        public var isHealthy: Bool { conflictCopies.isEmpty && integrityProblem == nil }
    }

    public static func run(_ book: Book) async -> Report {
        var report = Report()
        report.conflictCopies = conflictCopies(in: book.url)
        report.integrityProblem = await book.git.integrityProblem()
        return report
    }

    /// Files that look like sync-service conflict copies, as paths relative to the book.
    public static func conflictCopies(in root: URL) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var found: [String] = []
        for case let file as URL in enumerator {
            let relative = String(file.path.dropFirst(root.path.count + 1))
            // Inside .git only refs and HEAD-like files matter, not the object store.
            if relative.hasPrefix(".git/objects") { enumerator.skipDescendants(); continue }
            if isConflictName(file.lastPathComponent, siblingExists: { fm.fileExists(atPath: file.deletingLastPathComponent().appendingPathComponent($0).path) }) {
                found.append(relative)
            }
        }
        return found.sorted()
    }

    static func isConflictName(_ name: String, siblingExists: (String) -> Bool) -> Bool {
        let lower = name.lowercased()
        if lower.contains("conflicted copy") || lower.contains("konfliktkopie") || lower.contains(".sync-conflict-")
            || lower.contains("(case conflict") {
            return true
        }
        // iCloud style: "name 2.md" next to "name.md"
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        guard let space = stem.lastIndex(of: " "), Int(stem[stem.index(after: space)...]) != nil else { return false }
        let original = String(stem[..<space]) + (ext.isEmpty ? "" : ".\(ext)")
        return siblingExists(original)
    }
}
