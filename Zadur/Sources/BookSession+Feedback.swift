import AppKit
import ZadurCore

/// Comments/TODOs across the book, and the feedback inbox.
extension BookSession {
    // MARK: - Notes

    func loadNotes() async {
        await persist()
        notes = book.notes()
    }

    func jump(to note: NoteItem) async {
        await select(note.sceneID)
        await editor.select(from: note.from, to: note.to)
    }

    /// Removes a comment or TODO from the text ("erledigt"); a highlighted passage stays.
    func resolve(_ note: NoteItem) async {
        await persist()
        do {
            if note.sceneID == selectedSceneID {
                guard let body = currentScene?.body, CriticMarkup.removing(note, from: body) != nil else {
                    await loadNotes()
                    return
                }
                try await editor.replaceRange(from: note.from, to: note.to, with: note.highlighted ?? "")
            } else {
                try book.removeNote(note)
                hasChangesSinceVersion = true
                reloadSceneInfo()
            }
            try? await Task.sleep(for: .milliseconds(100))
            await loadNotes()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Feedback

    func loadFeedback() {
        feedback = book.feedbackEntries()
    }

    var feedbackNames: [String] {
        Array(Set(feedback.map(\.from).filter { !$0.isEmpty })).sorted()
    }

    /// The newest export mark: what feedback most likely refers to.
    var latestExportTag: String? {
        milestones.filter(\.isExport).max { $0.date < $1.date }?.tag
    }

    @discardableResult
    func addFeedback(from: String, received: Date, refersTo: String?, text: String, attachments: [URL],
                     wordComments: [WordComment] = []) -> FeedbackEntry? {
        do {
            let entry = try book.addFeedback(from: from, received: received, refersTo: refersTo, text: text,
                                             attachments: attachments, wordComments: wordComments)
            hasChangesSinceVersion = true
            loadFeedback()
            return entry
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func save(_ entry: FeedbackEntry) {
        do {
            try book.saveFeedback(entry)
            hasChangesSinceVersion = true
            loadFeedback()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ entry: FeedbackEntry) {
        do {
            try book.deleteFeedback(entry)
            hasChangesSinceVersion = true
            loadFeedback()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func attachmentURL(_ path: String) -> URL { book.url.appendingPathComponent(path) }

    /// Inserts text from a feedback entry as a comment at the editor's cursor (or around its selection).
    func insertFeedbackComment(_ text: String, from author: String) async {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, selectedSceneID != nil else { return }
        let comment = String(CriticMarkup.comment(clean, author: author.isEmpty ? nil : author).dropFirst(3).dropLast(3))
        do {
            try await editor.insertComment(comment)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Puts a Word comment where its passage is today. Returns false if the passage wasn't found.
    @discardableResult
    func place(_ comment: WordComment, of entry: FeedbackEntry) async -> Bool {
        await persist()
        guard !comment.anchor.isEmpty, let location = book.locate(comment.anchor) else { return false }
        if location.sceneID != selectedSceneID { await select(location.sceneID) }
        let content = String(CriticMarkup.comment(comment.text, author: comment.author).dropFirst(3).dropLast(3))
        do {
            try await editor.commentRange(from: location.range.lowerBound, to: location.range.upperBound, comment: content)
            await persist()
            markPlaced(comment, in: entry)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Puts a Word comment at the cursor (when its passage can't be found anymore).
    func placeAtCursor(_ comment: WordComment, of entry: FeedbackEntry) async {
        let text = comment.anchor.isEmpty ? comment.text : "„\(comment.anchor)“: \(comment.text)"
        await insertFeedbackComment(text, from: comment.author)
        await persist()
        markPlaced(comment, in: entry)
    }

    private func markPlaced(_ comment: WordComment, in entry: FeedbackEntry) {
        guard var current = book.feedbackEntries().first(where: { $0.id == entry.id }),
              let index = current.wordComments.firstIndex(where: { $0.id == comment.id })
        else { return }
        current.wordComments[index].placed = true
        save(current)
    }

    /// Reads a returned Word document's comments into a new feedback entry (the file is attached).
    func importWord(_ url: URL, from: String, refersTo: String?, note: String) async -> FeedbackEntry? {
        isBusy = true
        defer { isBusy = false }
        do {
            let comments = try await Book.wordComments(in: url)
            return addFeedback(from: from, received: Date(), refersTo: refersTo, text: note, attachments: [url], wordComments: comments)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Shows how the open scene changed since the version a piece of feedback is about.
    func compareWithFeedbackVersion(_ entry: FeedbackEntry) async {
        guard let tag = entry.refersTo, let id = selectedSceneID else { return }
        var commit = milestones.first(where: { $0.tag == tag })?.commit
        if commit == nil { commit = await book.git.resolve(tag) }
        guard let commit else { return }
        guard let version = await book.version(ofScene: id, at: commit) else {
            errorMessage = "Diese Szene gab es in der Fassung, auf die sich die Rückmeldung bezieht, noch nicht."
            return
        }
        await compare(with: version)
    }

    func milestoneLabel(_ tag: String?) -> String {
        guard let tag else { return "–" }
        guard let milestone = milestones.first(where: { $0.tag == tag }) else { return tag }
        return "\(milestone.name) (\(milestone.date.formatted(date: .abbreviated, time: .omitted)))"
    }
}
