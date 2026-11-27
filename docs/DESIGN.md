# Zadur — Design

> *Keep writing!* · *Schreib weiter!*

The name is stylized from Turkish *yazadur*, roughly "keep writing". Until version 1.0 the app was called **Stet**; what still carries that name, and why, is listed in §2a.

Zadur is a macOS app for long-form creative writing that keeps a lossless, branchable history of the work using git, without the writer ever seeing git. In one sentence: **GitKraken for writers.**

Status: Phases 1–4 are built (core, experiments, sync, export, notes & feedback, backups, wiki, signing and timestamps) – Nov 2026. Sections marked **Open** still need a decision.

---

## 1. Principles

1. **The writer never sees git vocabulary.** No "commit", "branch", "merge", "HEAD", conflict markers, or hashes in the UI.
2. **Nothing is ever lost.** Every save is reconstructable; experiments are shelved, never deleted.
3. **The files on disk are exactly what the writer typed.** No editor or tool silently reformats text. Clean diffs depend on it.
4. **Plain, open formats.** A book is Markdown + YAML in a folder, readable with any text editor, verifiable with standard git tools.
5. **Distraction-free first, expert features on demand.** Commit notes, signing and remotes exist but never get in the way.

## 2. Platform and distribution

- **macOS only** for now. The iPad and other devices get a **web app later**. The editor component is chosen so it can be reused there (see §7).
- **Direct download + Homebrew tap.** No Mac App Store, no sandbox, so Zadur can call the system `git`, `ssh-keygen`, `gpg`, Pandoc and Typst.
- **Releases** (`scripts/release.sh`, details in `docs/RELEASING.md`): Release configuration, Apple silicon + Intel, hardened runtime, as `Zadur-<version>.dmg` (drag to Programme) and `.zip`. With the Developer ID and a notary profile the same script signs, notarizes and staples both and asks Gatekeeper; without them it signs ad hoc for testing. The version lives in `project.yml` (`MARKETING_VERSION`); the build number is the commit count. Next: Homebrew cask (template in RELEASING.md).
- **Updates via Sparkle** (2.x, Swift package): the app checks the newest GitHub release's `appcast.xml` once a day (Einstellungen ▸ Updates, Zadur ▸ Nach Updates suchen) and installs only when the user agrees. Updates are EdDSA-signed: public key `SUPublicEDKey` in `project.yml`, private key in the release Mac's keychain; `release.sh` writes the appcast. Self-tests never start the updater. Release builds signed ad hoc need `AdHocRelease.entitlements` (no library validation: without a team ID the hardened runtime would refuse Sparkle.framework); Developer ID builds don't.
- **Pandoc and Typst on demand** instead of in the app (they would add several hundred MB for both kinds of Mac): when an export needs them, the export sheet offers to download the official release for this Mac from the projects' GitHub pages (pinned versions, the archives checked against SHA-256 digests in `ExportTools.catalog`, the program checked with `--version`) into `~/Library/Application Support/Stet/Tools/<tool>-<version>/`. Zadur's own copies come first; Homebrew's or anything on the PATH still work. Zadur only causes the download of the projects' own releases and doesn't redistribute them.
- **Tests on GitHub** (`.github/workflows/tests.yml`): on every push to main and every pull request, the editor's type check and build, the ZadurCore tests, a build of the app and the editor self-test, on GitHub's macOS runners.
- The self-tests draw Zadur's windows themselves for their pictures (`SelfTest.render`): no screen capture, so no Screen Recording permission and nothing but Zadur's own windows.

### 2a. The former name

Zadur was called Stet until 1.0. Everything people see or work with is renamed (app, menus, icon, taglines, code, folders). These keep the old name on purpose, because something stored on people's Macs or in their books hangs on it:

| What | Why |
|---|---|
| Bundle identifier `io.github.booneynoobington.stet` (and `….thumbnail`, `….preview`) | Sparkle finds a renamed app only by its identifier (`SUInstaller.m`), so without it no installed copy would ever update. Settings, keychain access and file types hang on it too. An updated copy keeps its file name `Stet.app` until it's renamed in Finder (Sparkle installs in place). |
| Update feed `github.com/BooneyNoobington/stet/…` | The repository's address; GitHub forwards it if the repository is renamed (never reuse the old name for another one). |
| Settings keys (`StetDeviceID`, `StetSigning`, …), keychain comment "Stet", `Application Support/Stet/` (keys, tools), stored signing method `stetKey` | Stored on members' Macs; books name their key by path. |
| `stet.sshKey` in a book's git config, `.git/STET_ADOPTING`, signature namespace `stet-nachweis`, Stet 1.0's trailers, refs, notes and receipts | In books and in proofs already made (§4.5, §14). |
| Type `io.github.booneynoobington.stet.book` (`.stet`), `.stet.zip` backups, folder `Dokumente/Stet-Backups` if it exists | Books and backups from before; all still open. |

`FormerNameTests` guards them.

**Books ending in .stet** open as before, with a banner offering to rename them to `.crea` ("Umbenennen" / "So lassen", remembered per Mac): only the folder's name changes (`AppModel.renameToCrea`), never overwriting another book.

## 3. Vocabulary

| Writer sees | Under the hood |
|---|---|
| Save / version | commit |
| Note on a version | `git notes` |
| Snapshot (automatic) | commit on a hidden per-device ref |
| Experiment | branch `experiments/<slug>` |
| Adopt experiment | merge (`--no-ff`) |
| Adopt some scenes | normal commit with `Crea-Adopted-From:` trailer |
| Shelve experiment | rename branch to `shelved/<slug>` |
| Milestone | annotated tag `milestone/<slug>` |
| Server / sync | remote `origin` (e.g. Gitea) |

## 4. The `.crea` package

A `.crea` book is a **directory package**: Zadur declares the `.crea` type as conforming to `com.apple.package`, so Finder shows it as a single file (the same mechanism `.app` uses). On machines without Zadur, and to sync tools, it is an ordinary folder.

```
Der Leuchtturm.crea/
├── manuscript.yaml        # book metadata + structure (order of parts/chapters/scenes)
├── scenes/
│   ├── 7f3a9c.md          # YAML front matter + prose
│   └── b21e04.md
├── wiki/
│   └── mara-kessler.md
├── feedback/
│   ├── 2026-11-19-gisela.md
│   └── attachments/
├── assets/
│   └── cover.jpg
├── .gitignore             # contains: .local/
├── .local/                # per-device, never versioned: cursor, open scene, display prefs
└── .git/
```

