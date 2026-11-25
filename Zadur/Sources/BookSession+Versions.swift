import Foundation
import ZadurCore

/// Experiments, adoption and milestones for the open book.
extension BookSession {
    enum Sheet: Identifiable, Equatable {
        case startExperiment
        case adopt(Experiment)
        case conflicts
        case milestone
        case server
        case export
        case backup

        var id: String {
            switch self {
            case .startExperiment: "start"
            case .adopt(let e): "adopt-\(e.branch)"
            case .conflicts: "conflicts"
            case .milestone: "milestone"
            case .server: "server"
            case .export: "export"
            case .backup: "backup"
            }
        }
    }

    /// An open adoption: the places to decide and what the writer chose so far.
    struct Adoption: Equatable {
        enum Choice: Equatable {
            case main, experiment, both
            case custom(String)
        }

        let branch: String
        let name: String
        var conflicts: [MergeConflict]
        /// How the two sides are called in the decision window.
        var mainLabel = "Hauptfassung"
        var otherLabel = "Experiment"
        var fromServer = false
        /// Per file: the choice for each conflicting passage (by segment index).
        var passages: [String: [Int: Choice]] = [:]
        /// Per file, for whole-file decisions (deleted on one side, or not mergeable as text).
        var wholeFile: [String: ConflictResolution] = [:]

        func isResolved(_ conflict: MergeConflict) -> Bool {
            switch conflict.kind {
            case .text(let segments):
                let needed = segments.indices.filter { if case .conflict = segments[$0] { return true } else { return false } }
                return needed.allSatisfy { passages[conflict.path]?[$0] != nil }
            default:
                return wholeFile[conflict.path] != nil
            }
        }

        var openCount: Int { conflicts.filter { !isResolved($0) }.count }

        func resolution(for conflict: MergeConflict) -> ConflictResolution? {
            switch conflict.kind {
            case .text(let segments):
                guard isResolved(conflict) else { return nil }
                let text = segments.enumerated().map { index, segment -> String in
                    switch segment {
                    case .same(let text):
                        return text
                    case .conflict(let main, let experiment):
                        switch passages[conflict.path]?[index] {
                        case .main?: return main
                        case .experiment?: return experiment
                        case .both?: return main + (main.hasSuffix("\n") ? "\n" : "\n\n") + experiment
                        case .custom(let text)?: return text.hasSuffix("\n") ? text : text + "\n"
                        case nil: return main
                        }
                    }
                }.joined()
                return .text(text)
            default:
                return wholeFile[conflict.path]
            }
        }
    }

    var isOnExperiment: Bool { branch != mainBranch }
    var activeExperiments: [Experiment] { experiments.filter { !$0.isShelved } }
    var shelvedExperiments: [Experiment] { experiments.filter(\.isShelved) }
    var currentExperiment: Experiment? { experiments.first { $0.branch == branch } }

    /// The writer's own milestone at a version (preferred), or an export mark.
    func milestone(at commit: String) -> Milestone? {
        milestones.first { $0.commit == commit && !$0.isExport } ?? milestones.first { $0.commit == commit }
    }

    // MARK: - Refreshing

    func refreshVersions() async {
        mainBranch = await book.mainBranch()
        branch = await book.currentBranch()
        branchName = await book.displayName(ofBranch: branch)
        experiments = await book.experiments()
        milestones = await book.milestones()
    }

    /// After the book's files changed underneath (switch, adoption): reload everything.
    func reloadAfterVersionChange() async {
        try? book.reload()
        reloadSceneInfo()
        let keep = selectedSceneID.flatMap { manifest.sceneIDs.contains($0) ? $0 : nil }
        if let target = keep ?? manifest.sceneIDs.first {
            await select(target, force: true)
        }
        hasChangesSinceVersion = !((try? await book.git.changedPaths()) ?? []).isEmpty
        lastVersion = try? await book.git.log(limit: 1).first
        await refreshVersions()
        await loadHistory()
        loadWiki()
        await pushWikiTerms()
    }

