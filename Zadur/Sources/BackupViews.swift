import AppKit
import ZadurCore
import SwiftUI
import UniformTypeIdentifiers

extension BookSession {
    /// A folder from when Zadur was called Stet goes on being used.
    static let defaultBackupFolder: URL = {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let old = documents.appendingPathComponent("Stet-Backups", isDirectory: true)
        return FileManager.default.fileExists(atPath: old.path) ? old : documents.appendingPathComponent("Zadur-Backups", isDirectory: true)
    }()
    static let autoBackupInterval: TimeInterval = 20 * 60 * 60

    struct BackupSettings: Equatable {
        var automatic = false
        var folder = BookSession.defaultBackupFolder
        var keep = 10
        var last: Date?
    }

    var backupSettings: BackupSettings {
        let state = LocalState.load(for: book)
        return BackupSettings(
            automatic: state.autoBackup ?? false,
            folder: state.backupFolder.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultBackupFolder,
            keep: state.backupKeep ?? 10,
            last: state.lastAutoBackup
        )
    }

    func save(_ settings: BackupSettings) {
        var state = LocalState.load(for: book)
        state.autoBackup = settings.automatic
        state.backupFolder = settings.folder.path
        state.backupKeep = settings.keep
        state.save(for: book)
        objectWillChange.send()
    }

    /// A backup into the configured folder (creating it if needed), then rotation.
    @discardableResult
    func backupToFolder() async -> URL? {
        await persist()
        let settings = backupSettings
        do {
            try? FileManager.default.createDirectory(at: settings.folder, withIntermediateDirectories: true)
            let file = try await Backup.create(book, in: settings.folder)
            try Backup.rotate(in: settings.folder, for: book, keep: settings.keep)
            var state = LocalState.load(for: book)
            state.lastAutoBackup = Date()
            state.save(for: book)
            backupWarning = nil
            objectWillChange.send()
            return file
        } catch {
            backupWarning = error.localizedDescription
            return nil
        }
    }

    /// "Backup sichern …" to a file the writer picks.
    func backup(to file: URL) async -> URL? {
        await persist()
        isBusy = true
        defer { isBusy = false }
        do {
            return try await Backup.create(book, to: file)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// At most once a day, on opening and after saving a version. Quiet: problems show as a hint.
    func maybeAutoBackup() async {
        let settings = backupSettings
        guard settings.automatic, adoption == nil else { return }
        if let last = settings.last, Date().timeIntervalSince(last) < Self.autoBackupInterval { return }
        if await backupToFolder() != nil {
            showToast(Toast(message: "Backup angelegt"))
        }
    }

    var backupSummary: String {
        let settings = backupSettings
        guard settings.automatic else { return "Nur von Hand" }
        let last = settings.last.map { "zuletzt " + $0.formatted(.relative(presentation: .named)) } ?? "noch keins"
        return "Täglich, \(settings.keep) behalten · \(last)"
    }
}

struct BackupSheet: View {
    @ObservedObject var session: BookSession
    @Environment(\.dismiss) private var dismiss
    @State private var settings = BookSession.BackupSettings()
    @State private var backups: [Backup.Info] = []
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Backups").font(.title2)
            Text("Ein Backup ist eine einzige ZIP-Datei mit dem ganzen Buch: Historie, Experimente, Meilensteine, Feedback. Eine einzelne Datei verträgt sich mit Nextcloud, iCloud & Co. – das Backup darf also dort liegen, oder auf einer externen Platte.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Automatisch einmal am Tag sichern (beim Öffnen oder nach ⌘S)", isOn: $settings.automatic)

            HStack {
                Text("Ordner:")
                Text(settings.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Ändern …") { chooseFolder() }
            }
            Stepper("Die letzten \(settings.keep) Backups behalten", value: $settings.keep, in: 1...100)

            if let warning = session.backupWarning {
                Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }

            GroupBox {
                if backups.isEmpty {
                    Text("Noch keine Backups in diesem Ordner.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(backups.prefix(6)) { info in
                            HStack {
                                Text(info.date.formatted(date: .abbreviated, time: .shortened))
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: Int64(info.size), countStyle: .file)).foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                        if backups.count > 6 { Text("… und \(backups.count - 6) weitere").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            } label: {
                HStack {
                    Text("Vorhanden")
                    Spacer()
                    Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([backups.first?.url ?? settings.folder]) }
                        .controlSize(.small)
                        .disabled(!FileManager.default.fileExists(atPath: settings.folder.path))
                }
            }

            HStack {
                Button(working ? "Wird gesichert …" : "Jetzt sichern") {
                    Task {
                        working = true
                        session.save(settings)
                        await session.backupToFolder()
                        reload()
                        working = false
                    }
                }
                .disabled(working)
                Spacer()
                Button("Fertig") {
                    session.save(settings)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 540)
        .onAppear {
            settings = session.backupSettings
            reload()
        }
        .onChange(of: settings.folder) { reload() }
    }

    private func reload() {
        backups = Backup.list(in: settings.folder, for: session.book)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Wählen"
        panel.directoryURL = settings.folder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.folder = url
    }
}

extension AppModel {
    /// "Backup sichern …": one ZIP to a place the writer picks.
    func showBackupPanel() {
        guard let session else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = Backup.fileName(for: session.book)
        panel.prompt = "Sichern"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            if let file = await session.backup(to: url) {
                NSWorkspace.shared.activateFileViewerSelecting([file])
            }
        }
    }

    /// "Backup wiederherstellen …": unpack a ZIP into a folder and open the book.
    func showRestorePanel() {
        let source = NSOpenPanel()
        source.allowedContentTypes = [.zip]
        source.message = "Wähle ein Zadur-Backup (.crea.zip oder .stet.zip)."
        guard source.runModal() == .OK, let zip = source.url else { return }
        let target = NSOpenPanel()
        target.canChooseDirectories = true
        target.canChooseFiles = false
        target.canCreateDirectories = true
        target.prompt = "Hierher wiederherstellen"
        target.message = "Wohin soll das Buch? Ein vorhandenes Buch gleichen Namens bleibt unangetastet."
        guard target.runModal() == .OK, let folder = target.url else { return }
        Task {
            busyMessage = "Backup wird wiederhergestellt …"
            defer { busyMessage = nil }
            do {
                let book = try await Backup.restore(zip, into: folder)
                await open(book)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