**Finder integration.**
- **Bundle bit.** Zadur sets it on every book it creates, imports or opens, so the book shows as a single file even on Macs without Zadur. Finder copies, AirDrop and Time Machine keep it; git and sync services don't.
- **Thumbnail extension.** Finder shows the book's cover as its icon, or a drawn title page (title and author) when there is no cover.
- **Cover** (Inspector ▸ Details ▸ Buch ▸ Titelbild: choose, drop an image, change, remove): stored as `assets/cover.jpg` or `assets/cover.png` and named in the manifest (`Book.setCover`). JPEG and PNG stay as they are; other formats (HEIC from a phone, TIFF, WebP) become JPEG, upright, and anything over 4000 pixels on the long side is scaled down. It is the PDF book's first page, the ePUB's cover and the Finder icon; the package's date is touched so Finder redraws the icon.
- **Preview extension.** The space bar shows the title, author, contents with word counts and the opening of the book.
- **Icons.** The app icon (z, period, oxblood insertion cursor) comes from `Zadur-Icon-Kit/` in the repository: the project uses `ZadurIcons.xcassets` from there directly. The document icon and the title page take up its motif and are drawn in code (`Zadur/Shared/ZadurArtwork.swift`; `scripts/make-icons.sh` renders `ZadurBook.icns`).

### 4.1 `manuscript.yaml`

```yaml
format: 1
title: Der Leuchtturm
authors: [Jane Doe]
language: de
quotes: guillemets        # guillemets (»« ›‹), de („“ ‚‘), en (“” ‘’); missing: by language (see §7)
year: 2026                # defaults to the current year
cover: assets/cover.jpg
export:
  sceneBreak: "* * *"
structure:                # parts are optional; chapters always have titles
  - chapter: Ankunft
    id: c4e1d0
    facts: { Datum: 1953-03-14 }
    scenes: [7f3a9c, b21e04]
  - part: Zweiter Teil
    id: p09ab2
    chapters:
      - chapter: Die Flut
        id: c77f10
        scenes: [d3c9e8]
```

- **Scene files are named by a stable random ID**, never by position or title. Reordering only touches `manuscript.yaml`; renaming a scene touches only its front matter. Git keeps an unbroken history per file.
- A chapter with one scene shows no scene level in the UI. The scene level appears once the chapter is split.
- Settings changes do not create commits; they are included in the next save.

### 4.2 Scene files

```markdown
---
title: Die Ankunft          # optional; the navigator shows the opening words otherwise
status: draft               # draft | revised | done
synopsis: Mara erreicht die Insel bei Nacht.
facts:
  Datum: 1953-03-14
  Uhrzeit: "21:40"
  Ort: "[[Hafen]]"          # links to a wiki entry
---
Der Wind kam von Westen, als Mara …
```

The editor only ever sees the prose. Zadur strips the front matter before handing the text to the editor and puts it back on save. Front matter is edited in an inspector.

All text files are **UTF-8 with LF line endings**. CodeMirror normalizes line breaks to LF anyway, so imported files with CRLF are converted once, visibly, on import, never silently on save.

### 4.3 Versioned vs. local settings

| Versioned (in the book) | Local (in `.local/` or app preferences) |
|---|---|
| title, author, year, language | writing-pane font, size, line height, theme |
| structure, quick-fact field definitions | window layout, open scene, cursor position |
| export styling (PDF font, trim size, scene-break glyph) | comments shown/hidden, focus mode |
| remote URL, signers' public SSH keys (`signers/`) | signing setup and timestamp services (app preferences), pending stamps (`.local/zadur-stamps.json`) |

### 4.4 Where books live (sync services)

A sync service such as Nextcloud, Dropbox, OneDrive or iCloud cannot be stopped from touching a folder. A synced `.git` can break when two devices write to it. Zadur therefore:

1. **Detects** synced locations when a book is created or opened: `~/Library/CloudStorage/*`, `~/Library/Mobile Documents`, `~/Documents` and `~/Desktop` when "Desktop & Documents in iCloud" is on, and a parent folder containing Nextcloud's `.sync_*.db` or Syncthing's `.stfolder`. It then shows a calm banner: *"This book is in a Nextcloud folder. Zadur keeps your history itself and syncs through your server. Folder syncing can damage it."* with buttons **Move to my books folder** and **Keep here**.
2. Asks once, on first launch, where books should live (default suggestion `~/Books`, never `~/Documents`).
3. Runs a **health check** on open: looks for conflicted-copy files (`… (conflicted copy …)`, `… 2.md`) and runs `git fsck --connectivity-only`. If the book is damaged and a remote exists, it offers **Restore from server** and carries the unsaved working text over.

Rejected: excluding only `.git` from sync. The text would sync and the history wouldn't, so each machine would see the other's edits as unexplained changes.

### 4.5 The Crea format

The package is specified as an open format of its own, **Crea** (spec, schemas, an example and a checker in the separate `crea-format` repository), so other programs can read and write books and nothing ties them to Zadur. Zadur follows it, with names from before the spec still read:

- **Names.** Trailers `Crea-…`, snapshots `refs/crea/snapshots/<device>`, stamps `refs/notes/crea-stamps` with `crea-stamp` lines, receipts `Crea-Receipt 1`. Stet 1.0's `Stet-…`, `refs/stet/snapshots/…` (moved on opening, `Book.adoptCreaNames`), `refs/notes/stet-stamps` and `Stet-Beleg 1` are still read. App-specific things keep Zadur's name: `Zadur-Imported-From:`, the server probe `refs/zadur/probe/main`, `.local/zadur-*.json`.
- **Extension.** Books are `.crea` (type `io.github.crea-format.book`, exported). Books from before the new name end in `.stet` (`io.github.booneynoobington.stet.book`) and open the same way (§2a). Backups are `.crea.zip`; `.stet.zip` ones are listed, kept and restored together with them.
- **A folder, not one file** (decided 26 Nov 2026). A book as one ZIP, unpacked into a working copy and packed back on saving, was built and tried (branch `crea-archive-test`, its DESIGN §4.6). It works, but it adds moving parts (working copies, packing, conflict copies) and needs more for things a folder has for free (the cover in Finder); the safety against sync services is had otherwise (the warning in §4.4, git noticing damage, a git server). And a folder stays a valid book for anyone who stops using Zadur.
- **Without history.** A book without `.git` (e.g. from another program) gets one on opening (`startHistoryIfNeeded`: `.gitignore`, `git init`, the current state as the first version, a notice). Book git commands run with `GIT_DIR`/`GIT_WORK_TREE` set to the book, so git never uses the repository of a folder around the book, nor a book folder that looks like a bare repository.
- **Other programs' keys** in `manuscript.yaml`, scene, wiki and feedback front matter are kept when Zadur saves.

## 5. Structure and navigation

