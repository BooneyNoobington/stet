import { type Range, StateField } from "@codemirror/state";
import {
  Decoration,
  type DecorationSet,
  EditorView,
  ViewPlugin,
  type ViewUpdate,
  WidgetType,
} from "@codemirror/view";
import { selectionTouches } from "./livePreview";
import { settingsField } from "./settings";

/**
 * CriticMarkup comments and TODOs:
 *
 *   {>>comment<<}                 comment at a point
 *   {==range==}{>>comment<<}      comment on a range
 *   {>>TODO: …<<}                 TODO
 *   {>>@Gisela: …<<}              comment by someone else
 *
 * Constructs never span lines (a paragraph is one line), which keeps parsing
 * simple and lets the decorations come from a view plugin.
 */

export type CriticKind = "comment" | "todo" | "highlight";

export interface CriticItem {
  /** Whole construct, including delimiters. */
  from: number;
  to: number;
  kind: CriticKind;
  /** Highlighted text (inside `{== ==}`), if any. */
  highlight?: { from: number; to: number };
  /** Comment text (inside `{>> <<}`), if any. */
  comment?: { from: number; to: number };
  author?: string;
  /** Comment text without the TODO / @author prefix. */
  body: string;
  /** 1-based number among comments and TODOs; 0 for a bare highlight. */
  index: number;
}

const OPEN = 3; // length of "{==" / "{>>"
const CLOSE = 3; // length of "==}" / "<<}"
const CRITIC = /\{==([^\n]*?)==\}(?:\{>>([^\n]*?)<<\})?|\{>>([^\n]*?)<<\}/g;
const TODO_PREFIX = /^\s*TODO\b[:\s]*/i;
const AUTHOR_PREFIX = /^\s*@([^:\n]{1,40}):\s*/;

function classify(raw: string): { kind: CriticKind; body: string; author?: string } {
  const todo = TODO_PREFIX.exec(raw);
  if (todo) return { kind: "todo", body: raw.slice(todo[0].length).trim() };
  const author = AUTHOR_PREFIX.exec(raw);
  if (author) return { kind: "comment", body: raw.slice(author[0].length).trim(), author: author[1].trim() };
  return { kind: "comment", body: raw.trim() };
}

export function parseCritic(text: string): CriticItem[] {
  const items: CriticItem[] = [];
  let counter = 0;
  for (const match of text.matchAll(CRITIC)) {
    const from = match.index;
    const to = from + match[0].length;
    const [, highlighted, attached, standalone] = match;

    if (highlighted !== undefined) {
      const highlight = { from: from + OPEN, to: from + OPEN + highlighted.length };
      if (attached === undefined) {
        items.push({ from, to, kind: "highlight", highlight, body: "", index: 0 });
        continue;
      }
      const commentFrom = highlight.to + CLOSE + OPEN;
      const comment = { from: commentFrom, to: commentFrom + attached.length };
      items.push({ from, to, highlight, comment, index: ++counter, ...classify(attached) });
    } else if (standalone !== undefined) {
      const comment = { from: from + OPEN, to: from + OPEN + standalone.length };
      items.push({ from, to, comment, index: ++counter, ...classify(standalone) });
    }
  }
  return items;
}

/** All CriticMarkup constructs in the document, re-parsed on every change. */
export const criticField = StateField.define<CriticItem[]>({
  create: (state) => parseCritic(state.doc.toString()),
  update: (items, tr) => (tr.docChanged ? parseCritic(tr.state.doc.toString()) : items),
});

/** Text with comments removed and highlight delimiters dropped, for word counts and export. */
export function stripCritic(text: string): string {
  return text.replace(/\{>>[^\n]*?<<\}/g, "").replace(/\{==|==\}/g, "");
}

// ---------------------------------------------------------------------------
// Inline decorations

class MarkerWidget extends WidgetType {
  constructor(
    readonly index: number,
    readonly todo: boolean,
  ) {
    super();
  }
  eq(other: MarkerWidget) {
    return other.index === this.index && other.todo === this.todo;
  }
  toDOM() {
    const el = document.createElement("sup");
    el.className = "zadur-comment-marker" + (this.todo ? " is-todo" : "");
    el.textContent = String(this.index);
    el.setAttribute("aria-label", this.todo ? `TODO ${this.index}` : `Kommentar ${this.index}`);
    return el;
  }
  ignoreEvent() {
    // Let a click place the cursor next to the marker, which reveals the raw comment.
    return false;
  }
}

const hidden = Decoration.replace({});
const raw = Decoration.mark({ class: "zadur-critic-raw" });
const highlightMark = Decoration.mark({ class: "zadur-critic-hl" });
const highlightTodoMark = Decoration.mark({ class: "zadur-critic-hl is-todo" });

