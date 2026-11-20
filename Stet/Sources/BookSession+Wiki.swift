import AppKit
import StetCore

/// The wiki and quick facts of the open book.
extension BookSession {
    func loadWiki() {
        wiki = book.wikiEntries()
    }

    /// Sends every name (titles and aliases) to the editor for underlining and fact cards.
    func pushWikiTerms() async {
        let terms: [[String: Any]] = wiki.flatMap { entry in
            entry.names.map { name in
                [
                    "name": name, "id": entry.id, "title": entry.title, "kind": entry.kind.rawValue,
                    "facts": entry.facts.map { [$0.key, $0.value] }, "summary": entry.summary,
                ] as [String: Any]
            }
        }
        await editor.setWikiTerms(terms)
    }

    func saveWiki(_ entry: WikiEntry) {
        do {
            try book.saveWiki(entry)
            hasChangesSinceVersion = true
            loadWiki()
            Task { await pushWikiTerms() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func createWiki(title: String, kind: WikiKind) -> WikiEntry? {
        do {
            let entry = try book.createWiki(title: title, kind: kind)
            hasChangesSinceVersion = true
            loadWiki()
            Task { await pushWikiTerms() }
            return entry
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func deleteWiki(_ entry: WikiEntry) {
        do {
            try book.deleteWiki(entry)
            hasChangesSinceVersion = true
            loadWiki()
            Task { await pushWikiTerms() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func appearances(of entry: WikiEntry) -> [(sceneID: String, title: String, count: Int)] {
        book.appearances(of: entry).map { ($0.sceneID, titles[$0.sceneID] ?? $0.sceneID, $0.count) }
    }

    /// Opens a scene and selects the first occurrence of one of the entry's names.
    func jump(to entry: WikiEntry, in sceneID: String) async {
        await select(sceneID)
        guard let body = currentScene?.body, let regex = WikiMatcher.regex(for: entry.names),
              let match = WikiMatcher.matches(in: body, regex: regex).first
        else { return }
        await editor.select(from: match.range.location, to: match.range.location + match.range.length)
    }

    /// "Wiki-Eintrag aus Auswahl": the selected name gets an entry (or its existing one opens).
    func wikiEntryFromSelection() async -> WikiEntry? {
        let selected = await editor.selectedText().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !selected.isEmpty, selected.count <= 80, !selected.contains("\n") else {
            errorMessage = "Markiere zuerst einen Namen oder Begriff im Text."
            return nil
        }
        if let existing = book.wikiEntry(named: selected) { return existing }
        return createWiki(title: selected, kind: .character)
    }

    /// The entry a fact value points to ("[[Hafen]]" or simply "Hafen").
    func wikiEntry(for fact: Fact) -> WikiEntry? {
        let name = fact.linkedTitle ?? fact.value
        return wiki.first { $0.names.contains(name) }
    }

    // MARK: Right-click menu

    /// Wiki items for the editor's right-click menu: open the entry under the mouse or for the
    /// clicked name, or put the name into the wiki (as figure, place, term or note).
    func contextMenuItems(text: String, wikiID: String?) -> [NSMenuItem] {
        if let wikiID, let entry = wiki.first(where: { $0.id == wikiID }) {
            return [ActionMenuItem("„\(entry.title)“ im Wiki öffnen") { AppModel.shared.openWiki(entry.id) }]
        }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard name.count >= 2, name.count <= 80, !name.contains("\n") else { return [] }
        if let entry = book.wikiEntry(named: name) {
            return [ActionMenuItem("„\(entry.title)“ im Wiki öffnen") { AppModel.shared.openWiki(entry.id) }]
        }
        let item = NSMenuItem(title: "„\(name)“ ins Wiki aufnehmen", action: nil, keyEquivalent: "")
        let kinds = NSMenu()
        for kind in WikiKind.allCases {
            kinds.addItem(ActionMenuItem("als \(kind.label)") { [weak self] in
                if let entry = self?.createWiki(title: name, kind: kind) { AppModel.shared.openWiki(entry.id) }
            })
        }
        item.submenu = kinds
        return [item]
    }

    // MARK: Scene facts

    /// Fields the book defines plus any extra ones this scene has, with their values.
    func factRows(for scene: SceneFile) -> [Fact] {
        let values = Dictionary(scene.factList.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        var rows = manifest.sceneFactFields.map { Fact($0, values[$0] ?? "") }
        for fact in scene.factList where !manifest.sceneFactFields.contains(fact.key) { rows.append(fact) }
        return rows
    }

    func setFact(_ key: String, to value: String) {
        updateCurrentScene { scene in
            var facts = scene.factList
            if let index = facts.firstIndex(where: { $0.key == key }) {
                facts[index].value = value
            } else {
                facts.append(Fact(key, value))
            }
            // Keep the book's field order.
            let order = manifest.sceneFactFields
            facts.sort { (order.firstIndex(of: $0.key) ?? .max) < (order.firstIndex(of: $1.key) ?? .max) }
            scene.factList = facts
        }
    }
}

extension AppModel {
    func openWiki(_ id: String? = nil) {
        if let id { wikiSelection = id }
        openWindowAction?(id: "wiki")
    }
}
