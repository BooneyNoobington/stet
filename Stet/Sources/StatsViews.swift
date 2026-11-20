import Charts
import StetCore
import SwiftUI

extension BookSession {
    func loadStats() async {
        stats = try? await book.writingStats()
    }

    /// Words saved in versions today, plus what's written since the last version.
    var wordsToday: Int {
        let saved = stats?.day(Date())?.words ?? 0
        let lastSaved = lastVersion?.trailers["Stet-Words"].flatMap(Int.init) ?? totalWords
        return saved + (totalWords - lastSaved)
    }

    var minutesToday: Int { (stats?.day(Date())?.minutes ?? 0) + unsavedMinutes }
}

// MARK: - The statistics window

struct StatsWindow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if let session = model.session {
                StatsView(session: session)
            } else {
                ContentUnavailableView("Kein Buch geöffnet", systemImage: "chart.bar",
                                       description: Text("Die Statistik gehört zu einem Buch. Öffne zuerst ein Buch."))
            }
        }
        .frame(minWidth: 640, minHeight: 520)
    }
}

private enum Period: String, CaseIterable, Identifiable {
    case days = "30 Tage"
    case weeks = "12 Wochen"
    case months = "Alles"
    var id: String { rawValue }
}

private struct Bar: Identifiable {
    let start: Date
    let words: Int
    let minutes: Int
    var id: Date { start }
}

struct StatsView: View {
    @ObservedObject var session: BookSession
    @AppStorage("StetDailyGoal") private var dailyGoal = 0
    @State private var period: Period = .days
    @State private var selectedBar: Date?
    @State private var selectedPoint: Date?
    @State private var goalText = ""

