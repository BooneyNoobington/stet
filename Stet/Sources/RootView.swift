import StetCore
import SwiftUI

struct RootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var editor: EditorController

    var body: some View {
        Group {
            if let session = model.session {
                BookView(session: session, editor: editor)
            } else {
                WelcomeView(model: model)
            }
        }
        .overlay {
            if let message = model.busyMessage {
                ZStack {
                    Color.black.opacity(0.15).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(message)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .alert("Fehler", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(item: Binding(get: { model.importReport.map(IdentifiedReport.init) }, set: { model.importReport = $0?.report })) { item in
            ImportReportView(report: item.report) { model.importReport = nil }
        }
        .sheet(isPresented: $model.showCloneSheet) { CloneSheet(model: model) }
    }
}

private struct IdentifiedReport: Identifiable {
    let report: Importer.Report
    var id: String { report.title }
}

struct WelcomeView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 6) {
                Text("Stet")
                    .font(.system(size: 54, weight: .regular, design: .serif))
                Text("lass es stehen")
                    .font(.system(.title3, design: .serif).italic())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button("Neues Buch …") { model.showNewBookPanel() }
                Button("Buch öffnen …") { model.showOpenPanel() }
                Button("Ordner importieren …") { model.showImportPanel() }
                Button("Vom Server holen …") { model.showCloneSheet = true }
            }
            .controlSize(.large)

            if !model.recentBooks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Zuletzt geöffnet").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.recentBooks, id: \.self) { url in
                        Button {
                            Task { await model.open(url) }
                        } label: {
                            HStack {
                                Image(systemName: "book.closed")
                                Text(url.deletingPathExtension().lastPathComponent)
                                Spacer()
                                Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 4)
                    }
                }
                .frame(width: 460)
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ImportReportView: View {
    let report: Importer.Report
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("„\(report.title)“ ist jetzt ein Stet-Buch").font(.title2)
            Text("\(report.chapters) Kapitel · \(report.scenes) Szenen · \(report.words.formatted()) Wörter")
                .foregroundStyle(.secondary)
            if report.commitsKept > 0 {
                Label("Die ganze bisherige Historie ist dabei: \(report.commitsKept) Versionen.", systemImage: "clock.arrow.circlepath")
            }
            if !report.experiments.isEmpty {
                Label("Als Experiment übernommen: " + report.experiments.joined(separator: ", "), systemImage: "arrow.triangle.branch")
            }
            if !report.moved.isEmpty {
                Label("Verschoben: " + report.moved.joined(separator: "; "), systemImage: "folder")
            }
            if !report.removed.isEmpty {
                Label("Durch Stet ersetzt (bleiben im Verlauf): " + report.removed.joined(separator: ", "), systemImage: "trash")
            }
            if !report.formerRemotes.isEmpty {
                Label("Der Server des Originals ist nicht verbunden, damit nichts versehentlich dorthin geschickt wird: "
                      + report.formerRemotes.joined(separator: ", "), systemImage: "server.rack")
            }
            ForEach(report.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            Text("Der ursprüngliche Ordner wurde nicht verändert.").foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Los geht’s", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
