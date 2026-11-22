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
    var showWikiTerms = true
    /// Red wavy lines under words macOS's dictionary doesn't know (host side, not sent to the editor).
    var checkSpelling = true

    init() {}

    /// Missing keys (from settings saved by an older version) fall back to the defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EditorSettings()
        font = try c.decodeIfPresent(Font.self, forKey: .font) ?? d.font
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? d.fontSize
        lineHeight = try c.decodeIfPresent(Double.self, forKey: .lineHeight) ?? d.lineHeight
        columnWidth = try c.decodeIfPresent(Double.self, forKey: .columnWidth) ?? d.columnWidth
        quotes = try c.decodeIfPresent(Quotes.self, forKey: .quotes) ?? d.quotes
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? d.language
        showComments = try c.decodeIfPresent(Bool.self, forKey: .showComments) ?? d.showComments
        focusMode = try c.decodeIfPresent(Bool.self, forKey: .focusMode) ?? d.focusMode
        showWikiTerms = try c.decodeIfPresent(Bool.self, forKey: .showWikiTerms) ?? d.showWikiTerms
        checkSpelling = try c.decodeIfPresent(Bool.self, forKey: .checkSpelling) ?? d.checkSpelling
    }

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
            "showWikiTerms": showWikiTerms,
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

    let webView: StetWebView
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []

    var onReady: (() -> Void)?
    var onChange: (() -> Void)?
    var onActivity: (() -> Void)?
    var onOpenWiki: ((String) -> Void)?
    var onEscape: (() -> Void)?
    /// Builds extra items for the right-click menu from what was clicked: the text (selection or
    /// word under the mouse), its range, and the wiki entry if it's an underlined name.
    var contextMenuProvider: ((String, NSRange, String?) -> [NSMenuItem])?
    private var lastContext: (text: String, range: NSRange, wikiID: String?, at: Date)?

    private func contextMenuItems() -> [NSMenuItem] {
        guard let context = lastContext, Date().timeIntervalSince(context.at) < 2 else { return [] }
        lastContext = nil
        return contextMenuProvider?(context.text, context.range, context.wikiID) ?? []
    }

    /// WebKit's own text checking stays off: it only looks at the paragraph being typed in, so
    /// Stet checks spelling itself (see Spelling.swift). No automatic correction (it would
    /// silently "fix" names, dialect and invented words); quotes and dashes come from Stet's own
    /// typography.
    static func registerTextCheckingDefaults() {
        UserDefaults.standard.register(defaults: [
            "WebContinuousSpellCheckingEnabled": false,
            "WebAutomaticSpellingCorrectionEnabled": false,
            "WebGrammarCheckingEnabled": false,
            "WebAutomaticQuoteSubstitutionEnabled": false,
            "WebAutomaticDashSubstitutionEnabled": false,
            "WebAutomaticTextReplacementEnabled": false,
        ])
    }

    override init() {
        Self.registerTextCheckingDefaults()
        let configuration = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        configuration.userContentController = contentController
        webView = StetWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.contextItems = { [weak self] in self?.contextMenuItems() ?? [] }

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

    func select(from: Int, to: Int) async {
        _ = try? await call("window.stet.select(a, b); return true", ["a": from, "b": to])
        webView.window?.makeFirstResponder(webView)
    }

    func replaceRange(from: Int, to: Int, with text: String) async throws {
        try await call("window.stet.replaceRange(a, b, t); return true", ["a": from, "b": to, "t": text])
    }

    /// Replaces several ranges with the same text, as one undoable edit.
    func replaceRanges(_ ranges: [NSRange], with text: String) async throws {
        let list = ranges.map { ["from": $0.location, "to": $0.location + $0.length] }
        try await call("window.stet.replaceRanges(l, t); return true", ["l": list, "t": text])
    }

    /// Highlights find matches in the scene; returns how many the editor shows.
    @discardableResult
    func setSearchMatches(_ ranges: [NSRange], current: Int?) async -> Int {
        let list = ranges.map { ["from": $0.location, "to": $0.location + $0.length] }
        return ((try? await call("return window.stet.setSearchMatches(l, c)", ["l": list, "c": current ?? -1])) as? NSNumber)?.intValue ?? 0
    }

    /// Selects a range and scrolls it into the middle, leaving the keyboard focus where it is.
    func reveal(_ range: NSRange) async {
        _ = try? await call("window.stet.reveal(a, b); return true", ["a": range.location, "b": range.location + range.length])
    }

    /// The editor's selection (or cursor).
    func selection() async -> NSRange {
        guard let value = (try? await call("return window.stet.selection()")) as? [String: Any],
              let from = (value["from"] as? NSNumber)?.intValue, let to = (value["to"] as? NSNumber)?.intValue
        else { return NSRange(location: 0, length: 0) }
        return NSRange(location: from, length: max(0, to - from))
    }

    func insertComment(_ comment: String) async throws {
        try await call("window.stet.insertComment(c); return true", ["c": comment])
    }

    func commentRange(from: Int, to: Int, comment: String) async throws {
        try await call("window.stet.commentRange(a, b, c); return true", ["a": from, "b": to, "c": comment])
    }

    func setWikiTerms(_ terms: [[String: Any]]) async {
        _ = try? await call("window.stet.setWikiTerms(t); return true", ["t": terms])
    }

    /// Red wavy lines under these words; returns how many the editor shows.
    @discardableResult
    func setMisspellings(_ list: [(range: NSRange, word: String)], hints: [(range: NSRange, word: String)] = []) async -> Int {
        let items = list.map { ["from": $0.range.location, "to": $0.range.location + $0.range.length, "word": $0.word] as [String: Any] }
            + hints.map { ["from": $0.range.location, "to": $0.range.location + $0.range.length, "word": $0.word, "kind": "hint"] as [String: Any] }
        return ((try? await call("return window.stet.setMisspellings(l)", ["l": items])) as? NSNumber)?.intValue ?? 0
    }

    func selectedText() async -> String {
        ((try? await call("return window.stet.selectedText()")) as? String) ?? ""
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
        case "openWiki":
            if let id = body["id"] as? String { onOpenWiki?(id) }
        case "escape":
            onEscape?()
        case "contextMenu":
            let from = (body["from"] as? NSNumber)?.intValue ?? 0
            let to = (body["to"] as? NSNumber)?.intValue ?? from
            lastContext = ((body["text"] as? String) ?? "", NSRange(location: from, length: max(0, to - from)), body["wikiId"] as? String, Date())
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

/// The editor's web view, with Stet's items at the top of the native right-click menu
/// (spelling suggestions, Look Up etc. stay).
final class StetWebView: WKWebView {
    var contextItems: (() -> [NSMenuItem])?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        let items = contextItems?() ?? []
        guard !items.isEmpty else { return }
        menu.insertItem(.separator(), at: 0)
        for item in items.reversed() { menu.insertItem(item, at: 0) }
    }
}

/// A menu item that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}
