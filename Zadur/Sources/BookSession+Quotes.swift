import Foundation
import ZadurCore

/// What "Anführungszeichen angleichen" would change, asked before it does.
struct QuoteConversion: Equatable {
    var style: QuoteStyle
    var marks: Int
    var scenes: Int
    /// Asked right after the style was changed (then "no" keeps the text as it is).
    var afterChange: Bool
}

extension BookSession {
    /// The book's quotation marks: typed quotes become these, exports set them. Asks whether the
    /// marks already in the text should change too.
    func setQuoteStyle(_ style: QuoteStyle) {
        guard style != manifest.quoteStyle else { return }
        updateBook { $0.quotes = style }
        Task { await offerQuoteConversion(afterChange: true) }
    }

    /// Counts the marks that aren't in the book's style yet (straight ones from imported or
    /// pasted text, or another style) and asks before changing them.
    func offerQuoteConversion(afterChange: Bool = false) async {
        await persist()
        let style = manifest.quoteStyle
        var marks = 0
        var scenes = 0
        for id in manifest.sceneIDs + unplacedSceneIDs {
            guard let text = await sceneText(id) else { continue }
            let changes = Typography.changes(from: text, to: Typography.quotes(text, style: style))
            if changes > 0 {
                marks += changes
                scenes += 1
            }
        }
        if marks > 0 {
            quoteConversion = QuoteConversion(style: style, marks: marks, scenes: scenes, afterChange: afterChange)
        } else if !afterChange {
            showToast(Toast(message: "Alle Anführungszeichen im Buch sind schon \(style.sample)"))
        }
    }

    /// Turns every quotation mark in the book into the book's style. The state before is saved
    /// as a snapshot (each scene's history can bring it back); in the scene being shown, ⌘Z
    /// undoes it too.
    func convertQuotes() async {
        quoteConversion = nil
        let style = manifest.quoteStyle
        await persistAndSnapshot()
        var marks = 0
        var scenes = 0
        for id in manifest.sceneIDs + unplacedSceneIDs {
            if id == selectedSceneID {
                guard let text = try? await editor.text() else { continue }
                let converted = Typography.quotes(text, style: style)
                let changes = Typography.changes(from: text, to: converted)
                guard changes > 0 else { continue }
                let selection = await editor.selection()
                try? await editor.replaceText(converted)
                await editor.select(from: selection.location, to: NSMaxRange(selection))
                marks += changes
                scenes += 1
            } else if var scene = try? book.readScene(id) {
                let converted = Typography.quotes(scene.body, style: style)
                let changes = Typography.changes(from: scene.body, to: converted)
                guard changes > 0 else { continue }
                scene.body = converted
                do {
                    _ = try book.writeScene(scene)
                    marks += changes
                    scenes += 1
                } catch {
                    errorMessage = "Eine Szene konnte nicht geändert werden: \(error.localizedDescription)"
                }
            }
        }
        await persist()
        sceneFilesChanged()
        let place = scenes == 1 ? "einer Szene" : "\(scenes) Szenen"
        showToast(Toast(message: "\(marks.formatted()) Anführungszeichen in \(place) angeglichen. Der Stand davor ist als Schnappschuss im Verlauf."))
    }

    /// A scene's text: from the editor for the one being shown, else from its file.
    private func sceneText(_ id: String) async -> String? {
        if id == selectedSceneID, let text = try? await editor.text() { return text }
        return try? book.readScene(id).body
    }
}