- **Navigator**: a tree in the style of Typora's sidebar. No file names or icons. Drag and drop to reorder, a quiet word count, and a status dot (draft / revised / done). Every chapter is a heading with its scenes below, also a chapter with a single scene (it used to be one row then, so a new chapter looked like a scene). **＋** below the tree: Neue Szene, Neues Kapitel.
- **Quick facts**: fields defined per book (`factFields` in `manuscript.yaml`, default *Datum, Uhrzeit, Ort, Perspektive*), edited in Inspector ▸ Details per scene, plus extra fields a single scene needs. They are stored in the scene's front matter (empty values aren't written) and shown in the navigator's tooltip. A value can point to a wiki entry (`[[Hafen]]`, or simply a known name); the inspector then offers to open it. Chapter and part facts come later.
- **Facts for chapters and parts** (Inspector ▸ Details, under the chapter and its part; `facts:` in `manuscript.yaml`, merged like titles): a scene inherits what it doesn't set itself (scene over chapter over part). An empty scene field shows the inherited value as its placeholder.
- **Zeitleiste** (Buch ▸ Zeitleiste, ⌥⌘L): every scene's story time from its "Datum" and "Uhrzeit" (own or inherited), read as written: "14.7.1998", "1998-07-14", "14. Juli 1998", "Juli 1998", "Sommer 1978", "3/1953", "1978"; times "23:30", "7 Uhr" (`StoryTime`). A chart plots story time (as a decimal year, later is higher) against reading order, so a flashback is a drop; scenes earlier than the latest one read before them are marked as flashbacks. Below, the scenes in story order (or reading order), undated ones listed apart; a click opens the scene.

## 6. Saving and history

**Grafischer Verlauf** (Fassung ▸ Verlauf zeigen, ⌥⌘Y): every version of every Fassung (experiments too, shelved ones included), newest at the top, in lanes like a git graph (`HistoryLayout`): the main version always in the first lane, an experiment branching off it and, once adopted, flowing back in (adoptions are hollow dots). Branch tips carry their names, milestones and exports their flags; dates, word changes and notes under each version.

| Action | What happens |
|---|---|
| Typing | Autosave writes the files to disk (debounced, ~2 s). No commit. |
| **Save (⌘S)** | Commit straight away with a generated message (`Edited "Ankunft", "Die Flut" · +412 words`). A small "Add a note" field appears and fades out on its own. Nothing blocks. |
| Note added later | `git notes add` on that commit. Never rewrites history. |
| App goes to background / idle 10 min / quit without saving | **Safety-net snapshot**: commit built with a temporary index (`GIT_INDEX_FILE` + `git write-tree` + `git commit-tree`) on `refs/crea/snapshots/<device-id>` (Stet 1.0: `refs/stet/snapshots/…`, moved when a book opens). The real index and visible history are untouched. |

**Commit trailers** keep later statistics cheap. Nothing has to replay the diffs.

```
Edited "Ankunft" · +412 words

Crea-Words: 85231
Crea-Words-Delta: +412
Crea-Active-Minutes: 47
Crea-Scenes: 7f3a9c,b21e04
```

The names are the Crea format's (§4.5); Stet 1.0 wrote them with `Stet-`, and both are read (`Git.Commit.trailers` drops the prefix: `trailers["Words"]`). `Crea-Active-Minutes` comes from the editor (time with keystrokes, minus idle gaps). Git timestamps only record *when* a save happened.

## 6a. Writing statistics

