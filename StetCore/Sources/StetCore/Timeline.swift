import Foundation

// MARK: - When a scene happens

/// A point in the story's time, from a scene's "Datum" (and "Uhrzeit") facts. As precise as the
/// writer was: "1978", "Sommer 1978", "Juli 1998", "14. Juli 1998", "14.7.1998", "1998-07-14".
public struct StoryTime: Comparable, Hashable {
    public let year: Int
    public let month: Int?
    public let day: Int?
    /// Minutes after midnight, if a time was given.
    public let minutes: Int?

    public init(year: Int, month: Int? = nil, day: Int? = nil, minutes: Int? = nil) {
        self.year = year
        self.month = month
        self.day = day
        self.minutes = minutes
    }

    /// Sorting: less precise dates come first within their span ("1998" before "Juli 1998").
    private var key: [Int] { [year, month ?? 0, day ?? 0, minutes ?? -1] }

    public static func < (lhs: StoryTime, rhs: StoryTime) -> Bool { lhs.key.lexicographicallyPrecedes(rhs.key) }

    /// The year with a fraction (1998.54 is mid-July 1998), for charts: later is higher.
    public var decimalYear: Double {
        let month = Double((self.month ?? 7) - 1) / 12
        let day = Double((self.day ?? (self.month == nil ? 1 : 15)) - 1) / 365
        let time = Double(minutes ?? 12 * 60) / (365 * 1440)
        return Double(year) + month + day + time
    }

    /// A date for charts: the middle of what's known (July 1st for a year, the 15th for a month).
    public var approximateDate: Date {
        var components = DateComponents()
        components.year = year
        components.month = month ?? 7
        components.day = day ?? (month == nil ? 1 : 15)
        components.hour = (minutes ?? 12 * 60) / 60
        components.minute = (minutes ?? 0) % 60
        return Calendar(identifier: .gregorian).date(from: components) ?? .distantPast
    }

    static let months = ["januar": 1, "jänner": 1, "februar": 2, "märz": 3, "maerz": 3, "april": 4, "mai": 5, "juni": 6,
                         "juli": 7, "august": 8, "september": 9, "oktober": 10, "november": 11, "dezember": 12,
                         "january": 1, "february": 2, "march": 3, "may": 5, "june": 6, "july": 7, "october": 10, "december": 12]
    static let seasons = ["frühling": 4, "frühjahr": 4, "sommer": 7, "herbst": 10, "winter": 1,
                          "spring": 4, "summer": 7, "autumn": 10, "fall": 10]