    private func perform(_ work: () async throws -> Void) async {
        isBusy = true
        isChangingFiles = true
        defer {
            isBusy = false
            isChangingFiles = false
        }
        do {
            try await work()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Experiments

    func startExperiment(named name: String, carryChanges: Bool) async {
        await persist()
        await perform {
            try await book.startExperiment(named: name, carryChanges: carryChanges)
            await reloadAfterVersionChange()
            showToast(Toast(message: "Experiment „\(branchName)“ gestartet"))
            scheduleSync()
        }
    }

    func switchTo(_ target: String) async {
        guard target != branch else { return }
        await persist()
        await perform {
            try await book.switchTo(target)
            await reloadAfterVersionChange()
        }
    }

    func shelve(_ experiment: Experiment) async {
        await persist()
        await perform {
            let wasCurrent = experiment.branch == branch
            try await book.shelve(experiment.branch)
            if wasCurrent { await reloadAfterVersionChange() } else { await refreshVersions() }
            showToast(Toast(message: "„\(experiment.name)“ abgelegt"))
            scheduleSync()
        }
    }

    func unshelve(_ experiment: Experiment) async {
        await perform {
            try await book.unshelve(experiment.branch)
            await refreshVersions()
        }
    }

    // MARK: - Adopting

    func changes(in experiment: Experiment) async -> ExperimentChanges? {
        try? await book.changes(in: experiment.branch)
    }

    func adoptAll(_ experiment: Experiment) async {
        await persist()
        await perform {
            let result = try await book.adopt(experiment.branch)
            switch result {
            case .adopted:
                await reloadAfterVersionChange()
                showToast(Toast(message: "Experiment „\(experiment.name)“ übernommen"))
                scheduleSync()
            case .nothingNew:
                await reloadAfterVersionChange()
                showToast(Toast(message: "Alles aus „\(experiment.name)“ ist schon in der Hauptfassung"))
            case .conflicts(let conflicts):
                adoption = Adoption(branch: experiment.branch, name: experiment.name, conflicts: conflicts)
                sheet = .conflicts
            }
        }
    }

    func adoptScenes(_ ids: [String], from experiment: Experiment) async {
        await persist()
        await perform {
            try await book.adoptScenes(ids, from: experiment.branch)
            await reloadAfterVersionChange()
            showToast(Toast(message: ids.count == 1 ? "Szene übernommen" : "\(ids.count) Szenen übernommen"))
            scheduleSync()
        }
    }

    func resumeAdoptionIfNeeded() async {
        guard let info = await book.adoptionInProgress(), let conflicts = try? await book.currentConflicts() else { return }
        adoption = info.fromServer
            ? Adoption(branch: info.branch, name: info.name, conflicts: conflicts, mainLabel: "Dieser Mac", otherLabel: "Server", fromServer: true)
            : Adoption(branch: info.branch, name: info.name, conflicts: conflicts)
    }

    func choose(_ choice: Adoption.Choice, for conflict: MergeConflict, passage index: Int) {
        adoption?.passages[conflict.path, default: [:]][index] = choice
    }

    func choose(_ resolution: ConflictResolution, forWhole conflict: MergeConflict) {
        adoption?.wholeFile[conflict.path] = resolution
    }

    func finishAdoption() async {
        guard let adoption, adoption.openCount == 0 else { return }
        await perform {
            for conflict in adoption.conflicts {
                if let resolution = adoption.resolution(for: conflict) {
                    try await book.resolve(conflict.path, with: resolution)
                }
            }
            try await book.finishAdoption()
            self.adoption = nil
            sheet = nil
            await reloadAfterVersionChange()
            if adoption.fromServer {
                syncState = .done(Date())
                showToast(Toast(message: "Mit dem Server zusammengeführt"))
            } else {
                showToast(Toast(message: "Experiment „\(adoption.name)“ übernommen"))
            }
            scheduleSync()
        }
    }

    func cancelAdoption() async {
        await perform {
            try await book.abortAdoption()
            adoption = nil
            sheet = nil
            await reloadAfterVersionChange()
            showToast(Toast(message: "Übernahme abgebrochen – nichts wurde verändert"))
        }
    }

    // MARK: - Milestones

    func setMilestone(name: String, note: String) async {
        await persist()
        await perform {
            let milestone = try await book.setMilestone(name: name, note: note)
            await reloadAfterVersionChange()
            showToast(Toast(message: "Meilenstein „\(milestone?.name ?? name)“ gesetzt"))
            scheduleSync()
            Task { await milestoneSet() }
        }
    }

    /// Title for a conflict entry: the scene's title in either version, or the file path.
    func title(of conflict: MergeConflict) -> String {
        guard let id = conflict.sceneID else { return conflict.path }
        if let title = titles[id] { return title }
        if case .text(let segments) = conflict.kind, case .same(let head)? = segments.first {
            return SceneFile.parse(id: id, text: head + "\n").title ?? id
        }
        return id
    }
}
