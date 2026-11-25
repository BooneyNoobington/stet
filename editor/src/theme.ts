import { HighlightStyle } from "@codemirror/language";
import { EditorView } from "@codemirror/view";
import { tags as t } from "@lezer/highlight";

/** Structural editor styles. Colors and sizes come from CSS variables set in editor.css and by settings. */
export const zadurTheme = EditorView.theme({
  "&": {
    height: "100%",
    backgroundColor: "var(--zadur-bg)",
    color: "var(--zadur-text)",
    fontSize: "var(--zadur-size)",
  },
  "&.cm-focused": { outline: "none" },
  ".cm-scroller": {
    fontFamily: "var(--zadur-font)",
    lineHeight: "var(--zadur-line-height)",
    padding: "0 32px",
  },
  ".cm-content": {
    maxWidth: "var(--zadur-column)",
    margin: "0 auto",
    padding: "12vh 0 45vh",
    caretColor: "var(--zadur-accent)",
  },
  "&.zadur-comments-on .cm-scroller": {
    paddingRight: "calc(var(--zadur-rail) + 56px)",
  },
  ".cm-line": { padding: "0" },
  // Quotes (a letter, an epigraph …): indented on both sides, with a quiet rule on the left.
  ".cm-line.zadur-quote": {
    padding: "0 1.6em 0 1.3em",
    marginLeft: "0.3em",
    borderLeft: "2px solid var(--zadur-quote-rule)",
  },
  ".cm-activeLine": { backgroundColor: "transparent" },
  "&.zadur-focus .cm-line": { opacity: "0.28", transition: "opacity .25s ease" },
  "&.zadur-focus .cm-line.cm-activeLine": { opacity: "1" },
});

export const proseHighlight = HighlightStyle.define([
  { tag: t.emphasis, fontStyle: "italic" },
  { tag: t.strong, fontWeight: "700" },
  { tag: t.heading1, fontSize: "1.6em", fontWeight: "600" },
  { tag: t.heading2, fontSize: "1.35em", fontWeight: "600" },
  { tag: [t.heading3, t.heading4, t.heading5, t.heading6], fontSize: "1.15em", fontWeight: "600" },
  { tag: t.processingInstruction, color: "var(--zadur-muted)" },
  { tag: t.contentSeparator, color: "var(--zadur-muted)" },
  { tag: t.monospace, fontFamily: "var(--zadur-mono)", fontSize: "0.9em" },
  { tag: t.link, color: "var(--zadur-accent)" },
  { tag: t.url, color: "var(--zadur-muted)" },
]);
