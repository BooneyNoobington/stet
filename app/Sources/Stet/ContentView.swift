import SwiftUI
import WebKit

struct ContentView: View {
    @ObservedObject var session: SceneSession
    @ObservedObject var editor: EditorController

    var body: some View {
        EditorWebView(webView: editor.webView)
            .frame(minWidth: 640, minHeight: 420)
            .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
            .toolbar { toolbar }
            .navigationTitle(session.title)
            .navigationSubtitle(session.isDirty ? "Bearbeitet" : "")
            .onChange(of: editor.settings) {
                Task { await editor.applySettings() }
            }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Picker("Schrift", selection: $editor.settings.font) {
                ForEach(EditorSettings.Font.allCases) { Text($0.label).tag($0) }
            }
            .help("Schrift")

            ControlGroup {
                Button { editor.settings.fontSize = max(12, editor.settings.fontSize - 1) } label: {
                    Image(systemName: "textformat.size.smaller")
                }
                .help("Kleiner")
                Button { editor.settings.fontSize = min(32, editor.settings.fontSize + 1) } label: {
                    Image(systemName: "textformat.size.larger")
                }
                .help("Größer")
            }

            Picker("Anführungszeichen", selection: $editor.settings.quotes) {
                ForEach(EditorSettings.Quotes.allCases) { Text($0.label).tag($0) }
            }
            .help("Anführungszeichen")

            Toggle(isOn: $editor.settings.showComments) {
                Label("Kommentare", systemImage: "text.bubble")
            }
            .help("Kommentare ein-/ausblenden")

            Toggle(isOn: $editor.settings.focusMode) {
                Label("Fokus", systemImage: "scope")
            }
            .help("Fokusmodus: nur der aktuelle Absatz ist hervorgehoben")
        }
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            Text("\(editor.words.formatted()) Wörter")
            Text("\(editor.characters.formatted()) Zeichen")
            Spacer()
            Text(session.saveStatus)
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(.bar)
    }
}

struct EditorWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
