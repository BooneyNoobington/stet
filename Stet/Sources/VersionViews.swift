import StetCore
import SwiftUI

// MARK: - Toolbar menu: which version of the book is open

struct VersionMenu: View {
    @ObservedObject var session: BookSession

    var body: some View {
        Menu {
            Button {
                Task { await session.switchTo(session.mainBranch) }
            } label: {
                checkmarked("Hauptfassung", session.branch == session.mainBranch)
            }

            if !session.activeExperiments.isEmpty {
                Section("Experimente") {
                    ForEach(session.activeExperiments) { experiment in
                        Button {
                            Task { await session.switchTo(experiment.branch) }
                        } label: {
                            checkmarked(experiment.name + (experiment.isAdopted ? " (übernommen)" : ""), session.branch == experiment.branch)
                        }
                        .disabled(!experiment.isStetBook)
                    }
                }
            }

            Divider()
            Button("Neues Experiment …") { session.sheet = .startExperiment }
            if let current = session.currentExperiment {
                Button("„\(current.name)“ übernehmen …") { session.sheet = .adopt(current) }
                Button("„\(current.name)“ ablegen") { Task { await session.shelve(current) } }
            }
            let others = session.activeExperiments.filter { $0.branch != session.branch && !$0.isAdopted }
            if !others.isEmpty {
                Menu("Experiment übernehmen") {
                    ForEach(others) { experiment in
                        Button(experiment.name + " …") { session.sheet = .adopt(experiment) }
                    }
                }
            }
            let shelvable = session.activeExperiments.filter { $0.branch != session.branch }
            if !shelvable.isEmpty {
                Menu("Experiment ablegen") {
                    ForEach(shelvable) { experiment in
                        Button(experiment.name + (experiment.isAdopted ? " (übernommen)" : "")) {
                            Task { await session.shelve(experiment) }
                        }
                    }
                }
            }
            if !session.shelvedExperiments.isEmpty {
                Menu("Abgelegte Experimente") {
                    ForEach(session.shelvedExperiments) { experiment in
                        Button("„\(experiment.name)“ zurückholen") { Task { await session.unshelve(experiment) } }
                    }
                }
            }
            Divider()
            Button("Meilenstein setzen …") { session.sheet = .milestone }
        } label: {
            Label(session.branchName, systemImage: session.isOnExperiment ? "flask" : "book.closed")
                .labelStyle(.titleAndIcon)
        }
        .help("Fassung wechseln, Experimente, Meilensteine")
    }

