import { isolateHistory } from "@codemirror/commands";
import { EditorView } from "@codemirror/view";
import { type QuoteStyle, settingsField } from "./settings";

/**
 * Typographic substitutions while typing:
 *   "  → » « / „ “ / “ ”   (the book's style)
 *   '  → › ‹ / ‚ ‘ / ‘ ’, or ’ as an apostrophe after a letter
 *   " -- " → " – "        (only between spaces, so CriticMarkup `{--` stays intact)
 *   "..."  → "…"
 * Whether a quote opens or closes depends on what comes before it, emphasis stars aside
 * (*"Ja"*, "*gut*"): the same rules as `Typography` in ZadurCore, which exports and
 * "Anführungszeichen angleichen" use. Each substitution is its own undo step; ⌘Z right after
 * restores the plain character.
 */

const QUOTES: Record<QuoteStyle, { dOpen: string; dClose: string; sOpen: string; sClose: string }> = {
  de: { dOpen: "„", dClose: "“", sOpen: "‚", sClose: "‘" },
  guillemets: { dOpen: "»", dClose: "«", sOpen: "›", sClose: "‹" },
  en: { dOpen: "“", dClose: "”", sOpen: "‘", sClose: "’" },
};

const APOSTROPHE = "’";
const LETTER_OR_DIGIT = /[\p{L}\p{N}]/u;

function isOpeningContext(prev: string, style: (typeof QUOTES)[QuoteStyle]): boolean {
  return (
    prev === "" ||
    /[\s([{–—\-/>]/.test(prev) ||
    prev === style.dOpen ||
    prev === style.sOpen
  );
}

export const typography = EditorView.inputHandler.of((view, from, to, text) => {
  if (view.composing) return false;
  const { state } = view;
  const before = state.sliceDoc(Math.max(0, from - 3), from);
  const prev = before.slice(-1);

  let replaceFrom = from;
  let insert: string | null = null;

  if (text === '"' || text === "'") {
    const style = QUOTES[state.field(settingsField).quotes];
    const significant = state.sliceDoc(Math.max(0, from - 12), from).replace(/[*_]+$/, "").slice(-1);
    if (text === "'" && LETTER_OR_DIGIT.test(prev)) {
      // After a letter it's an apostrophe, unless a single quote is open in this paragraph.
      const line = state.doc.lineAt(from);
      const lineBefore = state.sliceDoc(line.from, from);
      const quoteOpen = lineBefore.lastIndexOf(style.sOpen) > lineBefore.lastIndexOf(style.sClose);
      insert = quoteOpen && style.sClose !== APOSTROPHE ? style.sClose : APOSTROPHE;
    } else {
      const opening = isOpeningContext(significant, style);
      insert = text === '"' ? (opening ? style.dOpen : style.dClose) : opening ? style.sOpen : style.sClose;
    }
  } else if (text === " " && /(^|\s)--$/.test(before) && from === to) {
    replaceFrom = from - 2;
    insert = "– ";
  } else if (text === "." && before.endsWith("..") && from === to) {
    replaceFrom = from - 2;
    insert = "…";
  }

  if (insert === null) return false;
  // Two steps, like autocorrect in Pages or Word: first the character as typed, then the
  // substitution as its own undo step, so ⌘Z right after brings back the plain character.
  view.dispatch({
    changes: { from, to, insert: text },
    selection: { anchor: from + text.length },
    userEvent: "input.type",
  });
  view.dispatch({
    changes: { from: replaceFrom, to: from + text.length, insert },
    selection: { anchor: replaceFrom + insert.length },
    scrollIntoView: true,
    userEvent: "input.type.smart",
    annotations: isolateHistory.of("full"),
  });
  return true;
});
