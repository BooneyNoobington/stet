import Foundation

/// One version in the graphical history, with what to draw around it: which lane it sits in,
/// which lanes pass by, come in from above and go on below.
public struct GraphRow: Identifiable, Equatable {
    public let commit: Git.Commit
    /// The lane (column) of this version.
    public let lane: Int
    /// Lanes that run past this row without stopping here.
    public let passing: [Int]
    /// Lanes that end in this version from above (its children).
    public let incoming: [Int]
    /// Lanes this version continues in below (towards its parents).
    public let outgoing: [Int]
    /// On the main version's own line (first parents from its tip).
    public let isMain: Bool
    /// Fassungen whose newest version this is ("Hauptfassung", experiment names).
    public let branches: [String]
    public let milestones: [Milestone]
    public var id: String { commit.hash }
    /// An adoption or a merge with the server.
    public var isMerge: Bool { commit.parents.count > 1 }
}

public enum HistoryLayout {
    /// Lays out commits (newest first, children before parents) in lanes, the way history
    /// graphs do: a version continues its child's lane; a second parent (an adopted experiment)
    /// gets a lane of its own; lanes that meet at a version join it. `reserved` (the main
    /// version's newest commit) gets the first lane even if experiments are newer, so the main
    /// version is always the straight line on the left.
    public static func rows(_ commits: [Git.Commit], reserved: String? = nil) -> [(lane: Int, passing: [Int], incoming: [Int], outgoing: [Int])] {
        var lanes: [String?] = reserved.map { [$0] } ?? []
        // The reserved lane isn't drawn above its version (nothing leads into it from there).
        var waitingForReserved = reserved != nil
        var result: [(Int, [Int], [Int], [Int])] = []
        for commit in commits {
            let before = lanes
            var incoming = before.indices.filter { before[$0] == commit.hash }
            let lane = incoming.first ?? before.firstIndex(where: { $0 == nil }) ?? before.count
            var passing = before.indices.filter { before[$0] != nil && before[$0] != commit.hash }
            if waitingForReserved {
                passing.removeAll { $0 == 0 }
                if commit.hash == reserved {
                    incoming.removeAll { $0 == 0 }
                    waitingForReserved = false
                }
            }
            var after = before
            for index in incoming { after[index] = nil }
            while after.count <= lane { after.append(nil) }
            var outgoing: [Int] = []
            for (number, parent) in commit.parents.enumerated() {
                if number == 0 {
                    after[lane] = parent
                    outgoing.append(lane)
                } else if let existing = after.firstIndex(where: { $0 == parent }) {
                    outgoing.append(existing)
                } else {
                    let free = after.firstIndex(where: { $0 == nil }) ?? after.count
                    if free == after.count { after.append(parent) } else { after[free] = parent }
                    outgoing.append(free)
                }
            }
            while let last = after.last, last == nil { after.removeLast() }
            lanes = after
            result.append((lane, passing, incoming, outgoing))
        }
        return result
    }
}

extension Book {
    /// The whole history of all Fassungen (experiments too, shelved ones included), newest first.
    public func historyGraph(limit: Int = 500) async throws -> [GraphRow] {
        let commits = try await git.log("--branches", limit: limit)
        let ordered = try await topologicalOrder(commits)
        let main = await mainBranch()
        let layout = HistoryLayout.rows(ordered, reserved: await git.resolve("refs/heads/\(main)"))
        let mainLine = Set(((try? await git.run(["rev-list", "--first-parent", "refs/heads/\(main)"]))?.string ?? "")
            .split(separator: "\n").map(String.init))
        var tips: [String: [String]] = [:]
        if let mainTip = await git.resolve("refs/heads/\(main)") { tips[mainTip, default: []].append("Hauptfassung") }
        for experiment in await experiments() {
            tips[experiment.tip, default: []].append(experiment.isShelved ? "\(experiment.name) (abgelegt)" : experiment.name)
        }
        let milestones = Dictionary(grouping: await self.milestones(), by: \.commit)
        return zip(ordered, layout).map { commit, place in
            GraphRow(commit: commit, lane: place.lane, passing: place.passing, incoming: place.incoming, outgoing: place.outgoing,
                     isMain: mainLine.contains(commit.hash), branches: tips[commit.hash] ?? [], milestones: milestones[commit.hash] ?? [])
        }
    }

    /// `git log --branches` with children always before their parents (and otherwise by date).
    private func topologicalOrder(_ commits: [Git.Commit]) async throws -> [Git.Commit] {
        let order = try await git.run(["rev-list", "--topo-order", "--branches", "--max-count=\(commits.count)"]).string
            .split(separator: "\n").map(String.init)
        let byHash = Dictionary(commits.map { ($0.hash, $0) }, uniquingKeysWith: { first, _ in first })
        return order.compactMap { byHash[$0] }
    }
}
