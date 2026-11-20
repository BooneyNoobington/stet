import { StateEffect, StateField } from "@codemirror/state";

export type FontChoice = "serif" | "sans" | "mono";
export type QuoteStyle = "de" | "guillemets" | "en";

/** Display settings for the writing pane. Local to the device, never versioned. */
export interface EditorSettings {
  font: FontChoice;
  /** Font size in px. */
  fontSize: number;
  lineHeight: number;
  /** Text column width in em. */
  columnWidth: number;
  /** Smart-quote style; in the app this follows the book's language. */
  quotes: QuoteStyle;
  /** BCP 47 language tag, used for spellcheck, hyphenation and word segmentation. */
  language: string;
  showComments: boolean;
  focusMode: boolean;
  /** Underline names that have a wiki entry. */
  showWikiTerms: boolean;
}

export const defaultSettings: EditorSettings = {
  font: "serif",
  fontSize: 19,
  lineHeight: 1.65,
  columnWidth: 36,
  quotes: "de",
  language: "de",
  showComments: true,
  focusMode: false,
  showWikiTerms: true,
};

export const fontStacks: Record<FontChoice, string> = {
  serif: '"Iowan Old Style", "New York", ui-serif, Georgia, serif',
  sans: '-apple-system, system-ui, "Helvetica Neue", sans-serif',
  mono: 'ui-monospace, "SF Mono", Menlo, monospace',
};

export const setSettings = StateEffect.define<Partial<EditorSettings>>();

export const settingsField = StateField.define<EditorSettings>({
  create: () => defaultSettings,
  update(value, tr) {
    for (const effect of tr.effects) {
      if (effect.is(setSettings)) value = { ...value, ...effect.value };
    }
    return value;
  },
});
