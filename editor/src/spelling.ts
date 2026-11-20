import { StateEffect, StateField } from "@codemirror/state";
import { Decoration, type DecorationSet, EditorView } from "@codemirror/view";

/** A misspelled word as the host found it (UTF-16 offsets plus the word, to check it still fits). */
export interface Misspelling {
  from: number;
  to: number;
  word: string;
  /** "hint": a usage note (e.g. the possessive apostrophe in German), drawn more quietly. */
  kind?: "hint";
}

export const setMisspellings = StateEffect.define<Misspelling[]>();

const mark = Decoration.mark({ class: "stet-misspelled" });
const hintMark = Decoration.mark({ class: "stet-hint" });

/**
 * Red wavy lines from the host's spelling check (macOS's dictionaries, plus the book's words and
 * the wiki's names). They move with the text; a word being typed in loses its line until the
 * next check, a moment later.
 */
export const misspellingField = StateField.define<DecorationSet>({
  create: () => Decoration.none,
  update(value, tr) {
    for (const effect of tr.effects) {
      if (!effect.is(setMisspellings)) continue;
      const doc = tr.state.doc;
      const ranges = effect.value
        .filter((m) => m.from >= 0 && m.to <= doc.length && m.from < m.to && doc.sliceString(m.from, m.to) === m.word)
        .sort((a, b) => a.from - b.from)
        .map((m) => (m.kind === "hint" ? hintMark : mark).range(m.from, m.to));
      return Decoration.set(ranges, true);
    }
    if (!tr.docChanged) return value;
    const touched: [number, number][] = [];
    tr.changes.iterChangedRanges((_fromA, _toA, fromB, toB) => touched.push([fromB, toB]));
    return value.map(tr.changes).update({ filter: (from, to) => !touched.some(([a, b]) => from <= b && to >= a) });
  },
  provide: (field) => EditorView.decorations.from(field),
});