**Buch ▸ Statistik** (⌥⌘I), also a click on „Heute: +523“ in the status bar:
- Tiles: today (net words, active minutes, progress toward the daily goal), this week (words, writing days, time), streak (days in a row with words added or ≥ 5 active minutes; an empty today doesn't break it), the book (words, progress toward its goal).
- Words per day for 30 days, per week for 12 weeks, or per month for the whole history (net: written minus deleted; days with more deleted than written show grey below the line), with the daily goal as a line, a hover callout and a table view. "Das Buch wächst": the book's words along the open version's history, with the book's goal.
- Chapters: words per chapter and how many scenes are done.
- Goals: a daily goal per Mac (preferences) and a goal for the book (`wordGoal:` in `manuscript.yaml`, travels with the book).

Sources: the trailers of every version (`Crea-Words`, `Crea-Words-Delta`, `Crea-Active-Minutes`, or Stet 1.0's `Stet-…`). Days count versions on all branches (experiments included; merges don't count twice); the growth line follows the open version (first-parent), ordered by date, ties in history order. Versions from before Zadur have no trailers: their words are counted once from the scenes folder of that time (`scenes/`, or the folder with the most Markdown files, not the top folder with notes and read-mes) and remembered in `.local/word-counts.json`. Today also includes what is written but not saved yet.

## 7. Editor

**Engine: CodeMirror 6 in a `WKWebView`** for the writing pane. Everything else (navigator, history, inspector, settings, dialogs) is native SwiftUI.

Why:
- CodeMirror edits the source text and only changes how it is *drawn* (decorations), so the file stays byte-for-byte what was typed. WYSIWYG engines (ProseMirror, Milkdown, Tiptap) parse and re-serialize Markdown, which "normalizes" it and pollutes diffs.
- Input methods, undo, long documents and accessibility are already solved (Obsidian, Zettlr and MarkEdit are built on it).
- The future web app reuses the same editor.

Features:
- **Live preview**: Markdown symbols (`*`, `**`, `#`, `***`, `>`) are hidden unless the cursor touches them; quotes are indented with a quiet rule on the left.
- **Formatting** (since 1.0): only what a novel needs, all of it plain Markdown. Kursiv (`*…*`, ⌘I), Fett (`**…**`, ⌘B), Zitat (`> `, for a letter, an epigraph, a sign …), Kommentar (⌥⌘M) and TODO (⌥⌘T). Headings come from chapters; underline, strikethrough, lists, fonts and colours are left out on purpose (the export sets the type).
  - Three places, the same commands: a group in the toolbar above the text (Kursiv, Fett, Zitat, Kommentar; the first three light up when the cursor is in such text, from a `format` message the editor sends when that changes), the **Format** menu (with the shortcuts, each once in the menu bar; typed in another field, e.g. the inspector, they leave the text alone), and the right-click menu (for the selection if the click is on it, else the word under the mouse). WebKit's own "Schrift" submenu (Fett, Kursiv, Unterstrichen …) is taken out of the right-click menu: it would format the editor's HTML, not the Markdown.
  - Italic and bold behave like a word processor's: inside such text (or with all of it selected) the marks go; a selection gets marks per paragraph and without the spaces at its ends, merging with emphasis of the same kind it cuts into or contains; the cursor inside a word takes the word; elsewhere a pair of marks to type into.
  - Zitat toggles `> ` on the selected paragraphs. Blank lines inside, and those between it and a quote right above or below, become `>`, so a letter over several paragraphs is one quote; taking a paragraph out turns its neighbouring `>` lines into blank ones. Enter in a quote continues it (CodeMirror's Markdown keymap), so the usual double Enter starts a new paragraph inside it (`>` on the line between); one more Enter on that empty quote line ends the quote.
  - Exports: Typst sets quotes indented on both sides (the book a little smaller, the manuscript with a smaller inner indent and air around), ePUB as an indented `blockquote`, Word and LibreOffice with their quote styles ("Block Text", "Quotations").
- **Comments and TODOs** (§9) render as numbered markers with bubbles in a margin rail and can be shown or hidden.
- **Wiki terms** (§10) are underlined via alias matching.
- **Typography**: smart quotes in the book's style, apostrophe `’`, ` -- ` → ` – `, `...` → `…`. The style is the book's (`quotes:` in `manuscript.yaml`, chosen in the inspector under Buch): `»« ›‹` (the default for German books, as in most German novels), `„“ ‚‘` or `“” ‘’` (the default for English ones). Opening or closing depends on the character before, emphasis stars aside (`*"Ja"*`, `"*gut*"`).
  - Typing only changes what's typed, so text that came in by import or paste keeps its straight quotes. **Buch ▸ Anführungszeichen angleichen …** turns every quotation mark in the book into the book's style (straight ones and those of another style), after a snapshot; in the open scene ⌘Z undoes it. It asks first, with the count; changing the style in the inspector asks the same ("Nur beim Tippen" keeps the text).
  - The rules (`Typography.quotes` in ZadurCore, shared with exports): a single mark is an apostrophe inside a word (`geht's`), after a word when no single quote is open (`Andreas'`), and at the start of a word when nothing closes it later in the paragraph (`'n Abend`). Only quotation marks change, one character for another, so converting twice changes nothing.
- **Focus mode**: dims everything except the current paragraph, with typewriter scrolling.
- **Spelling** (Darstellung ▸ Rechtschreibfehler markieren, on by default): Zadur checks the open scene itself with macOS's dictionaries (`NSSpellChecker`, the book's language) right after loading it and a moment after typing stops, and sends the ranges to the editor, which draws red wavy lines (they move with the text; a word being typed loses its line until the next check). WebKit's own checking is off: it only looks at the paragraph being typed in, so existing mistakes stayed invisible. No automatic correction: it would silently "fix" names, dialect and invented words. Comments (`{>>…<<}`) are not checked.
  - Right as written: the wiki's names (also their parts, with genitive s, and with -ens for names on s, ß, x, z) and the book's word list (`words:` in `manuscript.yaml`, merged like a list so two Macs' additions add up). Both are the "ignored words" of the book's own spell document, so the system dictionary stays clean.
  - Right-click on a marked word: up to five suggestions (bold), „für dieses Buch erlauben“, „ignorieren“ (until the book is closed); the wiki items follow.
  - **Apostrophe hint** (German books only): a wiki name or book word with an English-style possessive gets a quieter blue dotted line and a suggestion: „Gabriela's“ → „Gabrielas“ (no apostrophe in the German genitive), „Andreas's“ → „Andreas’“ (names on s, ß, x, z take the apostrophe only). „Andrea's“ is left alone when there is also an Andreas: making the name clear is the accepted exception. „so lassen“ (or allowing the word for the book) keeps a form on purpose, e.g. a shop's name. The hints also appear in the spelling window.
  - **Rechtschreibung prüfen …** (⇧⌘;) opens a window with every unknown word of the book, most frequent first: suggestions with „Überall ersetzen“ (the open scene changes in the editor, undoable; other scenes on disk, the old text stays in the history), allow for this book, ignore, add to the macOS dictionary, and every occurrence with context (a click opens the scene and selects the word).
- **Find and replace** (Bearbeiten ▸ Suchen …, ⌘F; ⇧⌘F with the replace row): a native bar above the text searches the **whole book** in reading order (placed scenes, then unplaced ones), plain text only (no patterns): case doesn't matter, accents do, composed and decomposed umlauts are the same letter (`TextSearch`). The open scene is searched in the editor's text, the others on disk; the scene's matches are highlighted (the current one stronger) and follow the text while typing. Return or ⌘G goes to the next match and opens the next scene that has one (round the end), ⇧⌘G back; Esc (in the bar or in the text) closes it. A short selection becomes the search. With **Ersetzen** ticked only exact matches count (case too): „Ersetzen“ changes the current match in the editor (undoable) and moves on after the new text; „Alle ersetzen …“ asks first, saves a snapshot, changes the open scene in the editor (one undoable edit) and the other scenes on disk. Not during an adoption.
- **Apple's writing tools** (Korrekturlesen, Umschreiben … with Apple Intelligence) come from macOS, not from Zadur. They are limited to their own panel (`writingToolsBehavior = .limited` for the editor's web view, `.writingToolsBehavior(.limited)` for the book and wiki windows): rewriting in place could drop text the editor hides (Markdown symbols, comments); taking a result over from the panel is an ordinary, undoable edit.
- **Theming** (local setting): font family, size, line height, column width, light/dark from the system.

**Bridge** (JSON messages):
- Swift → JS: `load(text)`, `getText()`, `setSettings({...})`, `getSettings()`, `stats()`, `focus()`
- JS → Swift: `ready`, `changed` (no text; Swift tracks the dirty state), `stats {words, characters}`, `activity` (for active minutes)

Swift pulls the text with `getText()` when saving, instead of receiving it on every keystroke.

The prototype validated this choice (see `docs/editor-spike.md`): automated checks pass. The hands-on checklist is the final word.

## 8. Experiments, merging, milestones

- **Start experiment** → `git switch --create experiments/<slug>`. The name is required ("Kapitel 3 aus Maras Sicht"); the slug keeps umlauts and case (`Kapitel-3-aus-Maras-Sicht`), and the full name is stored as the branch description. Unsaved changes either move into the experiment or are first saved as a version where they are; the writer chooses.
- **Switching** saves pending changes as a version first, so there is never an "unsaved changes" dialog or a stash. Branches without `manuscript.yaml` (from before Zadur) can't be opened, but they can be adopted.
- A tinted banner and the toolbar's version menu always show which version is open.
- **Adopt experiment** → `git merge --no-ff --no-commit experiments/<slug>` into the main version:
  - **Structure.** `manuscript.yaml` is merged by Zadur whenever both sides changed it (`Manifest.merge`). Each side's additions, removals, moves and renames are kept. A new scene follows its predecessor from the experiment. Removing beats moving. If both sides changed the same field, the main version wins. Without a common ancestor (two imported branches), only what both share counts as "before", so nothing is lost.
  - **Scenes.** A scene's front matter and prose are merged separately. Otherwise a title change on one side and an edit of the opening paragraph on the other would collide, because the title block sits directly above it. For scenes from before an import, the common ancestor is found by the scene's title (`Szenen/<Titel>.md`).
  - **Conflicts.** What is left is shown per passage: *Hauptfassung* | *Experiment*, with **Diese Fassung / Beide behalten / Selbst formulieren**. A scene deleted on one side and edited on the other offers **Behalten / Löschen**. A kept scene goes back where the experiment has it. Files that can't be merged as text offer a choice of side. Conflict markers are never shown.
  - **Finishing** writes one version with both histories as parents (`Crea-Adopted-From: <branch> <sha>`), after removing structure entries whose files are gone. **Cancelling** (`git merge --abort`) leaves everything as before.
  - While an adoption is open, nothing writes to the working tree (autosave, snapshots and versions are blocked). After a crash or quit, a banner offers to continue or cancel.
- **Adopt some scenes** → copies the chosen scene files from the experiment into the main version; new scenes are placed as in the experiment. One normal version with `Crea-Adopted-From:`.
- **Shelve** → rename to `shelved/<slug>`. Shelved experiments can be brought back and are never deleted. Adopted experiments stay listed as "übernommen" until shelved.
- **Milestones** → annotated tags `milestone/<slug>` on the current version (pending changes are saved first). The tag message holds the name and an optional note. Milestones show as flags in a scene's history.
- **Import**: other branches of an imported repository that are fully merged are shelved. Branches with their own work become experiments, converted to the Zadur layout with the same scene and chapter IDs as the main version, so they open and adopt cleanly.
- **Diffs** are shown word-level within paragraphs and rendered by Zadur, not git's line diff.

## 9. Comments, TODOs, feedback

**Inline, CriticMarkup syntax** (no sidecars: sidecar comments lose their anchor when the text changes and drift apart from it across branches):

```
She {==never looked back==}{>>too cliché?<<} at the harbour.
{>>TODO: check tide times for 1953<<}
{>>@Gisela: Hier wurde ich ungeduldig.<<}
```

| Form | Meaning |
|---|---|
| `{>>text<<}` | comment at a point |
| `{==range==}{>>text<<}` | comment on a range |
| `{>>TODO: …<<}` | TODO (collected in a TODO list) |
| `{>>@Name: …<<}` | comment from someone else (imported feedback) |
| `{++ins++}`, `{--del--}` | suggested edits (reserved, later) |

Comments are excluded from word counts and removed on export (or turned into Word comments for `.docx` review copies). The `{~~old~>new~~}` substitution syntax is avoided because `~~` collides with GFM strikethrough; Zadur uses CommonMark without that extension.

**Notes overview** (Inspector ▸ Notizen): every comment and TODO in the book, grouped by scene in reading order, filterable (Alle / TODOs / Kommentare). A click jumps to the passage in the editor. **Erledigt** removes a TODO or comment from the text as one undoable edit; a highlighted passage stays as plain text, and the history keeps the note. Positions are UTF-16 offsets, as CodeMirror counts them.

**Feedback inbox** (Inspector ▸ Feedback, folder `feedback/`, versioned and synced). Each entry is a Markdown file with front matter:
- `from`, `received` (day), `refersTo` (an export mark or milestone; the newest export is preselected), `status` (open/done)
- `attachments`: files copied to `feedback/attachments/`, e.g. a photo of a marked-up printout
- `wordComments`: author, passage, text, placed

The body holds the feedback text. In the entry:
- Text marked in the feedback can be inserted as a comment `{>>@Name: …<<}` at the editor's cursor, or around its selection.
- **Diese Szene mit jener Fassung vergleichen** shows what changed in the open scene since the version that was read (`Book.version(ofScene:at:)` plus the comparison view).
- Marking an entry as done moves it to "Erledigt"; deleting removes it and its attachments (they stay in the history).
- A version that includes feedback says "Feedback" in its message.

**Word comments** ("Word-Datei …"):
- Pandoc reads a returned `.docx` with `--track-changes=all` through a small Lua writer (`Resources/comments.lua`). It yields each comment's author, text and the commented passage; Pandoc names the id `comment-id`.
- The passage is found in today's text by `PassageFinder`. It ignores the differences export and typing make: straight vs. typographic quotes and apostrophes, dashes, `...` vs. `…`, emphasis marks, CriticMarkup and whitespace. The match maps back to exact UTF-16 offsets.
- **An die Stelle** wraps that passage as `{==…==}{>>@Name: …<<}`; **Alle an ihre Stelle** does this for every comment. Where a passage no longer exists, **An den Cursor** inserts the comment with the quoted passage.
- The `.docx` itself is kept as an attachment of the entry.

## 10. Wiki

Git has no wiki. Forge wikis (Gitea, GitHub) are a separate repository, and issues live in the forge's database, so neither is used. Instead, the `wiki/` folder sits in the same repository, so the wiki is versioned, branched with experiments and synced like the manuscript.

```markdown
---
title: "Mara Kessler"
kind: character             # character | place | term | note
aliases: ["Mara", "die Kapitänin"]
facts:
  "Geboren": "1921"
  "Herkunft": "[[Hamburg]]"  # links to another entry
---
Free-form notes …
```

- **No markup in the prose.** The editor underlines every name (title and aliases) with a dotted line. Matching is whole words with Unicode letters, case-sensitive, longest name first. Genitives count: `-s` ("Maras" → Mara), English-style `'s`/`’s`, the apostrophe of names on s, ß, x, z ("Andreas’" → Andreas, the apostrophe stays outside), and for those names the old `-ens` ("Hansens", "Fritzens"). "Andreasstraße" or "Hansestadt" don't match.
  - Ambiguity: "Andreas" can be the name Andreas or Andrea's genitive. With entries for both, the longer, exact name wins (also in "Kommt vor in", which matches all names at once). Without an entry for Andreas, an entry can list **Nicht gemeint** words (`notMeant:` in its front matter, e.g. Andrea: Andreas): they are neither underlined nor counted for it.
  - Explicit links in the prose (`[[Andrea]]`, as in Obsidian) were considered and left out: they would clutter the manuscript, have to be removed from every export, and replace the automatic recognition; "Nicht gemeint" settles the rare ambiguous cases without markup.
- **Hovering a name shows a card** with kind, quick facts (`[[…]]` shown as plain text) and the entry's first line. ⌘-click, or the card's link, opens the entry. Underlining can be switched off (Darstellung ▸ Wiki-Namen unterstreichen).
- **Wiki window** (⌥⌘W or the toolbar): entries grouped by kind, with search. **＋** below the list (like the navigator's) asks for the kind (Figur, Ort, Begriff, Notiz), then the name; the entry's file is named after it. A name the wiki already knows (title or other name, ignoring case) opens that entry instead. For each entry: name, kind, other names, facts, notes, and **Kommt vor in** (the scenes with a count; a click opens the scene at the first occurrence). Edits are saved after a short pause.
- **Wiki-Eintrag aus Auswahl (⌃⌘W)**: the selected name gets an entry, or its existing entry opens.
- **Right-click in the text**: on the selection, or on the word under the mouse, the native menu (spelling, Look Up …) gets wiki items on top: „Name“ im Wiki öffnen if an entry exists (or the name is underlined), otherwise „Name“ ins Wiki aufnehmen with a submenu for the kind (Figur, Ort, Begriff, Notiz).
- Plain Markdown files in `wiki/` (e.g. imported notes) appear as notes, titled after the file name.
- Versions that change the wiki say "Wiki".
- **Taking the wiki along** (wiki window toolbar or Buch menu), e.g. into a sequel: **Wiki exportieren …** writes a ZIP with a folder `Wiki/`, one Markdown file per entry; **Wiki aus anderem Buch übernehmen …** reads another `.crea` book, such a ZIP, or a folder of Markdown files. Entries this book already has (by any of their names, ignoring case) stay as they are; the others come with aliases, facts and notes. File names are compared ignoring case, as the Mac's file system does.
- Later: optional export as a readable glossary appendix.

## 11. Export

**Ablage ▸ Exportieren … (⌘E)** or the toolbar button. If a format needs Pandoc or Typst and neither Zadur's own copy nor Homebrew's is there, the sheet offers to load them (§2). Formats:

| Format | How | Look |
|---|---|---|
| PDF – Manuskript | Pandoc → Typst (`Resources/manuscript.typ`) | A4, Times 12 pt, generous line spacing, first-line indent; title page with name and word count; header "Name · Titel · Seite" and the version line in the footer of **every** page |
| PDF – Buch | Pandoc → Typst (`Resources/book.typ`) | 13.5 × 21 cm, Iowan Old Style 10.5 pt, justified with hyphenation; running heads (author on even pages, chapter on odd pages, none on chapter openings); chapters start on right-hand pages; cover page, title page and imprint with the version |
| ePUB | Pandoc (epub3) | TOC, cover, the book's own CSS followed by Zadur's (`Resources/epub.css`), colophon with the version |
| Word / ODT | Pandoc with `Resources/reference.docx` | Times 12 pt, 1.5 line spacing, centred "Szenenwechsel" style; version line under the title. Optionally comments/TODOs as real Word comments (author from `@Name:`) |
| Markdown | Zadur itself | the combined Markdown |

Pipeline:

1. **Pending changes are saved as a version first**, so the stamp names exactly the text in the file.
2. **Zadur builds a combined Markdown for the target** (`CombinedMarkdown`):
   - YAML metadata, always quoted so "1.530" or "1984" stay text
   - parts and chapters as headings
   - scene breaks per target: a Typst `#scenebreak()`, `<p class="scene-break">⁂</p>`, the Word style "Szenenwechsel", or `* * *`
   - comments removed, or turned into Pandoc comment spans for docx/odt
   - optional scene titles
3. **Typography for the chosen quote style** (the export sheet starts with the book's; »« / „“ / “” / unverändert): every quotation mark, straight or in another style, → that style by context, apostrophe ’, ` -- ` → ` – `, `...` → `…`. Same rules as typing in the editor and "Anführungszeichen angleichen"; CriticMarkup and `***` lines are left alone. The writer's text isn't changed, only the export.
4. **Pandoc runs with `--from=markdown-smart`** and a Lua filter (`Resources/zadur.lua`): links without a target become their text, and images whose file is missing become their caption. A real manuscript's early version had `[<!-- … -->]()`, which Typst refuses.
5. **Every export is tagged** `export/<date>-<format>` (annotated, with the file name). The history shows these marks; the writer's own milestones take precedence.

Tools: Zadur's own copies of Pandoc and Typst (loaded on demand, see §2), otherwise Homebrew's (`/opt/homebrew/bin`, `/usr/local/bin`) or anything on the `PATH`. If one is missing, the sheet offers to load it.

## 12. Backup

A backup is **one ZIP file** of the whole package: history, experiments, milestones, export marks, feedback with attachments, and also unsaved text on disk. Per-device state (`.local/`) is left out. Name: `<Titel> – Backup 2026-11-20 1430.crea.zip`; unzipped it is `<Titel>.crea`, ready to open.

- **Written safely**: `/usr/bin/zip` into a temporary folder, checked with `unzip -t`, then moved into the target in one step. A half-written backup never appears there, which matters for synced folders.
- **A single file is fine for sync services.** Unlike a live book, a backup may sit in Nextcloud, iCloud or Dropbox, or on an external drive.
- **Backup sichern … (⌥⌘B)** writes a backup to a file of the writer's choice.
- **Backup wiederherstellen …** unpacks a backup into a chosen folder and opens it. A book of the same name stays untouched (the restored one is called "… (wiederhergestellt)"); the archive is checked first, for damage and for anything that would land outside the book or point elsewhere (§15).
- **Automatic backups** (Inspector ▸ Buch ▸ Backups, or Ablage ▸ Backups einstellen …) are per book and per Mac (`.local/zadur-state.json`). They run at most once every 20 hours, on opening or after ⌘S, into a chosen folder (default `~/Documents/Zadur-Backups`), and keep the newest N of this book (other books' backups in the same folder are not touched). If the folder is unavailable, e.g. a drive is unplugged, the inspector shows a quiet hint instead of an error dialog.
- The server and Time Machine are further backups.

## 12a. Import

**Import folder** turns a folder of Markdown scenes into a book, leaving the source untouched:

- A `book.yaml` (chapters → scene names, title, authors, language, cover, CSS) defines the structure. Without one, every `.md` file becomes a scene of one chapter. Scenes not listed go to a chapter "Nicht zugeordnet".
- If the folder is a git repository, the book is a **clone**: the whole history is kept, and other branches (local and remote-tracking) become experiments. The conversion is one ordinary commit, and git's rename tracking lets every scene's history reach back before the import. The original remote is removed, so nothing is pushed to the old repository by accident.
- Scene bodies stay byte-identical; titles go into front matter. Cover and CSS go to `assets/`, other Markdown files to `wiki/`, unknown files to `imported/`. Tooling that Zadur replaces (`book.yaml`, build scripts, `README.md`) is removed in the conversion commit and stays in the history.

## 13. Sync and remotes

If a book has a remote (`origin`), **the remote is the source of truth.**

- **Connecting** (Inspector ▸ Buch ▸ Server, or Buch ▸ Server …) first checks the server (`ls-remote` plus a fetch into a temporary ref). An **empty** repository gets the whole book. A server with **this book's history** is continued. This includes a repository used before Zadur: Zadur's main version is a fast-forward of it, so the server afterwards shows the Zadur layout, and the old files stay in its history; the sheet says so. A server with **another project** is refused.
- **On open**: full sync. Zadur fetches, fast-forwards what the server has (main version and experiments), and sends what's new here. Pending changes are saved as a version first.
- **After ⌘S** (and after starting/shelving experiments, milestones, adoptions): sync **without integrating**. Zadur only sends, and reports when the server has new versions. Nothing in the working tree changes while the writer may be typing. A blue banner offers **Holen** (fetch, with the text written to disk first).
- **Both Macs wrote**: the banner offers **Zusammenführen …**. It uses the adoption machinery (`mergeWithServer` = merge of `origin/main`), with the same decision window labelled *Dieser Mac* | *Server*. The result is a merge version "Mit dem Server zusammengeführt" (`Crea-Merged-From:`).
- **What is sent**: all branches that are ahead (`main`, `experiments/*`, `shelved/*`), milestone tags, notes (`refs/notes/commits`, merged with `cat_sort_uniq` on fetch), and this Mac's snapshot ref (the only forced push; one writer per ref). Branches that are behind or diverged are never sent; a diverged experiment is reported and left alone.
- **Shelving travels**: shelving deletes the experiment's old name on the server. A Mac that still has it active, at the same version, renames it to `shelved/…` as well. An experiment shelved here is not brought back by its old name.
- **Fetching never deletes local data**: `--prune` applies only to remote-tracking branches. (With a tags refspec it would delete milestones the server doesn't have yet; a test guards this.)
- **Addresses with a port**: the short form `user@host:path` can't carry a port; `git@host:2222/name/buch.git` would be read as path `2222/…`. The server sheet recognises this and offers `ssh://git@host:2222/name/buch.git` (or the short form without port if `~/.ssh/config` already sets it).
- **Own key per book** (optional): for SSH keys that ask for Touch ID or a passphrase on every use (e.g. Secretive), Zadur can create a passphrase-less ed25519 key for one book. It lives in `~/Library/Application Support/Stet/Keys` (folder 700, key 600), outside the book, so it's never synced. It is used only for that book via the book's local `core.sshCommand` (`-i <key> -o IdentitiesOnly=yes -o IdentityAgent=none`). Before creating it, the sheet explains the risks: an unencrypted key readable by any program of the user, and included in Time Machine backups. It recommends adding the key in Gitea as a **deploy key of that one repository** (with write access), not to the account. Removing it deletes it from the Mac; the sheet reminds the writer to remove the deploy key too. "Buch vom Server holen" can create such a key before cloning.
- **Network**: SSH runs with `BatchMode=yes` and `ConnectTimeout=15`, so it never waits for a password or host-key question. git/ssh errors are translated: unknown host, no connection, unknown host key ("connect once in Terminal"), permission denied, no repository. HTTPS uses the system credential helper.
- **Second Mac**: "Buch vom Server holen …" clones the book; experiments come along as local branches. Experiment names travel as their slug (`Kapitel-3-aus-Maras-Sicht` → "Kapitel 3 aus Maras Sicht"); real hyphens in names become spaces on the other Mac.
- **Status bar**: "Server: abgeglichen 14:02 / wird abgeglichen / neue Versionen verfügbar / zusammenführen nötig / nicht erreichbar". Click to sync now (⌃⌘S).

- **Which server**: anything that speaks git. Gitea/Forgejo or GitHub (web page, accounts, HTTPS), or simply git and SSH on a Raspberry Pi or NAS: one bare repository per book. On such a plain server there's no web page to create the repository, so the server sheet offers **Auf dem Server anlegen** when the address is SSH and nothing is there yet (`Book.createRepository`: `git init --bare --initial-branch=main` over SSH).
- **Logging in with a user name and password** (SSH or HTTPS; for Gitea/GitHub also an access token), as an alternative to SSH keys. The password lives in the keychain as an internet password marked "Zadur" (host, protocol, port, user), never in the book or `.git/config`; the address gets the user name (`pi@raspi.local:…`, `https://autorin@…`).
  - How git and ssh get it: for each network command Zadur opens a private Unix socket (in a 0700 temp folder) and points `GIT_ASKPASS` and `SSH_ASKPASS` (`SSH_ASKPASS_REQUIRE=force`) at a two-line script that asks Zadur over it, with a one-time token (`AskpassServer`). Zadur answers the user name to "Username for …", the password to "… password:", and nothing else (no key passphrases, no guesses). The user's own credential helper is switched off for these commands (`credential.helper=` via `GIT_CONFIG_*`), so the password isn't stored elsewhere. Socket and script are removed when the command ends.
  - SSH with a password: `BatchMode=no`, one password prompt, no public-key attempts, and `StrictHostKeyChecking=accept-new` (a new server is remembered; one whose key changed is refused). With keys everything stays as before (`BatchMode=yes`).
  - Checking and connecting use the typed login; only after the server accepted it is it saved. Self-tests keep logins in memory, never in the keychain; the core tests use a throwaway keychain, a local HTTP git server with Basic auth and a stand-in for ssh.

## 14. Signing and timestamps

A signature shows *who* made a version; a trusted timestamp shows *when* it existed (git dates are self-reported). For the club's purpose (showing that a text existed in this form by a given day) the timestamps matter most. Both are set up per Mac in **Einstellungen → Signatur & Zeitstempel** and apply to all books. Zadur never changes the user's git or GPG configuration: everything is passed per call (`-c gpg.format=… -c user.signingkey=… -c commit.gpgsign=true -c tag.gpgsign=true`).

**Signing** covers saved versions, merges, the first commit of new/imported books, milestone tags and export tags; safety-net snapshots and notes are never signed (no Touch ID every ten minutes). Options, found by Zadur itself (`Signing.discover`):
- **Zadur key** (recommended): an ed25519 key Zadur creates for this Mac in `~/Library/Application Support/Stet/Keys` (`signatur-…_ed25519`), no passphrase, no prompts. The setup sheet states the trade-off (anyone with access to the user account could sign).
- **SSH agent**: keys from Secretive, 1Password or the launchd agent (`user.signingkey=key::…`, `SSH_AUTH_SOCK` only for signing calls). Touch ID may ask per version.
- **S/MIME** certificates from the keychain, through `smimesign` (`gpg.format=x509`). Without smimesign Zadur counts the keychain's e-mail certificates and shows `brew install smimesign`. The e-mail used in versions can be set to the certificate's, so Gitea shows the signature as verified.
- **OpenPGP** keys through GnuPG (Homebrew or GPG Suite), if installed.

Choosing an option runs a **probe**: a throwaway commit in a temporary repository, signed exactly like a real version (this is when the keychain or Touch ID asks), then verified. Only then is it saved.

If signing fails later (key gone, agent locked, Touch ID cancelled), `Git.run` repeats the call without the signing options; when that works, the version is saved unsigned and a banner says so. A version is never lost to a signature.

SSH public keys go into the book as `signers/<fingerprint>.pub` (one file per key, so two Macs never conflict); verification uses them plus this Mac's key as `allowed_signers`. History rows show a seal (green: known key; grey: valid but unknown key; red: changed after signing).

**Timestamps (RFC 3161)**, by default from **DigiCert** and **Sectigo** (free, no account, roots in every trust store; more services can be added, https only):
- What is stamped is the SHA-256 of a **receipt** (`Beleg`): `Crea-Receipt 1` (Stet 1.0: `Stet-Beleg 1`; a proof for a version it stamped uses that header, so the checksum still matches), the commit, then every file of the version with its SHA-256 in `shasum -a 256` format. Exported files are stamped by their own SHA-256. The services only ever see that checksum.
- When: the first saved version of each day, every milestone, every exported file, and on request ("Zeitstempel jetzt holen", also for an older version from its history row).
- Zadur builds the request itself (`DER.swift`, `RFC3161`), checks the reply with the Security framework (signature, the authority's certificate with the time-stamping policy as of the stamped time, digest and nonce), and keeps the complete reply.
- Stored as one line per stamp (`crea-stamp 1 …`) in `refs/notes/crea-stamps` (kind, authority, time, digest, base64 reply, file name); Stet 1.0's `refs/notes/stet-stamps` is still read and synced. The notes sync with the server (merged with `cat_sort_uniq`, so stamps from two Macs add up) and are in backups. Stamps still to fetch (offline, a service down) wait per Mac in `.local/zadur-stamps.json` and are retried on the next save, opening or sync; a service is skipped for a stamp after 20 failures.
- macOS's own `openssl` (LibreSSL 3.3) can't verify Sectigo's stamps (an ESS check fails with its cross-signed root); current OpenSSL and macOS itself can. The proof's read-me says so.

**Proofs** (`Nachweis`): a folder anyone can check without Zadur, for a version (history row or Buch menu) or right after an export:
- the version's files in `Buch/` (or the exported file), `Beleg.txt`, `Zeitstempel – <Dienst>.tsr` (the replies) and `Zertifikate – <Dienst>.pem` (the certificates inside each stamp, for `-untrusted`);
- a detached signature of the receipt or file with this Mac's setup (`.sig` + `Schlüssel.allowed_signers` for SSH, `.p7s` for S/MIME, `.asc` + `Schlüssel.asc` for OpenPGP);
- `LIESMICH.txt` in plain German: what it proves, then the commands (`shasum -a 256 -c`, `openssl ts -verify … -CAfile /etc/ssl/cert.pem -untrusted …`, `ssh-keygen -Y verify` / `openssl smime -verify` / `gpg --verify`), the commit, the receipt's SHA-256, serial numbers and each service's root certificate with its fingerprint.

**Datei prüfen …** (Buch menu): picks any file (e.g. the PDF sent to a publisher) and tells whether exactly this file was stamped from this book, and when.

Tests run against a local authority (`LocalTestTSA`: `openssl ts -reply` with a throwaway CA) and throwaway keys/agents; the real services only with `ZADUR_LIVE_TSA=1` and a random checksum. Every self-test replaces the Mac's signing and timestamp settings in memory, so it never signs with the user's key or contacts a real service.

## 15. Git integration

- Uses the **system git** (`/usr/bin/git`, which comes with Xcode's Command Line Tools) via `Process`. On first launch, Zadur checks that git works and otherwise explains how to install it (`xcode-select --install`). The Homebrew cask declares `depends_on formula: "git"`.
- **Isolated from the user's git configuration**. Every invocation passes `-c core.hooksPath=/dev/null -c core.quotePath=false -c core.autocrlf=false -c pull.rebase=false -c commit.gpgsign=false (signing options are added per call when set up, see §14) -c init.defaultBranch=main` and sets `GIT_TERMINAL_PROMPT=0` and `GIT_OPTIONAL_LOCKS=0` (for reads). It parses only machine-readable output (`--porcelain=v2 -z`, `--format` with NUL separators).
- **Books from someone else run nothing** (`RepositoryGuard`, `ForeignBookTests`). A received book brings its own `.git`, and git settings can start programs. Before every git command in a book:
  - **Settings** in `.git/config` are reduced to an allowlist of harmless ones (identity, branch descriptions, the server's address, line endings …). Filters, merge and diff drivers, hooks (also git 2.54's settings-based ones), ssh and pager commands, credential helpers, included files, `core.worktree`, extra push addresses and the like are taken out; the original stays next to it as `.git/config.entfernt`, and a banner names what went. Only the file's bytes are compared each time, so a config that arrives later (sync service) is caught too.
  - **History elsewhere** (`.git` as a link or a pointer file, `commondir`) is refused. Nested repositories are never looked into (`--ignore-submodules`, `submodule.recurse=false`).
  - **Servers** are asked about first (`ServerTrust`): a book's server is only contacted if it was set up on this Mac or the writer agreed ("Kenne ich"); every address of the remote counts. Pushing to a folder would otherwise run that folder's hooks. Servers of books opened before this existed count as known.
  - **SSH keys** count only if they are Zadur's own (a plain file in its keys folder); the command is always rebuilt from the key, never taken from the book.
  - **Importing a folder** compares it with the copy's fresh `.git` instead of running git with the folder's own settings.
  - **ZIPs** (a backup to restore, a wiki to import) are looked into before anything is unpacked (`ZipCheck`, `ZipCheckTests`): absolute paths, `..`, links, devices and encrypted entries are refused. A link could otherwise make Zadur read and show any file on this Mac, e.g. a wiki entry that is really `~/.ssh/id_rsa`.
- All git access goes through one `GitClient` actor in `ZadurCore`, so the backend can be swapped.
- Requires git ≥ 2.34 (SSH signing). Apple Git 2.54 was current at the time of writing.

## 15a. First start, help, problem reports

- **Einführung**: four pages on first start (and Hilfe ▸ Einführung): versions, experiments, notes/wiki/facts, backups/server/export/proofs. The last page offers the **sample book** (`SampleBook`, "Ein Sommer am See", created in Documents): two chapters, four scenes with a flashback, a comment and a TODO, a figure and a place in the wiki, facts, two versions, a milestone and an experiment with another ending – Zadur's own text.
- **Zadur-Hilfe** (⌘?): a searchable help window in German, one page per topic, including all keyboard shortcuts.
- **Problem melden …**: what the user writes, plus technical facts only (versions, tools, settings by kind, the open book in numbers, the last error messages; home folder shortened to "~"), never text from a book; shown in full before it goes out by mail. The recipient is `ZadurSupportEmail` in `project.yml` (empty until set: the user enters it in Mail). Errors and warnings shown to the user are kept in memory for this (`DiagnosticsLog`, last 30).

## 16. Architecture

```
creative_writing_app/
├── docs/          design + decisions
├── editor/        TypeScript, CodeMirror 6 → dist/ (index.html, editor.js, editor.css)
│                  shared by the Mac app and the future web app
├── ZadurCore/      Swift package, UI-free and unit-tested: package format, manifest, Git, history,
│                  word diff, import, sync-location and health checks
└── Zadur/          macOS app: SwiftUI shell + WKWebView hosting editor/dist (Xcode project via XcodeGen)
```

The Xcode project is generated from `project.yml` by XcodeGen, so it stays reviewable as text. The app is `io.github.booneynoobington.stet` (after the GitHub account; the extensions are `….thumbnail` and `….preview`) and declares the book types `io.github.crea-format.book` (`.crea`) and `io.github.booneynoobington.stet.book` (`.stet`, §2a), conforming to `com.apple.package`. The identifier is the former name's, on purpose (§2a). Until November 2026 it was `local.stet.Stet`; on its first start the app copies the old settings once (`SettingsMigration`). The version lives in `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` in `project.yml`.

## 17. Roadmap

1. **Core**: package format, navigator, editor, Save = commit, autosave, snapshots, history list with per-scene diff and restore.
2. **Experiments**: start, switch, adopt (merge UI), adopt scenes, shelve, milestones.
3. **Comments/TODOs, feedback inbox, export** (combined Markdown, .docx, .odt, ePUB, PDF), backups, server sync.
4. **Wiki**, quick facts on hover, **signing + timestamps**.
5. Later: local LLM (commit summaries), English user interface, suggested edits (`{++ ++}`, `{-- --}`), glossary export from the wiki, web app for iPad. (Statistics, `.docx` comment import, timeline and graphical history are built.)

## 18. Open questions

- Are custom refs (`refs/crea/snapshots/*`, `refs/notes/*`) accepted and kept by Gitea on push? If not, snapshots stay local or use a hidden branch prefix.
- Author attribution in comments: is the `@Name:` prefix enough, or are structured comment IDs needed for feedback linking?
- Manuscript-format details (font, spacing, header) for the club.
