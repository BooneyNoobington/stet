import "./editor.css";
import { defaultKeymap, history, historyKeymap } from "@codemirror/commands";
import { markdown } from "@codemirror/lang-markdown";
import { syntaxHighlighting } from "@codemirror/language";
import { EditorState, type Extension, Transaction } from "@codemirror/state";
import { EditorView, highlightActiveLine, keymap, type ViewUpdate } from "@codemirror/view";
import type { HostMessage, ZadurEditorAPI, StressTestResult } from "./api";
import { type FormatState, formatState, runFormat, zadurKeymap } from "./commands";
import { commentRail, criticDecorations, criticField } from "./critic";
import { startDevHarness } from "./dev";
import { livePreview } from "./livePreview";
import { defaultSettings, type EditorSettings, fontStacks, setSettings, settingsField } from "./settings";
import { type TextStats, textStats } from "./stats";
import { proseHighlight, zadurTheme } from "./theme";
import { typography } from "./typography";
import { setWikiTerms, type WikiTerm, wikiExtensions, wikiField, wikiState } from "./wiki";
import { misspellingField, setMisspellings } from "./spelling";
import { searchField, setSearchMatches } from "./search";

// ---------------------------------------------------------------------------
// Host bridge

interface MessageHandler {
  postMessage(message: unknown): void;
}

const host: MessageHandler | undefined = (
  window as unknown as { webkit?: { messageHandlers?: { zadur?: MessageHandler } } }
).webkit?.messageHandlers?.zadur;

function post(message: HostMessage) {
  if (host) host.postMessage(message);
}

// ---------------------------------------------------------------------------
// Settings → CSS

let settings: EditorSettings = { ...defaultSettings };
// Kept across load(), which creates a new editor state.
let wikiTerms: WikiTerm[] = [];

function applyCssVariables(s: EditorSettings) {
  const root = document.documentElement;
  root.style.setProperty("--zadur-font", fontStacks[s.font]);
  root.style.setProperty("--zadur-size", `${s.fontSize}px`);
  root.style.setProperty("--zadur-line-height", String(s.lineHeight));
  root.style.setProperty("--zadur-column", `${s.columnWidth}em`);
  root.lang = s.language;
}

// ---------------------------------------------------------------------------
// Focus mode: typewriter scrolling while typing or moving with the keyboard

const typewriterScrolling = EditorState.transactionExtender.of((tr) => {
  if (!tr.startState.field(settingsField).focusMode) return null;
  const keyboard =
    tr.isUserEvent("input") ||
    tr.isUserEvent("delete") ||
    (tr.isUserEvent("select") && !tr.isUserEvent("select.pointer"));
  if (!keyboard) return null;
  return { effects: EditorView.scrollIntoView(tr.newSelection.main.head, { y: "center" }) };
});

// ---------------------------------------------------------------------------
// Change tracking and stats

let quiet = false;
let lastActivity = 0;
let lastStats: TextStats = { words: 0, characters: 0 };
let statsTimer: number | undefined;

let lastFormat = "";

/** Tells the host which formats the selection is in, when that changes. */
function postFormat(state: EditorState) {
  const format: FormatState = formatState(state);
  const key = JSON.stringify(format);
  if (key === lastFormat) return;
  lastFormat = key;
  post({ type: "format", ...format });
}

function onUpdate(update: ViewUpdate) {
  if ((update.docChanged || update.selectionSet) && !quiet) postFormat(update.state);
  if (!update.docChanged || quiet) return;
  post({ type: "changed" });
  const now = Date.now();
  if (now - lastActivity > 15_000) {
    lastActivity = now;
    post({ type: "activity" });
  }
  scheduleStats();
}

function scheduleStats(delay = 300) {
  window.clearTimeout(statsTimer);
  statsTimer = window.setTimeout(() => {
    lastStats = textStats(view.state.doc.toString(), settings.language);
    post({ type: "stats", ...lastStats });
  }, delay);
}

// ---------------------------------------------------------------------------
// Editor

