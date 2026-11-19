# Editor spike: CodeMirror 6 in a native Mac shell

**Question:** can a CodeMirror 6 writing pane inside a SwiftUI app feel native enough for Stet, while keeping the file exactly as typed?

**Status:** built, and the automated checks pass. The hands-on checklist below is still open. It decides go / no-go. The spike has since grown into the real app (Phase 1); the editor is the same.

## Run it

```bash
./scripts/build.sh
```

```bash
open build/Stet.app
```

Browser version (same editor, with a small dev toolbar), served on http://localhost:5173:

```bash
npm --prefix editor run dev
```

Automated bridge test against real WebKit (prints a JSON report, exits non-zero on failure):

```bash
build/Stet.app/Contents/MacOS/Stet --selftest
```

To debug the editor inside the app, use Safari ▸ Develop ▸ *your Mac* ▸ Stet. The web view is inspectable.

## What's in it

| Area | Behaviour |
|---|---|
| Live preview | `*kursiv*`, `**fett**`, `# Überschrift` and `***` (shown as ⁂) hide their symbols until the cursor touches them |
| Comments | `{==Text==}{>>Kommentar<<}`, `{>>Kommentar<<}`, `{>>TODO: …<<}`, `{>>@Name: …<<}` become numbered markers with bubbles in the margin. Clicking a bubble jumps to the comment. The toolbar toggle hides all of them |
| Typography | `"` → „ “ / » « / “ ”, `'` → ‚ ‘ or apostrophe ’, ` -- ` → ` – `, `...` → `…`. ⌘Z right after brings back the plain character |
| Focus mode | dims every paragraph except the current one, with typewriter scrolling |
| Theming | font (Serif/Sans/Mono), size, quote style. Light/dark follows the system |
| Shortcuts | ⌘B bold, ⌘I italic, ⌥⌘M comment (on the selection, if any), ⌥⌘T TODO |


## Automated results (2026-11-19, Apple Silicon, macOS 27.2)

`--selftest` in the built app (real WebKit):

| Check | Result |
|---|---|
| Round trip load → getText, byte for byte: sample scene, decomposed umlauts (NFD), emoji, tabs/trailing spaces, CriticMarkup edge cases, no final newline | all identical ✓ |
| `stats` message from JS reaches Swift | 510 words for the sample ✓ |
| Settings from Swift reach the editor | ✓ |
| 15,000 words (616 paragraphs, 118 comments) | load 2 ms, word count 2 ms, **0.17 ms per keystroke** |
| 60,000 words (a whole novel in one scene, 472 comments) | load 2 ms, word count 6 ms, **0.44 ms per keystroke** |
| CRLF line endings | normalized to LF, as expected (see below) |

"Per keystroke" covers the editor's own work (parsing, decorations, DOM update), not the browser's layout pass. The budget for a frame is 16 ms. The checklist below covers how it actually feels.

Also checked by hand in the browser: smart quotes, dashes, ellipsis, ⌘Z restoring the plain character, revealing hidden Markdown and comment syntax at the cursor, ⌥⌘M inserting a comment, the comments toggle, focus mode.

## Hands-on checklist (needs you, on your Mac)

These can't be tested from outside. They are what "feels native" means. Note anything that feels off, however small.

**Typing**
- [ ] German keyboard dead keys: `^` + `e` → ê, `´` + `e` → é, `` ` `` + `a` → à
- [ ] Press and hold a letter (accent popup: hold `a` → à á â …)
- [ ] Dictation (press 🎤 or fn twice) inserts text at the cursor
- [ ] Typing feels instant in your longest scene, including at its end (the 60,000-word stress test runs in `--selftest`)

**macOS text services**
- [ ] Spelling: red underlines for German words; right-click shows suggestions; Edit ▸ Spelling and Grammar works
- [ ] Do macOS's own substitutions (System Settings ▸ Keyboard ▸ Text Input: smart quotes, auto-capitalization, text replacements like "omw") clash with Stet's smart quotes?
- [ ] Look Up (three-finger tap or ⌃⌘D on a word)
- [ ] Writing Tools / Apple Intelligence on a selection, if enabled
- [ ] Services menu on a selection

**Editing feel**
- [ ] Double-click selects a word, triple-click a paragraph; ⇧⌥→ selects word by word across hidden `*` marks
- [ ] ⌘Z / ⇧⌘Z through a longer editing session: are the undo steps a sensible size?
- [ ] Arrow keys across a comment marker: the raw `{>>…<<}` should appear as soon as the cursor touches it, and nothing gets deleted by surprise
- [ ] Paste from Pages/Word/Mail (plain text only for now; formatting is dropped)
- [ ] Trackpad scrolling and momentum feel like a native text view

**Looks**
- [ ] Dark mode (switch while the app is open)
- [ ] Full screen (⌃⌘F) as a distraction-free mode
- [ ] Resize the window narrow and wide: the comment rail and text column
- [ ] Font choices and sizes look right; text renders as crisply as in Pages

**Accessibility**
- [ ] VoiceOver (⌘F5) reads the text and lets you move through it

## Findings and decisions so far

- **Line endings:** CodeMirror normalizes `\r\n` to `\n`. Decision: Stet's scene files are UTF-8 with LF by definition. Imported files are converted once, visibly, on import.
- **Paste:** CodeMirror pastes plain text, so italics from Word are lost. Converting HTML to Markdown on paste is a later feature.
- **Smart quotes:** `'` after a letter becomes an apostrophe (’) unless a single quote (‚) is open in the same paragraph. A leading elision (`’s ist`) comes out as ‚. That ambiguity is inherent; ⌘Z fixes it in one keystroke.
- **Bundle size:** 506 KB minified, mostly because `@codemirror/lang-markdown` pulls in the HTML/CSS/JS grammars. Can be trimmed later; irrelevant for a local app.
- **Comment rail:** rebuilt on every edit. That's fast enough at the measured sizes; it can be made incremental later.
- **Spike app:** a SwiftPM executable wrapped by a script. The real app moves to an Xcode project for the `.stet` document type, signing and Sparkle.

## Go / no-go

**Go** if the checklist shows no blockers in typing, text services or editing feel. Cosmetic issues are fine.
**No-go** if dead keys, dictation, spelling or undo misbehave in ways CodeMirror settings can't fix. Then fall back to a native TextKit 2 editor (STTextView).