    private let calendar = Calendar.current

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                tiles
                if let stats = session.stats {
                    perDay(stats)
                    growth(stats)
                } else {
                    ProgressView("Liest die Versionen …").frame(maxWidth: .infinity)
                }
                chapters
                goals
            }
            .padding(24)
        }
        .navigationTitle("Statistik – \(session.manifest.title)")
        .task { await session.loadStats() }
        .onAppear { goalText = session.manifest.goal.map(String.init) ?? "" }
    }

    // MARK: Headline numbers

    private var tiles: some View {
        let stats = session.stats
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? calendar.startOfDay(for: Date())
        let week = stats?.total(from: weekStart, to: .distantFuture) ?? (words: 0, minutes: 0, days: 0)
        let unsaved = session.wordsToday - (stats?.day(Date())?.words ?? 0)
        let streak = stats?.streak() ?? 0
        return Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                Tile(title: "Heute", value: signed(session.wordsToday), unit: "Wörter",
                     detail: minutes(session.minutesToday) + (dailyGoal > 0 ? " · Ziel \(dailyGoal.formatted())" : ""),
                     progress: dailyGoal > 0 ? Double(max(0, session.wordsToday)) / Double(dailyGoal) : nil)
                Tile(title: "Diese Woche", value: signed(week.words + unsaved), unit: "Wörter",
                     detail: "\(week.days) \(week.days == 1 ? "Schreibtag" : "Schreibtage") · " + minutes(week.minutes + session.unsavedMinutes))
                Tile(title: "Serie", value: "\(streak)", unit: streak == 1 ? "Tag" : "Tage",
                     detail: "in Folge geschrieben")
                Tile(title: "Buch", value: session.totalWords.formatted(), unit: "Wörter",
                     detail: session.manifest.goal.map { "Ziel \($0.formatted()) · \(Int((Double(session.totalWords) / Double($0) * 100).rounded())) %" } ?? "kein Ziel gesetzt",
                     progress: session.manifest.goal.map { Double(session.totalWords) / Double($0) })
            }
        }
    }

    // MARK: Words per day / week / month

    private func bars(_ stats: WritingStats) -> [Bar] {
        let today = calendar.startOfDay(for: Date())
        switch period {
        case .days:
            return (0..<30).reversed().compactMap { offset in
                guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
                let entry = stats.day(day)
                let extra = offset == 0 ? session.wordsToday - (entry?.words ?? 0) : 0
                return Bar(start: day, words: (entry?.words ?? 0) + extra, minutes: (entry?.minutes ?? 0) + (offset == 0 ? session.unsavedMinutes : 0))
            }
        case .weeks:
            let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
            return (0..<12).reversed().compactMap { offset in
                guard let start = calendar.date(byAdding: .weekOfYear, value: -offset, to: thisWeek),
                      let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start)
                else { return nil }
                let total = stats.total(from: start, to: end)
                return Bar(start: start, words: total.words, minutes: total.minutes)
            }
        case .months:
            guard let first = stats.days.first?.day else { return [] }
            var start = calendar.dateInterval(of: .month, for: first)?.start ?? first
            var result: [Bar] = []
            while start <= today, let end = calendar.date(byAdding: .month, value: 1, to: start) {
                let total = stats.total(from: start, to: end)
                result.append(Bar(start: start, words: total.words, minutes: total.minutes))
                start = end
            }
            return result
        }
    }

    private var unit: Calendar.Component {
        switch period {
        case .days: .day
        case .weeks: .weekOfYear
        case .months: .month
        }
    }

    private func perDay(_ stats: WritingStats) -> some View {
        let data = bars(stats)
        let selected = selectedBar.flatMap { date in data.first { calendar.isDate($0.start, equalTo: date, toGranularity: unit) } }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(period == .days ? "Wörter pro Tag" : period == .weeks ? "Wörter pro Woche" : "Wörter pro Monat").font(.headline)
                Spacer()
                Picker("Zeitraum", selection: $period) {
                    ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Chart {
                ForEach(data) { bar in
                    BarMark(x: .value("Zeitraum", bar.start, unit: unit), y: .value("Wörter", bar.words))
                        .cornerRadius(4)
                        .foregroundStyle(bar.words >= 0 ? Color.accentColor : Color.secondary.opacity(0.6))
                        .opacity(selected == nil || selected?.start == bar.start ? 1 : 0.45)
                }
                if period == .days, dailyGoal > 0 {
                    RuleMark(y: .value("Tagesziel", dailyGoal))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(.secondary)
                        .annotation(position: .top, alignment: .leading) {
                            Text("Tagesziel").font(.caption2).foregroundStyle(.secondary)
                        }
                }
                if let selected {
                    RuleMark(x: .value("Zeitraum", selected.start, unit: unit))
                        .foregroundStyle(.clear)
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            Callout(title: label(selected.start), lines: ["\(signed(selected.words)) Wörter", minutes(selected.minutes)])
                        }
                }
            }
            .chartXSelection(value: $selectedBar)
            .chartYAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel() } }
            .frame(height: 200)
            DisclosureGroup("Als Tabelle") {
                Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 3) {
                    ForEach(data.reversed().filter { $0.words != 0 || $0.minutes > 0 }) { bar in
                        GridRow {
                            Text(label(bar.start)).gridColumnAlignment(.leading)
                            Text("\(signed(bar.words)) Wörter")
                            Text(minutes(bar.minutes)).foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.callout.monospacedDigit())
                .padding(.top, 4)
            }
            .font(.callout)
        }
    }

    private func label(_ date: Date) -> String {
        switch period {
        case .days: date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        case .weeks: "Woche ab " + date.formatted(.dateTime.day().month(.abbreviated))
        case .months: date.formatted(.dateTime.month(.wide).year())
        }
    }

    // MARK: The book grows

    private func growth(_ stats: WritingStats) -> some View {
        let points = stats.progress
        let selected = selectedPoint.flatMap { date in points.last { $0.date <= date } }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Das Buch wächst").font(.headline)
            if points.count < 2 {
                Text("Noch zu wenige Versionen für einen Verlauf.").foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(points) { point in
                        LineMark(x: .value("Datum", point.date), y: .value("Wörter", point.words))
                            .interpolationMethod(.stepEnd)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .foregroundStyle(Color.accentColor)
                    }
                    if let goal = session.manifest.goal {
                        RuleMark(y: .value("Ziel", goal))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .foregroundStyle(.secondary)
                            .annotation(position: .bottom, alignment: .leading) {
                                Text("Ziel").font(.caption2).foregroundStyle(.secondary)
                            }
                    }
                    if let selected {
                        RuleMark(x: .value("Datum", selected.date))
                            .foregroundStyle(.secondary.opacity(0.5))
                            .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                Callout(title: selected.date.formatted(date: .abbreviated, time: .omitted), lines: ["\(selected.words.formatted()) Wörter"])
                            }
                        PointMark(x: .value("Datum", selected.date), y: .value("Wörter", selected.words))
                            .symbolSize(64)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .chartXSelection(value: $selectedPoint)
                .chartYScale(domain: 0...max(session.manifest.goal ?? 0, (points.map(\.words).max() ?? 0)) + 1)
                .chartYAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel() } }
                .frame(height: 180)
            }
        }
    }

    // MARK: Chapters

    private var chapters: some View {
        let rows = session.manifest.chapters.map { chapter in
            (title: chapter.title, words: chapter.sceneIDs.reduce(0) { $0 + (session.wordCounts[$1] ?? 0) },
             done: chapter.sceneIDs.filter { session.statuses[$0] == .done }.count, scenes: chapter.sceneIDs.count)
        }
        let largest = max(1, rows.map(\.words).max() ?? 1)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Kapitel").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.title).lineLimit(1).frame(maxWidth: 220, alignment: .leading)
                        GeometryReader { geometry in
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.accentColor)
                                .frame(width: max(2, geometry.size.width * CGFloat(row.words) / CGFloat(largest)))
                        }
                        .frame(height: 10)
                        Text(row.words.formatted()).monospacedDigit().gridColumnAlignment(.trailing)
                        Text("\(row.done)/\(row.scenes) fertig").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            .font(.callout)
        }
    }

    // MARK: Goals

    private var goals: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ziele").font(.headline)
            HStack {
                Text("Tagesziel")
                TextField("", value: $dailyGoal, format: .number, prompt: Text("z. B. 500"))
                    .frame(width: 90)
                Text("Wörter (auf diesem Mac)").foregroundStyle(.secondary)
            }
            HStack {
                Text("Ziel für das Buch")
                TextField("", text: $goalText, prompt: Text("z. B. 90.000"))
                    .frame(width: 90)
                    .onSubmit(saveBookGoal)
                Text("Wörter (reist mit dem Buch)").foregroundStyle(.secondary)
            }
        }
        .textFieldStyle(.roundedBorder)
        .onDisappear(perform: saveBookGoal)
    }

    private func saveBookGoal() {
        let digits = goalText.filter(\.isNumber)
        let goal = Int(digits).flatMap { $0 > 0 ? $0 : nil }
        guard goal != session.manifest.goal else { return }
        session.updateBook { $0.goal = goal }
    }

    // MARK: Formatting

    private func signed(_ n: Int) -> String { n > 0 ? "+\(n.formatted())" : n.formatted() }

    private func minutes(_ total: Int) -> String {
        guard total > 0 else { return "keine Schreibzeit" }
        return total < 60 ? "\(total) Min." : "\(total / 60) Std. \(total % 60) Min."
    }
}

private struct Tile: View {
    let title: String
    let value: String
    let unit: String
    let detail: String
    var progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(unit).foregroundStyle(.secondary)
            }
            if let progress {
                ProgressView(value: min(1, max(0, progress)))
                    .tint(progress >= 1 ? .green : .accentColor)
            }
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct Callout: View {
    let title: String
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold))
            ForEach(lines, id: \.self) { Text($0).font(.caption).monospacedDigit() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}