function extensions(): Extension[] {
  return [
    settingsField.init(() => settings),
    wikiField.init(() => wikiState(wikiTerms)),
    wikiExtensions((id) => post({ type: "openWiki", id })),
    EditorView.domEventHandlers({
      // Tell the host what was right-clicked, so the native menu can offer wiki items.
      contextmenu(event, view) {
        const wikiId = (event.target as HTMLElement).closest<HTMLElement>(".zadur-wiki-term")?.dataset.wiki ?? null;
        // The selection if the click is on it, else the word under the mouse (as on a Mac:
        // a right-click elsewhere is about what's there, not about the selection).
        const selection = view.state.selection.main;
        const pos = view.posAtCoords({ x: event.clientX, y: event.clientY });
        let from = selection.from;
        let to = selection.to;
        const onSelection = pos !== null && pos >= selection.from && pos <= selection.to;
        if (!view.state.sliceDoc(from, to).trim() || (pos !== null && !onSelection)) {
          const word = pos === null ? null : view.state.wordAt(pos);
          from = word?.from ?? pos ?? from;
          to = word?.to ?? from;
        }
        const text = view.state.sliceDoc(from, to);
        post({ type: "contextMenu", text: text.slice(0, 120), wikiId, from, to: Math.min(to, from + 120) });
        return false; // keep the native menu (look up, cut/copy/paste …)
      },
    }),
    history(),
    keymap.of([
      // Not handled here: the app still gets Esc (e.g. to close a comparison).
      { key: "Escape", run: () => (post({ type: "escape" }), false) },
      ...zadurKeymap,
      ...defaultKeymap,
      ...historyKeymap,
    ]),
    markdown(),
    syntaxHighlighting(proseHighlight),
    zadurTheme,
    EditorView.lineWrapping,
    highlightActiveLine(),
    misspellingField,
    searchField,
    // Spelling is checked by the host (whole scene, the book's words, the wiki's names), not by
    // WebKit, which only looks at the paragraph being typed in. No automatic correction: it
    // would silently "fix" names, dialect and invented words.
    EditorView.contentAttributes.of((view) => ({
      spellcheck: "false",
      autocorrect: "off",
      autocapitalize: "sentences",
      lang: view.state.field(settingsField).language,
      "aria-label": "Manuskript",
    })),
    EditorView.editorAttributes.of((view) => {
      const s = view.state.field(settingsField);
      const classes = [s.focusMode && "zadur-focus", s.showComments && "zadur-comments-on"].filter(Boolean);
      return classes.length ? { class: classes.join(" ") } : null;
    }),
    criticField,
    livePreview,
    criticDecorations,
    commentRail,
    typography,
    typewriterScrolling,
    EditorView.updateListener.of(onUpdate),
  ];
}

const view = new EditorView({
  parent: document.getElementById("editor")!,
  state: EditorState.create({ doc: "", extensions: extensions() }),
});

function measureTyping(samples = 100): number {
  const pos = view.state.doc.line(Math.ceil(view.state.doc.lines / 2)).from;
  quiet = true;
  const start = performance.now();
  for (let i = 0; i < samples; i++) {
    view.dispatch({ changes: { from: pos, insert: "x" }, annotations: Transaction.addToHistory.of(false) });
    view.dispatch({ changes: { from: pos, to: pos + 1 }, annotations: Transaction.addToHistory.of(false) });
  }
  const perKeystroke = (performance.now() - start) / (samples * 2);
  quiet = false;
  return Math.round(perKeystroke * 100) / 100;
}

