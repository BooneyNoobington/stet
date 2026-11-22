import { StateEffect, StateField } from "@codemirror/state";
import { Decoration, type DecorationSet, EditorView } from "@codemirror/view";

/** A match of the host's find bar in this scene (UTF-16 offsets). */
export interface SearchMatch {
  from: number;
  to: number;
}

/** The matches to highlight, and which of them is the current one (-1: none). */
export const setSearchMatches = StateEffect.define<{ matches: SearchMatch[]; current: number }>();

const matchMark = Decoration.mark({ class: "stet-search-match" });
const currentMark = Decoration.mark({ class: "stet-search-match stet-search-current" });

/**
 * Highlights from the find bar (the host searches the whole book and sends this scene's
 * matches). They move with the text; a match that gets edited loses its highlight until the
 * host searches again, a moment later.
 */
export const searchField = StateField.define<DecorationSet>({
  create: () => Decoration.none,
  update(value, tr) {
    for (const effect of tr.effects) {
      if (!effect.is(setSearchMatches)) continue;
      const length = tr.state.doc.length;
      const { matches, current } = effect.value;
      const ranges = matches
        .map((match, index) => ({ ...match, index }))
        .filter((m) => m.from >= 0 && m.to <= length && m.from < m.to)
        .sort((a, b) => a.from - b.from)
        .map((m) => (m.index === current ? currentMark : matchMark).range(m.from, m.to));
      return Decoration.set(ranges, true);
    }
    if (!tr.docChanged) return value;
    const touched: [number, number][] = [];
    tr.changes.iterChangedRanges((_fromA, _toA, fromB, toB) => touched.push([fromB, toB]));
    return value.map(tr.changes).update({ filter: (from, to) => !touched.some(([a, b]) => from <= b && to >= a) });
  },
  provide: (field) => EditorView.decorations.from(field),
});