function buildDecorations(view: EditorView): DecorationSet {
  const { state } = view;
  const { showComments } = state.field(settingsField);
  const { from: vpFrom, to: vpTo } = view.viewport;
  const decorations: Range<Decoration>[] = [];

  for (const item of state.field(criticField)) {
    if (item.to < vpFrom || item.from > vpTo) continue;

    if (selectionTouches(state, item.from, item.to)) {
      decorations.push(raw.range(item.from, item.to));
      continue;
    }

    const marker = item.comment
      ? Decoration.replace({ widget: new MarkerWidget(item.index, item.kind === "todo") })
      : hidden;

    if (item.highlight) {
      decorations.push(hidden.range(item.from, item.highlight.from));
      if (showComments && item.highlight.to > item.highlight.from) {
        decorations.push(
          (item.kind === "todo" ? highlightTodoMark : highlightMark).range(item.highlight.from, item.highlight.to),
        );
      }
      decorations.push((showComments ? marker : hidden).range(item.highlight.to, item.to));
    } else {
      decorations.push((showComments ? marker : hidden).range(item.from, item.to));
    }
  }
  return Decoration.set(decorations, true);
}

export const criticDecorations = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet;
    constructor(view: EditorView) {
      this.decorations = buildDecorations(view);
    }
    update(update: ViewUpdate) {
      if (
        update.docChanged ||
        update.viewportChanged ||
        update.selectionSet ||
        update.startState.field(settingsField) !== update.state.field(settingsField)
      ) {
        this.decorations = buildDecorations(update.view);
      }
    }
  },
  { decorations: (plugin) => plugin.decorations },
);

// ---------------------------------------------------------------------------
// Comment rail: bubbles in the right margin, aligned with their anchor line.

interface RailEntry {
  item: CriticItem;
  top: number;
}

interface RailMeasure {
  show: boolean;
  left: number;
  entries: RailEntry[];
}

const BUBBLE_GAP = 8;

class CommentRail {
  readonly dom: HTMLElement;

  constructor(readonly view: EditorView) {
    this.dom = document.createElement("div");
    this.dom.className = "zadur-comment-rail";
    this.dom.setAttribute("role", "complementary");
    this.dom.setAttribute("aria-label", "Kommentare");
    this.dom.addEventListener("mousedown", this.onMouseDown);
    view.scrollDOM.appendChild(this.dom);
    this.schedule();
  }

  update(update: ViewUpdate) {
    if (
      update.docChanged ||
      update.viewportChanged ||
      update.geometryChanged ||
      update.selectionSet ||
      update.startState.field(settingsField) !== update.state.field(settingsField)
    ) {
      this.schedule();
    }
  }

  schedule() {
    this.view.requestMeasure<RailMeasure>({
      key: this,
      read: (view) => this.read(view),
      write: (measure, view) => this.write(measure, view),
    });
  }

  read(view: EditorView): RailMeasure {
    const { showComments } = view.state.field(settingsField);
    if (!showComments) return { show: false, left: 0, entries: [] };

    const scroller = view.scrollDOM;
    const scrollRect = scroller.getBoundingClientRect();
    const contentRect = view.contentDOM.getBoundingClientRect();
    const { from, to } = view.viewport;
    const entries: RailEntry[] = [];

    for (const item of view.state.field(criticField)) {
      if (!item.comment || item.to < from || item.from > to) continue;
      const anchor = item.highlight ? item.highlight.from : item.from;
      const coords = view.coordsAtPos(anchor, 1);
      if (!coords) continue;
      entries.push({ item, top: coords.top - scrollRect.top + scroller.scrollTop });
    }
    const left = contentRect.right - scrollRect.left + scroller.scrollLeft + 28;
    return { show: true, left, entries };
  }

  write(measure: RailMeasure, view: EditorView) {
    this.dom.style.display = measure.show ? "" : "none";
    this.dom.textContent = "";
    if (!measure.show) return;
    this.dom.style.left = `${measure.left}px`;

    const head = view.state.selection.main.head;
    let lastBottom = -Infinity;
    for (const { item, top } of measure.entries) {
      const bubble = document.createElement("div");
      const active = head >= item.from && head <= item.to;
      bubble.className =
        "zadur-bubble" + (item.kind === "todo" ? " is-todo" : "") + (active ? " is-active" : "");
      bubble.dataset.target = String(item.comment!.from);

      const meta = document.createElement("div");
      meta.className = "zadur-bubble-meta";
      const number = document.createElement("span");
      number.textContent = String(item.index);
      const label = document.createElement("span");
      label.className = "zadur-bubble-kind";
      label.textContent = item.kind === "todo" ? "TODO" : (item.author ?? "Notiz");
      meta.append(number, label);

      const body = document.createElement("div");
      body.className = "zadur-bubble-body";
      body.textContent = item.body || "…";

      bubble.append(meta, body);
      this.dom.appendChild(bubble);

      const y = Math.max(top, lastBottom + BUBBLE_GAP);
      bubble.style.top = `${y}px`;
      lastBottom = y + bubble.offsetHeight;
    }
  }

  onMouseDown = (event: MouseEvent) => {
    const bubble = (event.target as HTMLElement).closest<HTMLElement>(".zadur-bubble");
    if (!bubble) return;
    event.preventDefault();
    const target = Number(bubble.dataset.target);
    this.view.dispatch({ selection: { anchor: target }, scrollIntoView: true });
    this.view.focus();
  };

  destroy() {
    this.dom.removeEventListener("mousedown", this.onMouseDown);
    this.dom.remove();
  }
}

export const commentRail = ViewPlugin.fromClass(CommentRail);
