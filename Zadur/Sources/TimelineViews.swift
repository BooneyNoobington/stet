import Charts
import ZadurCore
import SwiftUI

extension BookSession {
    func loadTimeline() async -> [TimelineEntry] {
        await persist()
        return book.timeline()
    }
}

struct TimelineWindow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if let session = model.session {
                TimelineView(session: session)
            } else {
                ContentUnavailableView("Kein Buch geöffnet", systemImage: "calendar",
                                       description: Text("Die Zeitleiste gehört zu einem Buch. Öffne zuerst ein Buch."))
            }
        }
        .frame(minWidth: 640, minHeight: 480)
    }
}

/// The scenes in story order, and how reading order moves through story time (flashbacks).
private struct TimelineView: View {
    @ObservedObject var session: BookSession
    @State private var entries: [TimelineEntry] = []
    @State private var storyOrder = true
    @State private var selectedPosition: Int?

    private var dated: [TimelineEntry] { entries.filter { $0.time != nil } }
    private var undated: [TimelineEntry] { entries.filter { $0.time == nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if entries.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if dated.isEmpty {
                ContentUnavailableView("Noch keine Daten", systemImage: "calendar.badge.plus",
                                       description: Text("Trag bei den Szenen (oder für ein ganzes Kapitel) unter „Fakten“ ein Datum ein, z. B. „14.7.1998“, „Juli 1998“ oder „Sommer 1978“ – dazu gern eine Uhrzeit."))
            } else {
                chart
                    .padding([.horizontal, .top], 20)
                    .padding(.bottom, 8)
                Divider()
                list
            }
        }
        .navigationTitle("Zeitleiste – \(session.manifest.title)")
        .toolbar {
            Picker("Reihenfolge", selection: $storyOrder) {
                Text("Wie in der Geschichte").tag(true)
                Text("Wie im Buch").tag(false)
            }
            .pickerStyle(.segmented)
            Button {
                Task { entries = await session.loadTimeline() }
            } label: {
                Label("Aktualisieren", systemImage: "arrow.clockwise")
            }
        }
        .task { entries = await session.loadTimeline() }
    }

    private var chart: some View {
        let selected = selectedPosition.flatMap { position in dated.first { $0.position == position } }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Erzählte Zeit, Szene für Szene").font(.headline)
            Text("Von links nach rechts liest man das Buch; je höher, desto später in der Geschichte. Ein Sprung nach unten ist eine Rückblende.")
                .font(.caption).foregroundStyle(.secondary)
            Chart {
                ForEach(dated) { entry in
                    LineMark(x: .value("Szene", entry.position), y: .value("Zeit", entry.time!.decimalYear))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .foregroundStyle(Color.accentColor.opacity(0.5))
                    PointMark(x: .value("Szene", entry.position), y: .value("Zeit", entry.time!.decimalYear))
                        .symbolSize(entry.isFlashback ? 90 : 60)
                        .symbol(entry.isFlashback ? .diamond : .circle)
                        .foregroundStyle(entry.isFlashback ? Color.orange : Color.accentColor)
                }
                if let selected {
                    RuleMark(x: .value("Szene", selected.position))
                        .foregroundStyle(.secondary.opacity(0.4))
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(selected.position). \(selected.title)").font(.caption.weight(.semibold))
                                Text(selected.timeText).font(.caption)
                                if selected.isFlashback { Text("Rückblende").font(.caption).foregroundStyle(.secondary) }
                            }
                            .padding(6)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        }
                }
            }
            .chartXSelection(value: $selectedPosition)
            .chartXScale(domain: 1...max(2, entries.count))
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: min(12, max(2, entries.count)))) { _ in AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel() } }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { if let year = value.as(Double.self) { Text(String(Int(year.rounded(.down)))) } }
                }
            }
            .chartXAxisLabel("Szene im Buch")
            .frame(height: 200)
        }
    }

    private var list: some View {
        let ordered = storyOrder
            ? dated.sorted { ($0.time!, $0.position) < ($1.time!, $1.position) }
            : dated.sorted { $0.position < $1.position }
        return List {
            Section(storyOrder ? "In der Reihenfolge der Geschichte" : "In der Reihenfolge des Buchs") {
                ForEach(ordered) { row($0) }
            }
            if !undated.isEmpty {
                Section {
                    ForEach(undated) { row($0) }
                } header: {
                    Text("Ohne Datum")
                } footer: {
                    Text("Diese Szenen haben (auch über ihr Kapitel) kein Datum, das Zadur lesen kann.")
                }
            }
        }
        .listStyle(.inset)
    }

    private func row(_ entry: TimelineEntry) -> some View {
        Button {
            AppModel.shared.openWindowAction?(id: "main")
            Task { await session.select(entry.sceneID) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(entry.timeText.isEmpty ? "–" : entry.timeText)
                    .monospacedDigit()
                    .frame(width: 170, alignment: .leading)
                    .foregroundStyle(entry.time == nil ? .secondary : .primary)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(entry.title)
                        if entry.isFlashback {
                            Label("Rückblende", systemImage: "arrow.uturn.backward")
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.orange)
                                .help("Rückblende: früher als die Szene davor")
                        }
                    }
                    Text([entry.chapterTitle, entry.place].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Szene \(entry.position)").font(.caption).foregroundStyle(.tertiary).monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
