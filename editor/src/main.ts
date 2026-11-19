import "./editor.css";
import { defaultKeymap, history, historyKeymap } from "@codemirror/commands";
import { markdown } from "@codemirror/lang-markdown";
import { syntaxHighlighting } from "@codemirror/language";
import { EditorState, type Extension, Transaction } from "@codemirror/state";
import { EditorView, highlightActiveLine, keymap, type ViewUpdate } from "@codemirror/view";
import type { HostMessage, StetEditorAPI, StressTestResult } from "./api";
import { stetKeymap } from "./commands";
import { commentRail, criticDecorations, criticField } from "./critic";
import { startDevHarness } from "./dev";
import { livePreview } from "./livePreview";
import { defaultSettings, type EditorSettings, fontStacks, setSettings, settingsField } from "./settings";
import { type TextStats, textStats } from "./stats";
import { proseHighlight, stetTheme } from "./theme";
import { typography } from "./typography";

// ---------------------------------------------------------------------------
// Host bridge

interface MessageHandler {
  postMessage(message: unknown): void;
}

const host: MessageHandler | undefined = (
  window as unknown as { webkit?: { messageHandlers?: { stet?: MessageHandler } } }
).webkit?.messageHandlers?.stet;

function post(message: HostMessage) {
  if (host) host.postMessage(message);
}

// ---------------------------------------------------------------------------
// Settings → CSS

let settings: EditorSettings = { ...defaultSettings };

function applyCssVariables(s: EditorSettings) {
  const root = document.documentElement;
  root.style.setProperty("--stet-font", fontStacks[s.font]);
  root.style.setProperty("--stet-size", `${s.fontSize}px`);
  root.style.setProperty("--stet-line-height", String(s.lineHeight));
  root.style.setProperty("--stet-column", `${s.columnWidth}em`);
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

function onUpdate(update: ViewUpdate) {
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
    history(),
    keymap.of([...stetKeymap, ...defaultKeymap, ...historyKeymap]),
    markdown(),
    syntaxHighlighting(proseHighlight),
    stetTheme,
    EditorView.lineWrapping,
    highlightActiveLine(),
    EditorView.contentAttributes.of((view) => ({
      spellcheck: "true",
      autocorrect: "on",
      autocapitalize: "sentences",
      lang: view.state.field(settingsField).language,
      "aria-label": "Manuskript",
    })),
    EditorView.editorAttributes.of((view) => {
      const s = view.state.field(settingsField);
      const classes = [s.focusMode && "stet-focus", s.showComments && "stet-comments-on"].filter(Boolean);
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

const api: StetEditorAPI = {
  load(text) {
    view.setState(EditorState.create({ doc: text, extensions: extensions() }));
    view.scrollDOM.scrollTop = 0;
    scheduleStats(0);
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

(window as unknown as { stet: StetEditorAPI }).stet = api;
applyCssVariables(settings);

if (host) {
  post({ type: "ready" });
} else {
  // Browser only: expose the view for debugging from the console.
  (window as unknown as { stetView: EditorView }).stetView = view;
  startDevHarness(api);
}
