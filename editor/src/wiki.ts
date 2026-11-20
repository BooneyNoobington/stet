import { type Extension, type Range, StateEffect, StateField } from "@codemirror/state";
import {
  Decoration,
  type DecorationSet,
  EditorView,
  hoverTooltip,
  ViewPlugin,
  type ViewUpdate,
} from "@codemirror/view";
import { settingsField } from "./settings";

/**
 * Wiki names in the prose: a quiet dotted underline, a card with the entry's quick facts on
 * hover, and ⌘-click to open the entry. Nothing is added to the text itself.
 */

export interface WikiTerm {
  /** The name as written (title or alias). */
  name: string;
  id: string;
  title: string;
  kind: string;
  facts: [string, string][];
  summary: string;
}

interface WikiState {
  byName: Map<string, WikiTerm>;
  regex: RegExp | null;
}

export const setWikiTerms = StateEffect.define<WikiTerm[]>();

function escape(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

export function wikiState(terms: WikiTerm[]): WikiState {
  const byName = new Map(terms.map((t) => [t.name, t]));
  const names = [...byName.keys()].sort((a, b) => b.length - a.length);
  const regex = names.length
    ? new RegExp(`(?<![\\p{L}\\p{N}])(${names.map(escape).join("|")})(?:s|’s|'s)?(?![\\p{L}\\p{N}])`, "gu")
    : null;
  return { byName, regex };
}

export const wikiField = StateField.define<WikiState>({
  create: () => wikiState([]),
  update(value, tr) {
    for (const effect of tr.effects) {
      if (effect.is(setWikiTerms)) value = wikiState(effect.value);
    }
    return value;
  },
});

interface Found {
  from: number;
  to: number;
  term: WikiTerm;
}

function find(state: WikiState, text: string, offset: number): Found[] {
  if (!state.regex) return [];
  const found: Found[] = [];
  state.regex.lastIndex = 0;
  for (const match of text.matchAll(state.regex)) {
    const term = state.byName.get(match[1]);
    if (term && match.index !== undefined) {
      found.push({ from: offset + match.index, to: offset + match.index + match[0].length, term });
    }
  }
  return found;
}

function build(view: EditorView): DecorationSet {
  const state = view.state.field(wikiField);
  if (!state.regex || view.state.field(settingsField).showWikiTerms === false) return Decoration.none;
  const decorations: Range<Decoration>[] = [];
  for (const { from, to } of view.visibleRanges) {
    for (const hit of find(state, view.state.sliceDoc(from, to), from)) {
      decorations.push(
        Decoration.mark({ class: "stet-wiki-term", attributes: { "data-wiki": hit.term.id } }).range(hit.from, hit.to),
      );
    }
  }
  return Decoration.set(decorations, true);
}

const underline = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet;
    constructor(view: EditorView) {
      this.decorations = build(view);
    }
    update(update: ViewUpdate) {
      if (
        update.docChanged ||
        update.viewportChanged ||
        update.startState.field(wikiField) !== update.state.field(wikiField) ||
        update.startState.field(settingsField) !== update.state.field(settingsField)
      ) {
        this.decorations = build(update.view);
      }
    }
  },
  { decorations: (plugin) => plugin.decorations },
);

const kindLabels: Record<string, string> = { character: "Figur", place: "Ort", term: "Begriff", note: "Notiz" };

function card(term: WikiTerm, open: (id: string) => void): HTMLElement {
  const dom = document.createElement("div");
  dom.className = "stet-wiki-card";
  const head = dom.appendChild(document.createElement("div"));
  head.className = "stet-wiki-card-head";
  head.append(Object.assign(document.createElement("strong"), { textContent: term.title }));
  head.append(Object.assign(document.createElement("span"), { textContent: kindLabels[term.kind] ?? term.kind }));
  if (term.facts.length) {
    const table = dom.appendChild(document.createElement("dl"));
    for (const [key, value] of term.facts) {
      table.append(Object.assign(document.createElement("dt"), { textContent: key }));
      table.append(Object.assign(document.createElement("dd"), { textContent: value.replace(/\[\[|\]\]/g, "") }));
    }
  }
  if (term.summary) {
    dom.append(Object.assign(document.createElement("p"), { textContent: term.summary }));
  }
  const link = dom.appendChild(document.createElement("button"));
  link.type = "button";
  link.textContent = "Im Wiki öffnen  ⌘-Klick";
  link.addEventListener("mousedown", (event) => {
    event.preventDefault();
    open(term.id);
  });
  return dom;
}

export function wikiExtensions(open: (id: string) => void): Extension[] {
  return [
    underline,
    hoverTooltip(
      (view, pos) => {
        const state = view.state.field(wikiField);
        if (!state.regex || view.state.field(settingsField).showWikiTerms === false) return null;
        const line = view.state.doc.lineAt(pos);
        const hit = find(state, line.text, line.from).find((h) => h.from <= pos && pos <= h.to);
        if (!hit) return null;
        return { pos: hit.from, end: hit.to, above: true, create: () => ({ dom: card(hit.term, open) }) };
      },
      { hoverTime: 450 },
    ),
    EditorView.domEventHandlers({
      mousedown(event) {
        if (!event.metaKey) return false;
        const target = (event.target as HTMLElement).closest<HTMLElement>(".stet-wiki-term");
        const id = target?.dataset.wiki;
        if (!id) return false;
        event.preventDefault();
        open(id);
        return true;
      },
    }),
  ];
}
