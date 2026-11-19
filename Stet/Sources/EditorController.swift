import AppKit
import WebKit

/// Display settings for the writing pane (mirrors `EditorSettings` in editor/src/settings.ts).
struct EditorSettings: Equatable, Codable {
    enum Font: String, CaseIterable, Identifiable, Codable {
        case serif, sans, mono
        var id: String { rawValue }
        var label: String {
            switch self {
            case .serif: "Serif"
            case .sans: "Sans"
            case .mono: "Mono"
            }
        }
    }

    enum Quotes: String, CaseIterable, Identifiable, Codable {
        case de, guillemets, en
        var id: String { rawValue }
        var label: String {
            switch self {
            case .de: "„Deutsch“"
            case .guillemets: "»Buch«"
            case .en: "“English”"
            }
        }
    }

    var font: Font = .serif
    var fontSize: Double = 19
    var lineHeight: Double = 1.65
    var columnWidth: Double = 36
    var quotes: Quotes = .de
    var language = "de"
    var showComments = true
    var focusMode = false

    private static let defaultsKey = "EditorSettings"

    /// Display settings are per device, not per book.
    static func load() -> EditorSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(EditorSettings.self, from: data)
        else { return EditorSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    static func quotes(forLanguage language: String) -> Quotes {
        language.lowercased().hasPrefix("en") ? .en : .de
    }

    var dictionary: [String: Any] {
        [
            "font": font.rawValue,
            "fontSize": fontSize,
            "lineHeight": lineHeight,
            "columnWidth": columnWidth,
            "quotes": quotes.rawValue,
            "language": language,
            "showComments": showComments,
            "focusMode": focusMode,
        ]
    }
}

/// Owns the WKWebView that hosts the CodeMirror editor and speaks the bridge protocol:
/// Swift → JS through `window.stet.*` (callAsyncJavaScript), JS → Swift through the
/// `stet` message handler (`ready`, `changed`, `stats`, `activity`).
@MainActor
final class EditorController: NSObject, ObservableObject {
    @Published private(set) var isReady = false
    @Published private(set) var words = 0
    @Published private(set) var characters = 0
    @Published var settings = EditorSettings.load() {
        didSet { settings.save() }
    }

    let webView: WKWebView
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []

    var onReady: (() -> Void)?
    var onChange: (() -> Void)?
    var onActivity: (() -> Void)?

    override init() {
        let configuration = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        configuration.userContentController = contentController
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        contentController.add(WeakMessageHandler(self), name: "stet")
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
        if #available(macOS 13.3, *) {
            webView.isInspectable = true  // Safari ▸ Develop ▸ Stet
        }

        let index = EditorResources.indexURL
        webView.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
    }

    func waitUntilReady() async {
        if isReady { return }
        await withCheckedContinuation { readyWaiters.append($0) }
    }

    // MARK: Swift → JS

    @discardableResult
    func call(_ body: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page)
    }

    func load(_ text: String) async throws {
        try await call("return window.stet.load(text)", ["text": text])
    }

    func text() async throws -> String {
        guard let text = try await call("return window.stet.getText()") as? String else {
            throw BridgeError.unexpectedResult("getText")
        }
        return text
    }

    /// Replaces the whole text as one undoable edit.
    func replaceText(_ text: String) async throws {
        try await call("window.stet.replaceText(text); return true", ["text": text])
    }

    func applySettings() async {
        _ = try? await call("return window.stet.setSettings(s)", ["s": settings.dictionary])
    }

    func stressTest(words: Int) async throws -> [String: Any] {
        guard let result = try await call("return window.stet.loadStressTest(n)", ["n": words]) as? [String: Any] else {
            throw BridgeError.unexpectedResult("loadStressTest")
        }
        return result
    }

    func focus() {
        webView.window?.makeFirstResponder(webView)
        Task { _ = try? await call("window.stet.focus(); return true") }
    }

    enum BridgeError: Error {
        case unexpectedResult(String)
    }
}

// MARK: JS → Swift

extension EditorController: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
            readyWaiters.forEach { $0.resume() }
            readyWaiters.removeAll()
            onReady?()
        case "changed":
            onChange?()
        case "stats":
            words = (body["words"] as? NSNumber)?.intValue ?? 0
            characters = (body["characters"] as? NSNumber)?.intValue ?? 0
        case "activity":
            onActivity?()
        default:
            break
        }
    }
}

/// WKUserContentController retains its handlers; this breaks the cycle with the controller.
@MainActor
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
