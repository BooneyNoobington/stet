import { stripCritic } from "./critic";

const segmenters = new Map<string, Intl.Segmenter>();

function segmenter(language: string): Intl.Segmenter {
  let s = segmenters.get(language);
  if (!s) {
    s = new Intl.Segmenter(language, { granularity: "word" });
    segmenters.set(language, s);
  }
  return s;
}

export interface TextStats {
  words: number;
  characters: number;
}

/** Word and character counts of the prose: comments excluded, Markdown marks ignored. */
export function textStats(text: string, language: string): TextStats {
  const prose = stripCritic(text);
  let words = 0;
  for (const part of segmenter(language).segment(prose)) {
    if (part.isWordLike) words++;
  }
  const characters = prose.replace(/[*_#\n]/g, "").length;
  return { words, characters };
}
