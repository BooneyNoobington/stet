import { ensureSyntaxTree, syntaxTree } from "@codemirror/language";
import { EditorSelection, type EditorState } from "@codemirror/state";
import type { Command, EditorView, KeyBinding } from "@codemirror/view";
import type { SyntaxNode } from "@lezer/common";

/** What the format buttons, the Format menu and the right-click menu do. */
export type FormatKind = "italic" | "bold" | "quote" | "comment" | "todo";

/** Which formats the selection is in, for the buttons' on/off look. */
export interface FormatState {
  italic: boolean;
  bold: boolean;
  quote: boolean;
}

const EMPHASIS = {
  italic: { node: "Emphasis", marker: "*" },
  bold: { node: "StrongEmphasis", marker: "**" },
} as const;

function tree(state: EditorState, upTo: number) {
  return ensureSyntaxTree(state, upTo, 200) ?? syntaxTree(state);
}

function marks(node: SyntaxNode): SyntaxNode[] {
  const list: SyntaxNode[] = [];
  for (let child = node.firstChild; child; child = child.nextSibling) {
    if (child.name === "EmphasisMark") list.push(child);
  }
  return list;
}

/** The text of an emphasis, between its marks. */
function inner(node: SyntaxNode): { from: number; to: number } {
  const list = marks(node);
  return {
    from: list.length && list[0].from === node.from ? list[0].to : node.from,
    to: list.length && list[list.length - 1].to === node.to ? list[list.length - 1].from : node.to,
  };
}

/** The emphasis of this kind the selection lies in (inside its marks, or exactly all of it). */
function enclosing(state: EditorState, name: string, from: number, to: number): SyntaxNode | null {
  const t = tree(state, to);
  for (const side of [1, -1] as const) {
    for (let node: SyntaxNode | null = t.resolveInner(from, side); node; node = node.parent) {
      if (node.name !== name) continue;
      const text = inner(node);
      if ((text.from <= from && to <= text.to) || (node.from === from && node.to === to)) return node;
    }
  }
  return null;
}

/** The quote marks at the start of a line (`> `, `>`, or nested `> > `). */
const QUOTE_PREFIX = /^[ \t]{0,3}(?:>[ \t]?)+/;
const isQuoted = (text: string) => QUOTE_PREFIX.test(text);
const isBlank = (text: string) => text.trim() === "";

/** The lines a command works on: the selection's, without a last line it only touches at its start. */
function selectedLines(state: EditorState) {
  const range = state.selection.main;
  const first = state.doc.lineAt(range.from).number;
  let last = state.doc.lineAt(range.to).number;
  if (!range.empty && last > first && state.doc.line(last).from === range.to) last--;
  return { first, last };
}

export function formatState(state: EditorState): FormatState {
  const { from, to } = state.selection.main;
  const { first, last } = selectedLines(state);
  let quoted = 0;
  let text = 0;
  for (let n = first; n <= last; n++) {
    const line = state.doc.line(n).text;
    if (isBlank(line)) continue;
    text++;
    if (isQuoted(line)) quoted++;
  }
  return {
    italic: enclosing(state, EMPHASIS.italic.node, from, to) !== null,
    bold: enclosing(state, EMPHASIS.bold.node, from, to) !== null,
    quote: text > 0 ? quoted === text : isQuoted(state.doc.line(first).text),
  };
}

/**
 * Italic or bold on and off, like in a word processor:
 *  - inside such an emphasis (or with all of it selected): the marks go, the text stays;
 *  - a selection gets the marks, per paragraph and without the spaces at its ends; emphasis of
 *    the same kind it cuts into or contains merges into it;
 *  - the cursor inside a word: the word; elsewhere a pair of marks to type into.
 */
function toggleEmphasis(kind: "italic" | "bold"): Command {
  const { node: name, marker } = EMPHASIS[kind];
  return (view) => {
    const { state } = view;
    const range = state.selection.main;
    const inside = enclosing(state, name, range.from, range.to);
    if (inside) {
      const changes = state.changes(marks(inside).map((m) => ({ from: m.from, to: m.to })));
      const selection = range.empty
        ? EditorSelection.cursor(changes.mapPos(range.head, -1))
        : EditorSelection.range(changes.mapPos(range.from, 1), changes.mapPos(range.to, -1));
      view.dispatch({ changes, selection, scrollIntoView: true, userEvent: "input.format" });
      return true;
    }
    if (range.empty) {
      const word = state.wordAt(range.head);
      if (word && word.from < range.head && range.head < word.to) {
        view.dispatch({
          changes: [
            { from: word.from, insert: marker },
            { from: word.to, insert: marker },
          ],
          selection: EditorSelection.cursor(range.head + marker.length),
          userEvent: "input.format",
        });
      } else {
        view.dispatch({
          changes: { from: range.head, insert: marker + marker },
          selection: EditorSelection.cursor(range.head + marker.length),
          userEvent: "input.format",
        });
      }
      return true;
    }

    // Take in emphasis of this kind the selection cuts into, and drop the marks inside.
    let from = range.from;
    let to = range.to;
    const drop: { from: number; to: number }[] = [];
    tree(state, to).iterate({
      from,
      to,
      enter(node) {
        if (node.name !== name || node.to <= range.from || node.from >= range.to) return;
        from = Math.min(from, node.from);
        to = Math.max(to, node.to);
        for (const m of marks(node.node)) drop.push({ from: m.from, to: m.to });
      },
    });
    drop.sort((a, b) => a.from - b.from);
    let text = "";
    let at = from;
    for (const d of drop) {
      text += state.sliceDoc(at, d.from);
      at = d.to;
    }
    text += state.sliceDoc(at, to);

    // Wrap each paragraph's text (after its quote marks, without the spaces at its ends).
    const startsLine = state.doc.lineAt(from).from === from;
    let firstMark = -1;
    let lastMark = -1;
    let out = "";
    text.split("\n").forEach((line, i) => {
      if (i > 0) out += "\n";
      const prefix = i > 0 || startsLine ? (line.match(QUOTE_PREFIX)?.[0] ?? "") : "";
      const rest = line.slice(prefix.length);
      const m = rest.match(/^(\s*)([\s\S]*?)(\s*)$/)!;
      if (!m[2]) {
        out += line;
        return;
      }
      out += prefix + m[1] + marker;
      if (firstMark < 0) firstMark = out.length;
      out += m[2];
      lastMark = out.length;
      out += marker + m[3];
    });
    if (firstMark < 0) return false;
    view.dispatch({
      changes: { from, to, insert: out },
      selection: EditorSelection.range(from + firstMark, from + lastMark),
      scrollIntoView: true,
      userEvent: "input.format",
    });
    return true;
  };
}