const api: ZadurEditorAPI = {
  load(text) {
    view.setState(EditorState.create({ doc: text, extensions: extensions() }));
    view.scrollDOM.scrollTop = 0;
    scheduleStats(0);
    postFormat(view.state);
    return { length: text.length };
  },
  getText: () => view.state.doc.toString(),
  replaceText(text) {
    view.dispatch({
      changes: { from: 0, to: view.state.doc.length, insert: text },
      selection: { anchor: 0 },
      scrollIntoView: true,
      userEvent: "input.restore",
    });
  },
  select(from, to) {
    const length = view.state.doc.length;
    const anchor = Math.max(0, Math.min(from, length));
    const head = Math.max(0, Math.min(to, length));
    view.dispatch({
      selection: { anchor, head },
      effects: EditorView.scrollIntoView(anchor, { y: "center" }),
      userEvent: "select",
    });
    view.focus();
  },
  replaceRange(from, to, text) {
    view.dispatch({ changes: { from, to, insert: text }, userEvent: "input.replace" });
  },
  replaceRanges(ranges, text) {
    const length = view.state.doc.length;
    const changes = ranges
      .filter((r) => r.from >= 0 && r.to <= length && r.from <= r.to)
      .sort((a, b) => a.from - b.from)
      .filter((r, i, all) => i === 0 || r.from >= all[i - 1].to)
      .map((r) => ({ from: r.from, to: r.to, insert: text }));
    if (changes.length) view.dispatch({ changes, userEvent: "input.replace.all" });
  },
  setSearchMatches(matches, current) {
    view.dispatch({ effects: setSearchMatches.of({ matches, current }) });
    return view.state.field(searchField).size;
  },
  reveal(from, to) {
    const length = view.state.doc.length;
    const anchor = Math.max(0, Math.min(from, length));
    const head = Math.max(0, Math.min(to, length));
    view.dispatch({
      selection: { anchor, head },
      effects: EditorView.scrollIntoView(anchor, { y: "center" }),
      userEvent: "select.search",
    });
  },
  selection() {
    const range = view.state.selection.main;
    return { from: range.from, to: range.to };
  },
  format(kind, from, to) {
    if (from !== undefined && to !== undefined) {
      const length = view.state.doc.length;
      view.dispatch({ selection: { anchor: Math.max(0, Math.min(from, length)), head: Math.max(0, Math.min(to, length)) }, userEvent: "select" });
    }
    return runFormat(view, kind);
  },
  formatState: () => formatState(view.state),
  insertComment(comment) {
    const range = view.state.selection.main;
    const body = `{>>${comment}<<}`;
    if (range.empty) {
      view.dispatch({ changes: { from: range.head, insert: body }, selection: { anchor: range.head + body.length }, userEvent: "input" });
    } else {
      const passage = view.state.sliceDoc(range.from, range.to);
      const text = `{==${passage}==}${body}`;
      view.dispatch({ changes: { from: range.from, to: range.to, insert: text }, selection: { anchor: range.from + text.length }, userEvent: "input" });
    }
    view.focus();
  },
  commentRange(from, to, comment) {
    const passage = view.state.sliceDoc(from, to);
    const text = `{==${passage}==}{>>${comment}<<}`;
    view.dispatch({
      changes: { from, to, insert: text },
      selection: { anchor: from },
      effects: EditorView.scrollIntoView(from, { y: "center" }),
      userEvent: "input",
    });
  },
  setWikiTerms(terms) {
    wikiTerms = terms;
    view.dispatch({ effects: setWikiTerms.of(terms) });
  },
  setMisspellings(list) {
    view.dispatch({ effects: setMisspellings.of(list) });
    return view.dom.querySelectorAll(".zadur-misspelled, .zadur-hint").length;
  },
  selectedText() {
    const range = view.state.selection.main;
    return view.state.sliceDoc(range.from, range.to);
  },
  setSettings(patch) {
    settings = { ...settings, ...patch };
    applyCssVariables(settings);
    view.dispatch({ effects: setSettings.of(patch) });
    if (patch.language) scheduleStats(0);
    return settings;
  },
  getSettings: () => settings,
  stats: () => lastStats,
  focus: () => view.focus(),
  loadStressTest(targetWords = 15_000): StressTestResult | null {
    const paragraphs = view.state.doc
      .toString()
      .split(/\n{2,}/)
      .filter((p) => p.trim());
    if (!paragraphs.length) return null;
    const out: string[] = [];
    let words = 0;
    for (let i = 0; words < targetWords; i++) {
      const paragraph = paragraphs[i % paragraphs.length];
      out.push(paragraph);
      words += textStats(paragraph, settings.language).words;
    }
    const text = out.join("\n\n");

    let start = performance.now();
    api.load(text);
    const loadMs = performance.now() - start;

    start = performance.now();
    const stats = textStats(text, settings.language);
    const statsMs = performance.now() - start;

    return {
      words: stats.words,
      characters: text.length,
      paragraphs: out.length,
      comments: view.state.field(criticField).filter((c) => c.comment).length,
      loadMs: Math.round(loadMs),
      statsMs: Math.round(statsMs),
      msPerKeystroke: measureTyping(),
    };
  },
};

(window as unknown as { zadur: ZadurEditorAPI }).zadur = api;
applyCssVariables(settings);

if (host) {
  post({ type: "ready" });
} else {
  // Browser only: expose the view for debugging from the console.
  (window as unknown as { zadurView: EditorView }).zadurView = view;
  startDevHarness(api);
}