    public static func parse(date: String, time: String? = nil) -> StoryTime? {
        let text = date.trimmingCharacters(in: .whitespaces).lowercased()
        let minutes = time.flatMap(parseTime)
        func match(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
            else { return nil }
            return (1..<found.numberOfRanges).map { index in
                Range(found.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
        if let parts = match(#"^(\d{4})-(\d{1,2})-(\d{1,2})"#), let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
           (1...12).contains(month), (1...31).contains(day)
        {
            return StoryTime(year: year, month: month, day: day, minutes: minutes)
        }
        if let parts = match(#"^(\d{1,2})\.\s*(\d{1,2})\.\s*(\d{4})"#), let day = Int(parts[0]), let month = Int(parts[1]), let year = Int(parts[2]),
           (1...12).contains(month), (1...31).contains(day)
        {
            return StoryTime(year: year, month: month, day: day, minutes: minutes)
        }
        if let parts = match(#"^(\d{1,2})\.?\s+([a-zäöü]+)\s+(\d{3,4})"#), let day = Int(parts[0]), let month = months[parts[1]], let year = Int(parts[2]) {
            return StoryTime(year: year, month: month, day: day, minutes: minutes)
        }
        if let parts = match(#"^([a-zäöü]+)\s+(\d{3,4})"#), let year = Int(parts[1]) {
            if let month = months[parts[0]] { return StoryTime(year: year, month: month, minutes: minutes) }
            if let month = seasons[parts[0]] { return StoryTime(year: year, month: month, minutes: minutes) }
        }
        if let parts = match(#"^(\d{1,2})/(\d{4})$"#), let month = Int(parts[0]), let year = Int(parts[1]), (1...12).contains(month) {
            return StoryTime(year: year, month: month, minutes: minutes)
        }
        if let parts = match(#"^(\d{3,4})$"#), let year = Int(parts[0]) {
            return StoryTime(year: year, minutes: minutes)
        }
        return nil
    }

    /// "23:30", "23.30", "23 Uhr", "7:05 Uhr".
    static func parseTime(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard let regex = try? NSRegularExpression(pattern: #"^(\d{1,2})(?:[:.](\d{2}))?\s*(?:uhr)?$"#),
              let found = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let hourRange = Range(found.range(at: 1), in: trimmed), let hour = Int(trimmed[hourRange]), hour < 24
        else { return nil }
        let minute = Range(found.range(at: 2), in: trimmed).flatMap { Int(trimmed[$0]) } ?? 0
        guard minute < 60, found.range(at: 2).location != NSNotFound || trimmed.contains("uhr") else { return nil }
        return hour * 60 + minute
    }
}

// MARK: - Facts that scenes inherit

extension Manifest {
    public func part(containingChapter chapterID: String) -> Part? {
        for node in structure {
            if case .part(let part) = node, part.chapters.contains(where: { $0.id == chapterID }) { return part }
        }
        return nil
    }

    public mutating func updatePart(_ id: String, _ change: (inout Part) -> Void) {
        structure = structure.map { node in
            guard case .part(var part) = node, part.id == id else { return node }
            change(&part)
            return .part(part)
        }
    }

    /// Part facts, overridden by chapter facts, overridden by the scene's own.
    public func effectiveFacts(ofScene sceneID: String, own: [Fact]) -> [Fact] {
        var facts: [Fact] = []
        func apply(_ layer: [Fact]) {
            for fact in layer where !fact.value.trimmingCharacters(in: .whitespaces).isEmpty {
                if let index = facts.firstIndex(where: { $0.key == fact.key }) { facts[index] = fact } else { facts.append(fact) }
            }
        }
        if let chapter = chapter(containing: sceneID) {
            if let part = part(containingChapter: chapter.id) { apply(part.facts) }
            apply(chapter.facts)
        }
        apply(own)
        return facts
    }
}

// MARK: - The timeline

public struct TimelineEntry: Identifiable, Equatable {
    public let sceneID: String
    public let title: String
    public let chapterTitle: String
    /// 1-based position in reading order.
    public let position: Int
    public let time: StoryTime?
    /// The date and time as written ("Sommer 1978", "14.7.1998 · 23:30").
    public let timeText: String
    public let place: String?
    /// Earlier in the story than the scene read just before it.
    public let isFlashback: Bool
    public var id: String { sceneID }
}

extension Book {
    static let dateKeys = ["datum", "date", "tag"]
    static let timeKeys = ["uhrzeit", "zeit", "time"]
    static let placeKeys = ["ort", "place", "schauplatz"]

    /// Every placed scene in reading order, with its story time (from its own facts, or its
    /// chapter's or part's) and whether it jumps back.
    public func timeline() -> [TimelineEntry] {
        var entries: [TimelineEntry] = []
        var latest: StoryTime?
        for (index, id) in manifest.sceneIDs.enumerated() {
            let scene = try? readScene(id)
            let facts = manifest.effectiveFacts(ofScene: id, own: scene?.factList ?? [])
            func value(_ keys: [String]) -> String? {
                facts.first { keys.contains($0.key.lowercased()) }?.value.trimmingCharacters(in: .whitespaces)
            }
            let date = value(Self.dateKeys)
            let clock = value(Self.timeKeys)
            let time = date.flatMap { StoryTime.parse(date: $0, time: clock) }
            let flashback = time.map { current in latest.map { current < $0 } ?? false } ?? false
            if let time, !flashback { latest = max(latest ?? time, time) }
            entries.append(TimelineEntry(
                sceneID: id,
                title: scene?.displayTitle ?? id,
                chapterTitle: manifest.chapter(containing: id)?.title ?? "",
                position: index + 1,
                time: time,
                timeText: [date, clock].compactMap { $0 }.joined(separator: " · "),
                place: value(Self.placeKeys).map { Fact("", $0).displayValue },
                isFlashback: flashback
            ))
        }
        return entries
    }
}