/**
 * Paragraphs as a quote (`> `) and back. Blank lines inside the selection, and those that
 * separate it from a quote right above or below, become `>` so it stays one quote; taking a
 * paragraph out of a quote turns the `>` lines next to it into blank ones.
 */
const toggleQuote: Command = (view) => {
  const { state } = view;
  const { doc } = state;
  const range = state.selection.main;
  const { first, last } = selectedLines(state);
  const remove = formatState(state).quote;
  const changes: { from: number; to: number; insert?: string }[] = [];
  const unquote = (n: number) => {
    const line = doc.line(n);
    const prefix = line.text.match(QUOTE_PREFIX)?.[0];
    if (prefix) changes.push({ from: line.from, to: line.from + prefix.length });
  };
  const quote = (n: number) => {
    const line = doc.line(n);
    if (isQuoted(line.text)) return;
    changes.push({ from: line.from, to: line.from, insert: isBlank(line.text) ? ">" : "> " });
  };
  const bareQuote = (n: number) => n >= 1 && n <= doc.lines && /^[ \t]{0,3}>[ \t]*$/.test(doc.line(n).text);

  if (remove) {
    for (let n = first; n <= last; n++) unquote(n);
    if (bareQuote(first - 1)) unquote(first - 1);
    if (bareQuote(last + 1)) unquote(last + 1);
  } else {
    for (let n = first; n <= last; n++) quote(n);
    // Join a quote right above or below across the blank lines between.
    let above = first - 1;
    while (above >= 1 && isBlank(doc.line(above).text)) above--;
    if (above >= 1 && above < first - 1 && isQuoted(doc.line(above).text)) {
      for (let n = above + 1; n < first; n++) quote(n);
    }
    let below = last + 1;
    while (below <= doc.lines && isBlank(doc.line(below).text)) below++;
    if (below <= doc.lines && below > last + 1 && isQuoted(doc.line(below).text)) {
      for (let n = last + 1; n < below; n++) quote(n);
    }
  }
  if (!changes.length) return false;
  changes.sort((a, b) => a.from - b.from);
  const set = state.changes(changes);
  view.dispatch({
    changes: set,
    selection: range.empty
      ? EditorSelection.cursor(set.mapPos(range.head, 1))
      : EditorSelection.range(set.mapPos(range.from, 1), set.mapPos(range.to, 1)),
    scrollIntoView: true,
    userEvent: "input.format",
  });
  return true;
};

/** Insert a CriticMarkup comment; with a selection, the selection becomes the highlighted range. */
function insertComment(prefix: string): Command {
  return (view) => {
    const { state } = view;
    const spec = state.changeByRange((range) => {
      if (range.empty) {
        const insert = `{>>${prefix}<<}`;
        return {
          changes: { from: range.from, insert },
          range: EditorSelection.cursor(range.from + 3 + prefix.length),
        };
      }
      const open = "{==";
      const close = `==}{>>${prefix}`;
      return {
        changes: [
          { from: range.from, insert: open },
          { from: range.to, insert: `${close}<<}` },
        ],
        range: EditorSelection.cursor(range.to + open.length + close.length),
      };
    });
    view.dispatch(state.update(spec, { scrollIntoView: true, userEvent: "input" }));
    return true;
  };
}

export const formatCommands: Record<FormatKind, Command> = {
  italic: toggleEmphasis("italic"),
  bold: toggleEmphasis("bold"),
  quote: toggleQuote,
  comment: insertComment(""),
  todo: insertComment("TODO: "),
};

/** Runs a format command (from the host's buttons and menus) and gives the editor the focus. */
export function runFormat(view: EditorView, kind: FormatKind): boolean {
  const done = formatCommands[kind](view);
  view.focus();
  return done;
}

export const zadurKeymap: KeyBinding[] = [
  { key: "Mod-b", run: formatCommands.bold },
  { key: "Mod-i", run: formatCommands.italic },
  { key: "Mod-Alt-m", run: formatCommands.comment },
  { key: "Mod-Alt-t", run: formatCommands.todo },
];
