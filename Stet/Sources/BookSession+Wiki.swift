import AppKit
import StetCore

/// The wiki and quick facts of the open book.
extension BookSession {
    func loadWiki() {
        wiki = book.wikiEntries()
        refreshSpellingVocabulary()
    }

    /// Sends every name (titles and aliases) to the editor for underlining and fact cards.
    func pushWikiTerms() async {
        let terms: [[String: Any]] = wiki.flatMap { entry in
            entry.names.map { name in
                [
                    "name": name, "id": entry.id, "title": entry.title, "kind": entry.kind.rawValue,
                    "facts": entry.facts.map { [$0.key, $0.value] }, "summary": entry.summary,
                    "notMeant": entry.notMeant,
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
        let names = Set(entry.names)
        guard let body = currentScene?.body, let regex = WikiMatcher.regex(for: wiki.flatMap(\.names) + entry.names),
              let match = WikiMatcher.matches(in: body, regex: regex, excluding: Set(entry.notMeant)).first(where: { names.contains($0.name) })
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

    // MARK: Taking the wiki along (e.g. into a sequel)

    /// The whole wiki as a ZIP: to pass on, or to take into another book.
    func exportWiki() {
        guard !wiki.isEmpty else {
            wikiNotice = "Das Wiki dieses Buchs ist noch leer."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "\(manifest.title) – Wiki.zip"
        panel.message = "Das ganze Wiki als ZIP-Datei: zum Weitergeben oder für eine Fortsetzung (dort „Wiki übernehmen …“)."
        panel.prompt = "Exportieren"
        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                try self.book.exportWiki(to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                self.wikiNotice = error.localizedDescription
            }
        }
    }

    func chooseWikiToImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.stetBook, .zip, .folder]
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Woher kommt das Wiki? Ein anderes Stet-Buch (z. B. der erste Band), ein exportiertes Wiki (ZIP) oder ein Ordner mit Markdown-Dateien."
        panel.prompt = "Übernehmen"
        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.importWiki(from: url)
        }
    }

    /// Adds the entries this book doesn't have yet; existing ones stay as they are.
    @discardableResult
    func importWiki(from url: URL) -> WikiImport? {
        do {
            let report = try book.importWiki(Book.wikiEntries(at: url))
            if !report.added.isEmpty { hasChangesSinceVersion = true }
            loadWiki()
            Task { await pushWikiTerms() }
            var text = report.added.isEmpty ? "Es kam kein neuer Eintrag dazu." : "\(report.added.count) \(report.added.count == 1 ? "Eintrag" : "Einträge") übernommen."
            if !report.skipped.isEmpty {
                text += "\n\nSchon vorhanden und unverändert gelassen: " + Book.list(report.skipped)
            }
            wikiNotice = text
            return report
        } catch {
            wikiNotice = error.localizedDescription
            return nil
        }
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

    /// What a scene gets from its chapter or part for this field (shown when its own is empty).
    func inheritedFact(_ key: String, forScene sceneID: String) -> String? {
        manifest.effectiveFacts(ofScene: sceneID, own: []).first { $0.key == key }?.displayValue
    }

    func setChapterFact(_ chapterID: String, _ key: String, to value: String) {
        updateBook { manifest in
            manifest.updateChapter(chapterID) { chapter in chapter.facts = Self.setting(key, to: value, in: chapter.facts) }
        }
    }

    func setPartFact(_ partID: String, _ key: String, to value: String) {
        updateBook { manifest in
            manifest.updatePart(partID) { part in part.facts = Self.setting(key, to: value, in: part.facts) }
        }
    }

    private static func setting(_ key: String, to value: String, in facts: [Fact]) -> [Fact] {
        var result = facts
        if let index = result.firstIndex(where: { $0.key == key }) { result[index].value = value } else { result.append(Fact(key, value)) }
        return result.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
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
