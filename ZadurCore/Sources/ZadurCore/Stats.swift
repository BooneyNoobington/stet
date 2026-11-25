import Foundation

/// Writing statistics from the history. Every saved version records the book's words
/// (`Crea-Words`), the change (`Crea-Words-Delta`) and the active minutes
/// (`Crea-Active-Minutes`; Stet 1.0 wrote them with `Stet-`); for versions from before Zadur the words are counted once from the
/// files of that time and remembered per Mac.
public struct WritingStats: Equatable {
    public struct Point: Equatable, Identifiable {
        public let commit: String
        public let date: Date
        public let words: Int
        public var id: String { commit }
    }

    public struct Day: Equatable, Identifiable {
        /// Start of the day (local calendar).
        public let day: Date
        /// Net change in words (written minus deleted).
        public var words: Int
        public var minutes: Int
        public var versions: Int
        public var id: Date { day }
    }

    /// Words in the book over time, along the open version's history, oldest first.
    public var progress: [Point]
    /// Writing per day, from all versions on all branches (experiments too), oldest first.
    public var days: [Day]

    public init(progress: [Point], days: [Day]) {
        self.progress = progress
        self.days = days
    }

    public func day(_ date: Date, calendar: Calendar = .current) -> Day? {
        let start = calendar.startOfDay(for: date)
        return days.first { $0.day == start }
    }

    /// Net words and minutes from `start` (inclusive) to `end` (exclusive).
    public func total(from start: Date, to end: Date) -> (words: Int, minutes: Int, days: Int) {
        let range = days.filter { $0.day >= start && $0.day < end }
        return (range.reduce(0) { $0 + $1.words }, range.reduce(0) { $0 + $1.minutes }, range.count)
    }

    /// Days in a row with writing (a version with words added, or 5 active minutes), up to today.
    /// Today doesn't break the streak while it's still empty.
    public func streak(until today: Date = Date(), calendar: Calendar = .current) -> Int {
        let wrote = Set(days.filter { $0.words > 0 || $0.minutes >= 5 }.map(\.day))
        var day = calendar.startOfDay(for: today)
        if !wrote.contains(day) { day = calendar.date(byAdding: .day, value: -1, to: day) ?? day }
        var count = 0
        while wrote.contains(day) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }

    /// Per day, from versions (oldest first) with their net change and minutes.
    static func days(from versions: [(date: Date, delta: Int, minutes: Int)], calendar: Calendar) -> [Day] {
        var byDay: [Date: Day] = [:]
        for version in versions {
            let start = calendar.startOfDay(for: version.date)
            var day = byDay[start] ?? Day(day: start, words: 0, minutes: 0, versions: 0)
            day.words += version.delta
            day.minutes += version.minutes
            day.versions += 1
            byDay[start] = day
        }
        return byDay.values.sorted { $0.day < $1.day }
    }
}