    @ViewBuilder
    private func checkmarked(_ title: String, _ checked: Bool) -> some View {
        if checked { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}

// MARK: - Start an experiment

struct StartExperimentSheet: View {
    @ObservedObject var session: BookSession
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var carryChanges = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Neues Experiment").font(.title2)
            Text("Ein Experiment ist eine eigene Fassung des Buchs. Was du dort schreibst, bleibt dort – bis du es übernimmst. Die \(session.branchName) bleibt unberührt.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Name", text: $name, prompt: Text("z. B. Kapitel 3 aus Maras Sicht"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(start)
            if session.hasChangesSinceVersion || session.isWritingPending {
                Picker("Deine Änderungen seit der letzten Version:", selection: $carryChanges) {
                    Text("ins Experiment mitnehmen").tag(true)
                    Text("vorher als Version der \(session.branchName) sichern").tag(false)
                }
                .pickerStyle(.radioGroup)
            }
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                Button("Experiment starten", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func start() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        dismiss()
        Task { await session.startExperiment(named: trimmed, carryChanges: carryChanges) }
    }
}

// MARK: - Milestone

struct MilestoneSheet: View {
    @ObservedObject var session: BookSession
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Meilenstein setzen").font(.title2)
            Text("Markiert den jetzigen Stand des Buchs, damit du ihn später wiederfindest – etwa die Fassung, die du dem Schreibclub gegeben hast.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Name", text: $name, prompt: Text("z. B. An den Schreibclub geschickt"))
                .textFieldStyle(.roundedBorder)
            TextField("Notiz (optional)", text: $note, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                Button("Meilenstein setzen") {
                    dismiss()
                    Task { await session.setMilestone(name: name, note: note) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

// MARK: - Adopt: overview and choice

struct AdoptSheet: View {
    @ObservedObject var session: BookSession
    let experiment: Experiment
    @Environment(\.dismiss) private var dismiss
    @State private var changes: ExperimentChanges?
    @State private var selected = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("„\(experiment.name)“ übernehmen").font(.title2)
            if let changes {
                if changes.isEmpty {
                    Text("Das Experiment enthält nichts, was die Hauptfassung nicht schon hat.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Das hat das Experiment verändert:").foregroundStyle(.secondary)
                    List {
                        ForEach(changes.scenes) { change in
                            Toggle(isOn: Binding(
                                get: { selected.contains(change.id) },
                                set: { if $0 { selected.insert(change.id) } else { selected.remove(change.id) } }
                            )) {
                                HStack {
                                    Text(change.title)
                                    Text(label(change.kind)).foregroundStyle(.secondary)
                                    Spacer()
                                    if change.wordsDelta != 0 {
                                        Text((change.wordsDelta > 0 ? "+" : "") + change.wordsDelta.formatted())
                                            .monospacedDigit()
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .disabled(change.kind == .removed || !experiment.isStetBook)
                        }
                        if changes.structureChanged {
                            Label("Aufbau des Buchs (Reihenfolge, Kapitel)", systemImage: "list.bullet.indent")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(changes.otherFiles, id: \.self) { file in
                            Label(file, systemImage: "doc").foregroundStyle(.secondary)
                        }
                    }
                    .frame(minHeight: 160, maxHeight: 280)
                    if changes.mainChangedScenes > 0 {
                        Text("Die Hauptfassung hat seit Beginn des Experiments \(changes.mainChangedScenes) Szene(n) geändert. Beim Übernehmen wird beides zusammengeführt. Wo beide dieselbe Stelle geändert haben, entscheidest du.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            }
            HStack {
                Button("Abbrechen", role: .cancel) { dismiss() }
                Spacer()
                Button("Nur ausgewählte Szenen") {
                    let ids = changes?.scenes.filter { selected.contains($0.id) && $0.kind != .removed }.map(\.id) ?? []
                    dismiss()
                    Task { await session.adoptScenes(ids, from: experiment) }
                }
                .disabled(selected.isEmpty || !experiment.isStetBook || changes?.scenes.allSatisfy { selected.contains($0.id) || $0.kind == .removed } == true)
                .help("Kopiert nur die ausgewählten Szenen in die Hauptfassung")
                Button("Alles übernehmen") {
                    dismiss()
                    Task { await session.adoptAll(experiment) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(changes?.isEmpty ?? true)
            }
        }
        .padding(24)
        .frame(width: 560)
        .task {
            let loaded = await session.changes(in: experiment)
            changes = loaded
            selected = Set(loaded?.scenes.filter { $0.kind != .removed }.map(\.id) ?? [])
        }
    }

    private func label(_ kind: ExperimentChanges.SceneChange.Kind) -> String {
        switch kind {
        case .added: "neu"
        case .edited: "bearbeitet"
        case .removed: "entfernt"
        }
    }
}

// MARK: - Conflicts: decide passage by passage

struct ConflictSheet: View {
    @ObservedObject var session: BookSession
    @State private var selection: String?

    var body: some View {
        if let adoption = session.adoption {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(adoption.fromServer ? "Mit dem Server zusammenführen" : "„\(adoption.name)“ übernehmen").font(.title2)
                    Text("Hier haben \(adoption.mainLabel) und \(adoption.otherLabel) dieselbe Stelle unterschiedlich geändert. Entscheide, was bleiben soll – alles andere ist schon zusammengeführt.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                Divider()
                HSplitView {
                    List(adoption.conflicts, selection: $selection) { conflict in
                        HStack {
                            Image(systemName: adoption.isResolved(conflict) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(adoption.isResolved(conflict) ? .green : .secondary)
                            Text(session.title(of: conflict)).lineLimit(1)
                        }
                        .tag(conflict.path)
                    }
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 300)

                    Group {
                        if let conflict = adoption.conflicts.first(where: { $0.path == (selection ?? adoption.conflicts.first?.path) }) {
                            ConflictDetail(session: session, conflict: conflict, adoption: adoption)
                        }
                    }
                    .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                }
                Divider()
                HStack {
                    Button(adoption.fromServer ? "Abbrechen" : "Übernahme abbrechen") { Task { await session.cancelAdoption() } }
                        .help("Nichts wird verändert; beide Seiten bleiben, wie sie sind.")
                    Spacer()
                    Text(adoption.openCount == 0 ? "Alles entschieden" : "Noch \(adoption.openCount) offen")
                        .foregroundStyle(.secondary)
                    Button(adoption.fromServer ? "Zusammenführen abschließen" : "Übernahme abschließen") { Task { await session.finishAdoption() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(adoption.openCount > 0 || session.isBusy)
                }
                .padding(16)
            }
            .frame(minWidth: 820, idealWidth: 960, minHeight: 560, idealHeight: 680)
            .interactiveDismissDisabled()
        }
    }
}

private struct ConflictDetail: View {
    @ObservedObject var session: BookSession
    let conflict: MergeConflict
    let adoption: BookSession.Adoption

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch conflict.kind {
                case .text(let segments):
                    ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                        switch segment {
                        case .same(let text):
                            ContextText(text: text)
                        case .conflict(let main, let experiment):
                            PassageChoice(
                                main: main, experiment: experiment,
                                mainLabel: adoption.mainLabel, otherLabel: adoption.otherLabel,
                                choice: adoption.passages[conflict.path]?[index],
                                choose: { session.choose($0, for: conflict, passage: index) }
                            )
                        }
                    }
                case .deletedInMain:
                    WholeChoice(
                        text: "\(adoption.mainLabel): Szene gelöscht. \(adoption.otherLabel): Szene bearbeitet.",
                        options: [("Szene behalten", .keep), ("Szene löschen", .delete)],
                        choice: adoption.wholeFile[conflict.path],
                        choose: { session.choose($0, forWhole: conflict) }
                    )
                case .deletedInExperiment:
                    WholeChoice(
                        text: "\(adoption.otherLabel): Szene gelöscht. \(adoption.mainLabel): Szene bearbeitet.",
                        options: [("Szene behalten", .keep), ("Szene löschen", .delete)],
                        choice: adoption.wholeFile[conflict.path],
                        choose: { session.choose($0, forWhole: conflict) }
                    )
                case .whole:
                    WholeChoice(
                        text: "„\(conflict.path)“ wurde auf beiden Seiten geändert und lässt sich nicht absatzweise zusammenführen.",
                        options: [(adoption.mainLabel, .main), (adoption.otherLabel, .experiment)],
                        choice: adoption.wholeFile[conflict.path],
                        choose: { session.choose($0, forWhole: conflict) }
                    )
                }
            }
            .padding(20)
        }
    }
}

/// Unchanged text around a conflict, shortened to its first and last paragraph.
private struct ContextText: View {
    let text: String

    var body: some View {
        let paragraphs = SceneFile.parse(id: "", text: text).body
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        VStack(alignment: .leading, spacing: 6) {
            if paragraphs.count <= 2 {
                ForEach(paragraphs, id: \.self) { Text($0) }
            } else {
                Text(paragraphs.first!)
                Text("… \(paragraphs.count - 2) unveränderte Absätze …").italic().font(.callout)
                Text(paragraphs.last!)
            }
        }
        .font(.system(size: 14, design: .serif))
        .foregroundStyle(.secondary)
        .lineLimit(4)
    }
}

private struct PassageChoice: View {
    let main: String
    let experiment: String
    var mainLabel = "Hauptfassung"
    var otherLabel = "Experiment"
    let choice: BookSession.Adoption.Choice?
    let choose: (BookSession.Adoption.Choice) -> Void
    @State private var editing = false
    @State private var custom = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                side(mainLabel, main, chosen: choice == .main || choice == .both) { choose(.main) }
                side(otherLabel, experiment, chosen: choice == .experiment || choice == .both) { choose(.experiment) }
            }
            HStack {
                Button("Beide behalten") { choose(.both) }
                Button("Selbst formulieren …") {
                    if case .custom(let text)? = choice { custom = text } else { custom = main.trimmingCharacters(in: .newlines) }
                    editing = true
                }
                Spacer()
                if case .custom? = choice {
                    Label("Eigene Fassung", systemImage: "pencil").foregroundStyle(.green)
                }
            }
            .controlSize(.small)
            if editing {
                TextEditor(text: $custom)
                    .font(.system(size: 14, design: .serif))
                    .frame(minHeight: 90)
                    .border(.quaternary)
                HStack {
                    Spacer()
                    Button("Abbrechen") { editing = false }
                    Button("Übernehmen") {
                        choose(.custom(custom))
                        editing = false
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
    }

    private func side(_ label: String, _ text: String, chosen: Bool, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text.trimmingCharacters(in: .newlines).isEmpty ? "(nichts)" : text.trimmingCharacters(in: .newlines))
                .font(.system(size: 14, design: .serif))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(chosen ? "Gewählt" : "Diese Fassung", action: action)
                .controlSize(.small)
                .tint(chosen ? .green : nil)
                .buttonStyle(.borderedProminent)
                .disabled(chosen)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(chosen ? Color.green.opacity(0.7) : Color.secondary.opacity(0.2), lineWidth: chosen ? 2 : 1)
        )
    }
}

private struct WholeChoice: View {
    let text: String
    let options: [(String, ConflictResolution)]
    let choice: ConflictResolution?
    let choose: (ConflictResolution) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text)
            HStack {
                ForEach(options, id: \.0) { title, resolution in
                    Button(title) { choose(resolution) }
                        .buttonStyle(.borderedProminent)
                        .tint(choice == resolution ? .green : nil)
                }
            }
        }
    }
}
