import AppKit
import SwiftUI
import WebKit

/// The few formats a novel needs: italic, bold, a quote (a letter, an epigraph …), and the
/// writer's own comments and TODOs. The toolbar, the Format menu and the right-click menu offer
/// the same commands; the editor does the Markdown (see editor/src/commands.ts).
enum TextFormat: String, CaseIterable, Identifiable {
    case italic, bold, quote, comment, todo

    var id: String { rawValue }

    var label: String {
        switch self {
        case .italic: "Kursiv"
        case .bold: "Fett"
        case .quote: "Zitat"
        case .comment: "Kommentar"
        case .todo: "TODO"
        }
    }

    var symbol: String {
        switch self {
        case .italic: "italic"
        case .bold: "bold"
        case .quote: "text.quote"
        case .comment: "plus.bubble"
        case .todo: "checklist"
        }
    }

    /// The menu's shortcut (the editor knows the same keys).
    var shortcut: KeyboardShortcut? {
        switch self {
        case .italic: KeyboardShortcut("i", modifiers: .command)
        case .bold: KeyboardShortcut("b", modifiers: .command)
        case .comment: KeyboardShortcut("m", modifiers: [.command, .option])
        case .quote, .todo: nil
        }
    }

    var help: String {
        switch self {
        case .italic: "Kursiv (⌘I) – auch wieder aufheben"
        case .bold: "Fett (⌘B) – auch wieder aufheben"
        case .quote: "Zitat: die Absätze eingerückt, etwa für einen Brief oder ein Motto – auch wieder aufheben"
        case .comment: "Kommentar an der markierten Stelle (⌥⌘M)"
        case .todo: "TODO an der markierten Stelle (⌥⌘T)"
        }
    }

    /// Italic, bold and quote are on or off; comments are added.
    var isToggle: Bool { self == .italic || self == .bold || self == .quote }
}

/// Which formats the selection is in, as the editor reports it.
struct FormatState: Equatable {
    var italic = false
    var bold = false
    var quote = false

    func isOn(_ format: TextFormat) -> Bool {
        switch format {
        case .italic: italic
        case .bold: bold
        case .quote: quote
        case .comment, .todo: false
        }
    }
}

extension EditorController {
    /// Applies a format to the selection, or to `range` (the right-click menu's word) and gives
    /// the text the keyboard focus.
    func format(_ format: TextFormat, range: NSRange? = nil) async {
        webView.window?.makeFirstResponder(webView)
        if let range {
            _ = try? await call("return window.zadur.format(kind, from, to)",
                                ["kind": format.rawValue, "from": range.location, "to": NSMaxRange(range)])
        } else {
            _ = try? await call("return window.zadur.format(kind)", ["kind": format.rawValue])
        }
    }

    /// A shortcut typed in another field (the inspector, the wiki, a dialog) isn't meant for the
    /// text; a click on a menu item or button is.
    var takesFormatShortcuts: Bool {
        guard NSApp.currentEvent?.type == .keyDown else { return true }
        return (NSApp.keyWindow?.firstResponder as? NSView)?.isDescendant(of: webView) == true
    }
}

/// Kursiv, Fett, Zitat and Kommentar in the toolbar; the first three light up when the cursor
/// is in such text.
struct FormatButtons: View {
    @ObservedObject var editor: EditorController

    var body: some View {
        ControlGroup {
            ForEach([TextFormat.italic, .bold, .quote]) { format in
                Toggle(isOn: Binding(get: { editor.formatState.isOn(format) }, set: { _ in apply(format) })) {
                    Label(format.label, systemImage: format.symbol)
                }
                .help(format.help)
            }
            Button { apply(.comment) } label: {
                Label(TextFormat.comment.label, systemImage: TextFormat.comment.symbol)
            }
            .help(TextFormat.comment.help)
        } label: {
            Label("Format", systemImage: "textformat")
        }
    }

    private func apply(_ format: TextFormat) {
        Task { await editor.format(format) }
    }
}

/// The Format menu in the menu bar.
struct FormatMenu: View {
    @ObservedObject var model: AppModel
    @ObservedObject var editor: EditorController

    var body: some View {
        ForEach(TextFormat.allCases) { format in
            if format == .comment { Divider() }
            item(format)
                .disabled(model.session == nil)
        }
    }

    @ViewBuilder
    private func item(_ format: TextFormat) -> some View {
        let title = format.isToggle ? format.label : "\(format.label) einfügen"
        if format.isToggle {
            Toggle(title, isOn: Binding(get: { editor.formatState.isOn(format) }, set: { _ in apply(format) }))
                .keyboardShortcut(format.shortcut)
        } else {
            Button(title) { apply(format) }
                .keyboardShortcut(format.shortcut)
        }
    }

    private func apply(_ format: TextFormat) {
        guard editor.takesFormatShortcuts else { return }
        Task { await editor.format(format) }
    }
}

extension BookSession {
    /// Right-click: the formats, for the selection or the word under the mouse.
    func formatMenuItems(range: NSRange) -> [NSMenuItem] {
        TextFormat.allCases.filter { range.length > 0 || !($0 == .italic || $0 == .bold) }.map { format in
            let title = format.isToggle ? format.label : "\(format.label) einfügen"
            let item = ActionMenuItem(title) { [weak self] in
                Task { await self?.editor.format(format, range: range) }
            }
            item.image = NSImage(systemSymbolName: format.symbol, accessibilityDescription: nil)
            return item
        }
    }
}