extension Book {
    /// Statistics of the whole history. Versions without word counts (from before Zadur) are
    /// counted from their files once, then remembered in `.local/zadur-word-counts.json`.
    public func writingStats(calendar: Calendar = .current) async throws -> WritingStats {
        let commits = try await git.log("--branches")
        guard !commits.isEmpty else { return WritingStats(progress: [], days: []) }
        var cache = loadWordCounts()
        let cacheSize = cache.count

        func words(of commit: Git.Commit) async -> Int {
            if let value = commit.trailers["Words"].flatMap(Int.init) { return value }
            if let cached = cache[commit.hash] { return cached }
            let counted = (try? await wordsInTree(commit.hash)) ?? 0
            cache[commit.hash] = counted
            return counted
        }

        var byHash: [String: Git.Commit] = [:]
        for commit in commits { byHash[commit.hash] = commit }

        var versions: [(date: Date, delta: Int, minutes: Int)] = []
        for commit in commits where commit.parents.count <= 1 {
            let minutes = commit.trailers["Active-Minutes"].flatMap(Int.init) ?? 0
            var delta: Int
            if let value = commit.trailers["Words-Delta"].flatMap(Int.init) {
                delta = value
            } else {
                let now = await words(of: commit)
                var before = 0
                if let parent = commit.parents.first {
                    if let known = byHash[parent] {
                        before = await words(of: known)
                    } else {
                        if let cached = cache[parent] {
                            before = cached
                        } else {
                            before = (try? await wordsInTree(parent)) ?? 0
                            cache[parent] = before
                        }
                    }
                }
                delta = now - before
            }
            versions.append((commit.date, delta, minutes))
        }

        // In history order (dates can tie, or be off on another Mac's clock).
        let line = try await git.run(["rev-list", "--first-parent", "--reverse", "HEAD"]).string.split(separator: "\n").map(String.init)
        var progress: [WritingStats.Point] = []
        for hash in line {
            guard let commit = byHash[hash] else { continue }
            progress.append(.init(commit: commit.hash, date: commit.date, words: await words(of: commit)))
        }

        if cache.count != cacheSize { saveWordCounts(cache) }
        return WritingStats(
            // By date; versions with the same time keep their history order.
            progress: progress.enumerated().sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }.map(\.element),
            days: WritingStats.days(from: versions.sorted { $0.date < $1.date }, calendar: calendar)
        )
    }

    /// Words in a version's scenes: `scenes/` in a Zadur book; otherwise (before the import) the
    /// folder with the most Markdown files, e.g. "Szenen/".
    func wordsInTree(_ revision: String) async throws -> Int {
        let listing = try await git.run(["ls-tree", "-r", "-z", "--full-tree", revision]).string
        var files: [(path: String, oid: String)] = []
        for record in listing.split(separator: "\0") {
            guard let tab = record.firstIndex(of: "\t") else { continue }
            let meta = record[..<tab].split(separator: " ")
            let path = String(record[record.index(after: tab)...])
            guard meta.count == 3, meta[1] == "blob", path.lowercased().hasSuffix(".md") else { continue }
            files.append((path, String(meta[2])))
        }
        let folder: String
        if files.contains(where: { $0.path.hasPrefix(Self.scenesFolder + "/") }) {
            folder = Self.scenesFolder
        } else {
            // The top folder usually holds notes and read-mes; it counts only if there is nothing else.
            let counts = Dictionary(grouping: files) { ($0.path as NSString).deletingLastPathComponent }.mapValues(\.count)
                .filter { !$0.key.hasPrefix(WikiEntry.folder) && !$0.key.hasPrefix(FeedbackEntry.folder) }
            let folders = counts.count > 1 ? counts.filter { !$0.key.isEmpty } : counts
            folder = folders.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? ""
        }
        let scenes = files.filter { ($0.path as NSString).deletingLastPathComponent == folder }
        let blobs = try await git.blobs(scenes.map(\.oid))
        return scenes.reduce(0) { total, file in
            let text = String(decoding: blobs[file.oid] ?? Data(), as: UTF8.self)
            return total + TextStats.words(in: SceneFile.parse(id: "", text: text).body)
        }
    }

    private var wordCountsURL: URL { url.appendingPathComponent(Self.localFolder).appendingPathComponent("zadur-word-counts.json") }

    func loadWordCounts() -> [String: Int] {
        guard let data = try? Data(contentsOf: wordCountsURL),
              let counts = try? JSONDecoder().decode([String: Int].self, from: data)
        else { return [:] }
        return counts
    }

    func saveWordCounts(_ counts: [String: Int]) {
        try? FileManager.default.createDirectory(at: wordCountsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(counts) { try? data.write(to: wordCountsURL, options: .atomic) }
    }
}

extension Manifest {
    /// The book's word goal, if the writer set one.
    public var goal: Int? {
        get { wordGoal }
        set { wordGoal = newValue.flatMap { $0 > 0 ? $0 : nil } }
    }
}
