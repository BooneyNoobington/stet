import ZadurCore
import SwiftUI

struct HistoryGraphWindow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if let session = model.session {
                HistoryGraphView(session: session)
            } else {
                ContentUnavailableView("Kein Buch geöffnet", systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text("Der Verlauf gehört zu einem Buch. Öffne zuerst ein Buch."))
            }
        }
        .frame(minWidth: 620, minHeight: 440)
    }
}

/// Every version of every Fassung on one time axis (newest at the top): the main version as the
/// line on the left, experiments branching off and, once adopted, flowing back in.
private struct HistoryGraphView: View {
    @ObservedObject var session: BookSession
    @State private var rows: [GraphRow] = []
    @State private var loaded = false

    private let rowHeight: CGFloat = 46
    private let laneWidth: CGFloat = 16

    private var laneCount: Int {
        rows.map { ([$0.lane] + $0.passing + $0.incoming + $0.outgoing).max() ?? 0 }.max().map { $0 + 1 } ?? 1
    }

    var body: some View {
        Group {
            if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                ContentUnavailableView("Noch keine Versionen", systemImage: "clock", description: Text("⌘S sichert eine Version des ganzen Buchs."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            HStack(alignment: .center, spacing: 10) {
                                GraphCell(row: row, rowHeight: rowHeight, laneWidth: laneWidth)
                                    .frame(width: CGFloat(laneCount) * laneWidth + 8, height: rowHeight)
                                text(row)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14)
                            .help(row.commit.subject + (row.commit.note.map { "\n\n" + $0 } ?? ""))
                        }
                    }
                    .padding(.vertical, 10)
                }
            }
        }
        .navigationTitle("Verlauf – \(session.manifest.title)")
        .toolbar {
            HStack(spacing: 14) {
                legend(Color.accentColor, "Hauptfassung")
                legend(.purple, "Experiment")
            }
            Button {
                Task { await load() }
            } label: {
                Label("Aktualisieren", systemImage: "arrow.clockwise")
            }
        }
        .task { await load() }
    }

    private func load() async {
        rows = (try? await session.book.historyGraph()) ?? []
        loaded = true
    }

    private func legend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func text(_ row: GraphRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                ForEach(row.branches, id: \.self) { name in
                    Text(name)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background((name == "Hauptfassung" ? Color.accentColor : Color.purple).opacity(0.15), in: Capsule())
                }
                ForEach(row.milestones) { milestone in
                    Label(milestone.name, systemImage: milestone.isExport ? "square.and.arrow.up" : "flag.fill")
                        .font(.caption)
                        .foregroundStyle(milestone.isExport ? Color.secondary : Color.purple)
                }
                Text(row.commit.subject).lineLimit(1)
            }
            HStack(spacing: 8) {
                Text(row.commit.date.formatted(date: .abbreviated, time: .shortened))
                if let delta = row.commit.trailers["Words-Delta"], delta != "0" {
                    Text("\(delta) Wörter").monospacedDigit()
                }
                if row.isMerge { Text(row.isMain ? "Übernahme" : "Zusammenführung") }
                if let note = row.commit.note { Text(note).italic().lineLimit(1) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// The lanes of one row: lines passing by, coming in from above, going on below, and the version's dot.
private struct GraphCell: View {
    let row: GraphRow
    let rowHeight: CGFloat
    let laneWidth: CGFloat

    var body: some View {
        Canvas { context, size in
            func x(_ lane: Int) -> CGFloat { CGFloat(lane) * laneWidth + laneWidth / 2 + 4 }
            let middle = size.height / 2
            var lines = Path()
            for lane in row.passing {
                lines.move(to: CGPoint(x: x(lane), y: 0))
                lines.addLine(to: CGPoint(x: x(lane), y: size.height))
            }
            for lane in row.incoming {
                lines.move(to: CGPoint(x: x(lane), y: 0))
                lines.addCurve(to: CGPoint(x: x(row.lane), y: middle),
                               control1: CGPoint(x: x(lane), y: middle * 0.6), control2: CGPoint(x: x(row.lane), y: middle * 0.4))
            }
            for lane in row.outgoing {
                lines.move(to: CGPoint(x: x(row.lane), y: middle))
                lines.addCurve(to: CGPoint(x: x(lane), y: size.height),
                               control1: CGPoint(x: x(row.lane), y: middle + middle * 0.6), control2: CGPoint(x: x(lane), y: middle + middle * 0.4))
            }
            context.stroke(lines, with: .color(.secondary.opacity(0.55)), lineWidth: 2)
            let color: Color = row.isMain ? .accentColor : .purple
            let radius: CGFloat = row.isMerge ? 6 : 5
            let dot = Path(ellipseIn: CGRect(x: x(row.lane) - radius, y: middle - radius, width: radius * 2, height: radius * 2))
            context.fill(dot, with: .color(row.isMerge ? Color(nsColor: .windowBackgroundColor) : color))
            context.stroke(dot, with: .color(color), lineWidth: 2)
        }
        .accessibilityHidden(true)
    }
}
