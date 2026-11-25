import { syntaxTree } from "@codemirror/language";
import type { EditorState, Range } from "@codemirror/state";
import {
  Decoration,
  type DecorationSet,
  EditorView,
  ViewPlugin,
  type ViewUpdate,
  WidgetType,
} from "@codemirror/view";

/**
 * Live preview: hides Markdown syntax (emphasis marks, heading marks, thematic
 * breaks, quote marks) unless the selection touches the construct; quotes are indented.
 * Only decorations are added; the document text is never modified.
 */

const hidden = Decoration.replace({});
const quoteLine = Decoration.line({ class: "zadur-quote" });

class SceneBreakWidget extends WidgetType {
  eq() {
    return true;
  }
  toDOM() {
    const el = document.createElement("span");
    el.className = "zadur-scene-break";
    el.textContent = "⁂";
    el.setAttribute("aria-label", "Szenenwechsel");
    return el;
  }
  ignoreEvent() {
    return false;
  }
}

const sceneBreak = Decoration.replace({ widget: new SceneBreakWidget() });

export function selectionTouches(state: EditorState, from: number, to: number): boolean {
  return state.selection.ranges.some((r) => r.from <= to && r.to >= from);
}

function build(view: EditorView): DecorationSet {
  const { state } = view;
  const decorations: Range<Decoration>[] = [];
  const tree = syntaxTree(state);

  for (const { from, to } of view.visibleRanges) {
    tree.iterate({
      from,
      to,
      enter(ref) {
        const name = ref.name;
        if (name === "Emphasis" || name === "StrongEmphasis") {
          if (selectionTouches(state, ref.from, ref.to)) return;
          for (let child = ref.node.firstChild; child; child = child.nextSibling) {
            if (child.name === "EmphasisMark") decorations.push(hidden.range(child.from, child.to));
          }
        } else if (name.startsWith("ATXHeading")) {
          const line = state.doc.lineAt(ref.from);
          if (selectionTouches(state, line.from, line.to)) return;
          const mark = ref.node.firstChild;
          if (mark?.name === "HeaderMark") {
            let end = mark.to;
            if (state.sliceDoc(end, end + 1) === " ") end++;
            if (end > mark.from) decorations.push(hidden.range(mark.from, end));
          }
        } else if (name === "Blockquote") {
          // Every line of the quote, once (nested quotes are inside it).
          if (ref.node.parent?.name === "Blockquote") return;
          const start = Math.max(ref.from, from);
          const end = Math.min(ref.to, to);
          for (let pos = state.doc.lineAt(start).from; pos <= end; ) {
            const line = state.doc.lineAt(pos);
            decorations.push(quoteLine.range(line.from));
            pos = line.to + 1;
          }
        } else if (name === "QuoteMark") {
          const line = state.doc.lineAt(ref.from);
          if (selectionTouches(state, line.from, line.to)) return;
          let end = ref.to;
          if (state.sliceDoc(end, end + 1) === " ") end++;
          decorations.push(hidden.range(ref.from, end));
        } else if (name === "HorizontalRule") {
          if (!selectionTouches(state, ref.from, ref.to)) {
            decorations.push(sceneBreak.range(ref.from, ref.to));
          }
          return false;
        }
      },
    });
  }
  return Decoration.set(decorations, true);
}

export const livePreview = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet;
    constructor(view: EditorView) {
      this.decorations = build(view);
    }
    update(update: ViewUpdate) {
      if (
        update.docChanged ||
        update.viewportChanged ||
        update.selectionSet ||
        syntaxTree(update.startState) !== syntaxTree(update.state)
      ) {
        this.decorations = build(update.view);
      }
    }
  },
  { decorations: (plugin) => plugin.decorations },
);
