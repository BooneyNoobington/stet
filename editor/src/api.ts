import type { EditorSettings } from "./settings";
import type { TextStats } from "./stats";

/** Messages the editor posts to the host (the Swift app) via `webkit.messageHandlers.stet`. */
export type HostMessage =
  | { type: "ready" }
  | { type: "changed" }
  | { type: "stats"; words: number; characters: number }
  | { type: "activity" };

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
  setSettings(patch: Partial<EditorSettings>): EditorSettings;
  getSettings(): EditorSettings;
  stats(): TextStats;
  focus(): void;
  /** Replaces the document with the current text repeated up to `targetWords`, then measures. */
  loadStressTest(targetWords?: number): StressTestResult | null;
}
