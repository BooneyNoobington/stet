import { EditorSelection } from "@codemirror/state";
import type { Command, KeyBinding } from "@codemirror/view";

/** Wrap the selection in `marker`, or unwrap it if it is already wrapped. */
function toggleMarker(marker: string): Command {
  const len = marker.length;
  return (view) => {
    const { state } = view;
    const spec = state.changeByRange((range) => {
      const before = state.sliceDoc(range.from - len, range.from);
      const after = state.sliceDoc(range.to, range.to + len);
      // For italics, don't strip one star off a bold pair (`**word**`), unless it's `***`.
      const insideBold =
        marker === "*" &&
        state.sliceDoc(range.from - 2, range.from) === "**" &&
        state.sliceDoc(range.from - 3, range.from) !== "***";

      if (before === marker && after === marker && !insideBold) {
        return {
          changes: [
            { from: range.from - len, to: range.from },
            { from: range.to, to: range.to + len },
          ],
          range: EditorSelection.range(range.from - len, range.to - len),
        };
      }
      return {
        changes: [
          { from: range.from, insert: marker },
          { from: range.to, insert: marker },
        ],
        range: EditorSelection.range(range.from + len, range.to + len),
      };
    });
    view.dispatch(state.update(spec, { scrollIntoView: true, userEvent: "input" }));
    return true;
  };
}

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

export const stetKeymap: KeyBinding[] = [
  { key: "Mod-b", run: toggleMarker("**") },
  { key: "Mod-i", run: toggleMarker("*") },
  { key: "Mod-Alt-m", run: insertComment("") },
  { key: "Mod-Alt-t", run: insertComment("TODO: ") },
];
