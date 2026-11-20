import type { Misspelling } from "./spelling";
import type { EditorSettings } from "./settings";
import type { TextStats } from "./stats";
import type { WikiTerm } from "./wiki";

/** Messages the editor posts to the host (the Swift app) via `webkit.messageHandlers.stet`. */
export type HostMessage =
  | { type: "ready" }
  | { type: "changed" }
  | { type: "stats"; words: number; characters: number }
  | { type: "activity" }
  | { type: "openWiki"; id: string }
  /** Sent on right-click, before the native menu opens: the selection (or the word under the
   *  mouse) and the wiki entry under the mouse, if any. */
  | { type: "contextMenu"; text: string; wikiId: string | null; from: number; to: number };

export interface StressTestResult {
  words: number;
  characters: number;
  paragraphs: number;
  comments: number;
  loadMs: number;
  statsMs: number;
  msPerKeystroke: number;
}

/** Exposed as `window.stet`; the host calls these with `callAsyncJavaScript`. */
export interface StetEditorAPI {
  load(text: string): { length: number };
  getText(): string;
  /** Replaces the whole text as one undoable edit (used to restore an older version). */
  replaceText(text: string): void;
  /** Selects a range (UTF-16 offsets), scrolls it to the middle and focuses the editor. */
  select(from: number, to: number): void;
  /** Replaces a range as one undoable edit. */
  replaceRange(from: number, to: number, text: string): void;
  /** Wraps the selection as `{==…==}{>>comment<<}`, or inserts `{>>comment<<}` at the cursor. */
  insertComment(comment: string): void;
  /** Wraps a range as `{==…==}{>>comment<<}`. */
  commentRange(from: number, to: number, comment: string): void;
  /** Names with wiki entries, for underlining and the fact cards. */
  setWikiTerms(terms: WikiTerm[]): void;
  /** The selected text (main selection). */
  selectedText(): string;
  /** Red wavy lines under these words (offsets checked against the words); returns how many show. */
  setMisspellings(list: Misspelling[]): number;
  setSettings(patch: Partial<EditorSettings>): EditorSettings;
  getSettings(): EditorSettings;
  stats(): TextStats;
  focus(): void;
  /** Replaces the document with the current text repeated up to `targetWords`, then measures. */
  loadStressTest(targetWords?: number): StressTestResult | null;
}
