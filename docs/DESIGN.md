# Stet — Design

> *stet* (Latin, "let it stand"): the proofreader's mark that restores text that was crossed out.

Stet is a macOS app for long-form creative writing that keeps a lossless, branchable history of the work using git, without the writer ever seeing git. In one sentence: **GitKraken for writers.**

Status: Phases 1–3 are built (core, experiments, sync, export, notes & feedback, backups) – Nov 2026. Sections marked **Open** still need a decision.

---

## 1. Principles

1. **The writer never sees git vocabulary.** No "commit", "branch", "merge", "HEAD", conflict markers, or hashes in the UI.
2. **Nothing is ever lost.** Every save is reconstructable; experiments are shelved, never deleted.
3. **The files on disk are exactly what the writer typed.** No editor or tool silently reformats text. Clean diffs depend on it.
4. **Plain, open formats.** A book is Markdown + YAML in a folder, readable with any text editor, verifiable with standard git tools.
5. **Distraction-free first, expert features on demand.** Commit notes, signing and remotes exist but never get in the way.

## 2. Platform and distribution

- **macOS only** for now. The iPad and other devices get a **web app later**. The editor component is chosen so it can be reused there (see §7).
- **Direct download + Homebrew tap.** No Mac App Store, no sandbox, so Stet can call the system `git`, `ssh-keygen`, `gpg`, Pandoc and Typst.
- Builds for other people need Developer ID signing + notarization. Updates via Sparkle.

## 3. Vocabulary

| Writer sees | Under the hood |
|---|---|
| Save / version | commit |
| Note on a version | `git notes` |
| Snapshot (automatic) | commit on a hidden per-device ref |
| Experiment | branch `experiments/<slug>` |
| Adopt experiment | merge (`--no-ff`) |
| Adopt some scenes | normal commit with `Stet-Adopted-From:` trailer |
| Shelve experiment | rename branch to `shelved/<slug>` |
| Milestone | annotated tag `milestone/<slug>` |
| Server / sync | remote `origin` (e.g. Gitea) |

## 4. The `.stet` package

A `.stet` book is a **directory package**: Stet declares the `.stet` type as conforming to `com.apple.package`, so Finder shows it as a single file (the same mechanism `.app` uses). On machines without Stet, and to sync tools, it is an ordinary folder.

```
Der Leuchtturm.stet/
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
- **Bundle bit.** Stet sets it on every book it creates, imports or opens, so the book shows as a single file even on Macs without Stet. Finder copies, AirDrop and Time Machine keep it; git and sync services don't.
- **Thumbnail extension.** Finder shows the book's cover as its icon, or a drawn title page (title and author) when there is no cover.
- **Preview extension.** The space bar shows the title, author, contents with word counts and the opening of the book.
- **Icons.** The app and document icons use the proofreader's stet mark: dots under a word. They are drawn in code (`Stet/Shared/StetArtwork.swift`, rendered by `scripts/make-icons.sh`).

### 4.1 `manuscript.yaml`

```yaml
format: 1
title: Der Leuchtturm
authors: [Jane Doe]
language: de
year: 2026                # defaults to the current year
cover: assets/cover.jpg
export:
  sceneBreak: "* * *"
  quotes: de              # de („“), guillemets (»«), en (“”)
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

The editor only ever sees the prose. Stet strips the front matter before handing the text to the editor and puts it back on save. Front matter is edited in an inspector.

All text files are **UTF-8 with LF line endings**. CodeMirror normalizes line breaks to LF anyway, so imported files with CRLF are converted once, visibly, on import, never silently on save.

### 4.3 Versioned vs. local settings

| Versioned (in the book) | Local (in `.local/` or app preferences) |
|---|---|
| title, author, year, language | writing-pane font, size, line height, theme |
| structure, quick-fact field definitions | window layout, open scene, cursor position |
| export styling (PDF font, trim size, scene-break glyph) | comments shown/hidden, focus mode |
| remote URL | signing key reference |

### 4.4 Where books live (sync services)

A sync service such as Nextcloud, Dropbox, OneDrive or iCloud cannot be stopped from touching a folder. A synced `.git` can break when two devices write to it. Stet therefore:

1. **Detects** synced locations when a book is created or opened: `~/Library/CloudStorage/*`, `~/Library/Mobile Documents`, `~/Documents` and `~/Desktop` when "Desktop & Documents in iCloud" is on, and a parent folder containing Nextcloud's `.sync_*.db` or Syncthing's `.stfolder`. It then shows a calm banner: *"This book is in a Nextcloud folder. Stet keeps your history itself and syncs through your server. Folder syncing can damage it."* with buttons **Move to my books folder** and **Keep here**.
2. Asks once, on first launch, where books should live (default suggestion `~/Books`, never `~/Documents`).
3. Runs a **health check** on open: looks for conflicted-copy files (`… (conflicted copy …)`, `… 2.md`) and runs `git fsck --connectivity-only`. If the book is damaged and a remote exists, it offers **Restore from server** and carries the unsaved working text over.

Rejected: excluding only `.git` from sync. The text would sync and the history wouldn't, so each machine would see the other's edits as unexplained changes.

## 5. Structure and navigation

- **Navigator**: a tree in the style of Typora's sidebar. No file names or icons. Drag and drop to reorder, a quiet word count, and a status dot (draft / revised / done).
- **Quick facts**: user-defined fields per book (e.g. *Datum, Uhrzeit, Ort, POV, Wetter*). They are stored in the scene's front matter, or in `manuscript.yaml` for chapters and parts, and shown on hover in the navigator. A fact can point to a wiki entry (`[[Hafen]]`); hovering it shows that entry's quick facts.
- Later: a **timeline view** plotting story time against reading order, for pacing.

## 6. Saving and history

| Action | What happens |
|---|---|
| Typing | Autosave writes the files to disk (debounced, ~2 s). No commit. |
| **Save (⌘S)** | Commit straight away with a generated message (`Edited "Ankunft", "Die Flut" · +412 words`). A small "Add a note" field appears and fades out on its own. Nothing blocks. |
| Note added later | `git notes add` on that commit. Never rewrites history. |
| App goes to background / idle 10 min / quit without saving | **Safety-net snapshot**: commit built with a temporary index (`GIT_INDEX_FILE` + `git write-tree` + `git commit-tree`) on `refs/stet/snapshots/<device-id>`. The real index and visible history are untouched. |

**Commit trailers** keep later statistics cheap. Nothing has to replay the diffs.

```
Edited "Ankunft" · +412 words

Stet-Words: 85231
Stet-Words-Delta: +412
Stet-Active-Minutes: 47
Stet-Scenes: 7f3a9c,b21e04
```

`Stet-Active-Minutes` comes from the editor (time with keystrokes, minus idle gaps). Git timestamps only record *when* a save happened.

## 7. Editor

**Engine: CodeMirror 6 in a `WKWebView`** for the writing pane. Everything else (navigator, history, inspector, settings, dialogs) is native SwiftUI.

Why:
- CodeMirror edits the source text and only changes how it is *drawn* (decorations), so the file stays byte-for-byte what was typed. WYSIWYG engines (ProseMirror, Milkdown, Tiptap) parse and re-serialize Markdown, which "normalizes" it and pollutes diffs.
- Input methods, undo, long documents and accessibility are already solved (Obsidian, Zettlr and MarkEdit are built on it).
- The future web app reuses the same editor.

Features:
- **Live preview**: Markdown symbols (`*`, `**`, `#`, `***`) are hidden unless the cursor touches them.
- **Comments and TODOs** (§9) render as numbered markers with bubbles in a margin rail and can be shown or hidden.
- **Wiki terms** (§10) are underlined via alias matching.
- **Typography**: smart quotes per book language (`„“`, `»«`, `“”`), apostrophe `’`, ` -- ` → ` – `, `...` → `…`.
- **Focus mode**: dims everything except the current paragraph, with typewriter scrolling.
- **Theming** (local setting): font family, size, line height, column width, light/dark from the system.

**Bridge** (JSON messages):
- Swift → JS: `load(text)`, `getText()`, `setSettings({...})`, `getSettings()`, `stats()`, `focus()`
- JS → Swift: `ready`, `changed` (no text; Swift tracks the dirty state), `stats {words, characters}`, `activity` (for active minutes)

Swift pulls the text with `getText()` when saving, instead of receiving it on every keystroke.

The prototype validated this choice (see `docs/editor-spike.md`): automated checks pass. The hands-on checklist is the final word.

## 8. Experiments, merging, milestones

- **Start experiment** → `git switch --create experiments/<slug>`. The name is required ("Kapitel 3 aus Maras Sicht"); the slug keeps umlauts and case (`Kapitel-3-aus-Maras-Sicht`), and the full name is stored as the branch description. Unsaved changes either move into the experiment or are first saved as a version where they are; the writer chooses.
- **Switching** saves pending changes as a version first, so there is never an "unsaved changes" dialog or a stash. Branches without `manuscript.yaml` (from before Stet) can't be opened, but they can be adopted.
- A tinted banner and the toolbar's version menu always show which version is open.
- **Adopt experiment** → `git merge --no-ff --no-commit experiments/<slug>` into the main version:
  - **Structure.** `manuscript.yaml` is merged by Stet whenever both sides changed it (`Manifest.merge`). Each side's additions, removals, moves and renames are kept. A new scene follows its predecessor from the experiment. Removing beats moving. If both sides changed the same field, the main version wins. Without a common ancestor (two imported branches), only what both share counts as "before", so nothing is lost.
  - **Scenes.** A scene's front matter and prose are merged separately. Otherwise a title change on one side and an edit of the opening paragraph on the other would collide, because the title block sits directly above it. For scenes from before an import, the common ancestor is found by the scene's title (`Szenen/<Titel>.md`).
  - **Conflicts.** What is left is shown per passage: *Hauptfassung* | *Experiment*, with **Diese Fassung / Beide behalten / Selbst formulieren**. A scene deleted on one side and edited on the other offers **Behalten / Löschen**. A kept scene goes back where the experiment has it. Files that can't be merged as text offer a choice of side. Conflict markers are never shown.
  - **Finishing** writes one version with both histories as parents (`Stet-Adopted-From: <branch> <sha>`), after removing structure entries whose files are gone. **Cancelling** (`git merge --abort`) leaves everything as before.
  - While an adoption is open, nothing writes to the working tree (autosave, snapshots and versions are blocked). After a crash or quit, a banner offers to continue or cancel.
- **Adopt some scenes** → copies the chosen scene files from the experiment into the main version; new scenes are placed as in the experiment. One normal version with `Stet-Adopted-From:`.
- **Shelve** → rename to `shelved/<slug>`. Shelved experiments can be brought back and are never deleted. Adopted experiments stay listed as "übernommen" until shelved.
- **Milestones** → annotated tags `milestone/<slug>` on the current version (pending changes are saved first). The tag message holds the name and an optional note. Milestones show as flags in a scene's history.
- **Import**: other branches of an imported repository that are fully merged are shelved. Branches with their own work become experiments, converted to the Stet layout with the same scene and chapter IDs as the main version, so they open and adopt cleanly.
- **Diffs** are shown word-level within paragraphs and rendered by Stet, not git's line diff.

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

Comments are excluded from word counts and removed on export (or turned into Word comments for `.docx` review copies). The `{~~old~>new~~}` substitution syntax is avoided because `~~` collides with GFM strikethrough; Stet uses CommonMark without that extension.

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

Git has no wiki. Forge wikis (Gitea, GitHub) are a separate repository, and issues live in the forge's database, so neither is used. Instead, the `wiki/` folder sits in the same repository, so the wiki is versioned and branched together with the manuscript.

```markdown
---
title: Mara Kessler
kind: character             # character | place | term | … (user-extensible)
aliases: [Mara, Captain Kessler, die Kapitänin]
facts:
  Geboren: 1921
  Augen: grau
---
Free-form background …
```

- **No markup in the prose.** The editor underlines alias matches (Unicode word boundaries, case-sensitive per entry). Clicking one opens the entry; hovering shows its quick facts.
- **Create entry from selection** adds the selected text as an alias.
- Backlinks ("appears in …") are computed from the same matching.
- Optional export as a glossary appendix (ePUB/PDF).

## 11. Export

**Ablage ▸ Exportieren … (⌘E)** or the toolbar button. Formats:

| Format | How | Look |
|---|---|---|
| PDF – Manuskript | Pandoc → Typst (`Resources/manuscript.typ`) | A4, Times 12 pt, generous line spacing, first-line indent; title page with name and word count; header "Name · Titel · Seite" and the version line in the footer of **every** page |
| PDF – Buch | Pandoc → Typst (`Resources/book.typ`) | 13.5 × 21 cm, Iowan Old Style 10.5 pt, justified with hyphenation; running heads (author on even pages, chapter on odd pages, none on chapter openings); chapters start on right-hand pages; cover page, title page and imprint with the version |
| ePUB | Pandoc (epub3) | TOC, cover, the book's own CSS followed by Stet's (`Resources/epub.css`), colophon with the version |
| Word / ODT | Pandoc with `Resources/reference.docx` | Times 12 pt, 1.5 line spacing, centred "Szenenwechsel" style; version line under the title. Optionally comments/TODOs as real Word comments (author from `@Name:`) |
| Markdown | Stet itself | the combined Markdown |

Pipeline:

1. **Pending changes are saved as a version first**, so the stamp names exactly the text in the file.
2. **Stet builds a combined Markdown for the target** (`CombinedMarkdown`):
   - YAML metadata, always quoted so "1.530" or "1984" stay text
   - parts and chapters as headings
   - scene breaks per target: a Typst `#scenebreak()`, `<p class="scene-break">⁂</p>`, the Word style "Szenenwechsel", or `* * *`
   - comments removed, or turned into Pandoc comment spans for docx/odt
   - optional scene titles
3. **Typography for the chosen quote style** („“ / »« / “” / unverändert): straight quotes → typographic ones by context, apostrophe ’, ` -- ` → ` – `, `...` → `…`. Same rules as typing in the editor; CriticMarkup and `***` lines are left alone. The writer's text isn't changed, only the export.
4. **Pandoc runs with `--from=markdown-smart`** and a Lua filter (`Resources/stet.lua`): links without a target become their text, and images whose file is missing become their caption. A real manuscript's early version had `[<!-- … -->]()`, which Typst refuses.
5. **Every export is tagged** `export/<date>-<format>` (annotated, with the file name). The history shows these marks; the writer's own milestones take precedence.

Tools: Pandoc and Typst from Homebrew (`/opt/homebrew/bin`, `/usr/local/bin`, `PATH`). If one is missing, the sheet says so with the `brew install` line. Bundling them comes later.

## 12. Backup

A backup is **one ZIP file** of the whole package: history, experiments, milestones, export marks, feedback with attachments, and also unsaved text on disk. Per-device state (`.local/`) is left out. Name: `<Titel> – Backup 2026-11-20 1430.stet.zip`; unzipped it is `<Titel>.stet`, ready to open.

- **Written safely**: `/usr/bin/zip` into a temporary folder, checked with `unzip -t`, then moved into the target in one step. A half-written backup never appears there, which matters for synced folders.
- **A single file is fine for sync services.** Unlike a live book, a backup may sit in Nextcloud, iCloud or Dropbox, or on an external drive.
- **Backup sichern … (⌥⌘B)** writes a backup to a file of the writer's choice.
- **Backup wiederherstellen …** unpacks a backup into a chosen folder and opens it. A book of the same name stays untouched (the restored one is called "… (wiederhergestellt)"); the archive is checked first.
- **Automatic backups** (Inspector ▸ Buch ▸ Backups, or Ablage ▸ Backups einstellen …) are per book and per Mac (`.local/state.json`). They run at most once every 20 hours, on opening or after ⌘S, into a chosen folder (default `~/Documents/Stet-Backups`), and keep the newest N of this book (other books' backups in the same folder are not touched). If the folder is unavailable, e.g. a drive is unplugged, the inspector shows a quiet hint instead of an error dialog.
- The server and Time Machine are further backups.

## 12a. Import

**Import folder** turns a folder of Markdown scenes into a book, leaving the source untouched:

- A `book.yaml` (chapters → scene names, title, authors, language, cover, CSS) defines the structure. Without one, every `.md` file becomes a scene of one chapter. Scenes not listed go to a chapter "Nicht zugeordnet".
- If the folder is a git repository, the book is a **clone**: the whole history is kept, and other branches (local and remote-tracking) become experiments. The conversion is one ordinary commit, and git's rename tracking lets every scene's history reach back before the import. The original remote is removed, so nothing is pushed to the old repository by accident.
- Scene bodies stay byte-identical; titles go into front matter. Cover and CSS go to `assets/`, other Markdown files to `wiki/`, unknown files to `imported/`. Tooling that Stet replaces (`book.yaml`, build scripts, `README.md`) is removed in the conversion commit and stays in the history.

## 13. Sync and remotes

If a book has a remote (`origin`), **the remote is the source of truth.**

- **Connecting** (Inspector ▸ Buch ▸ Server, or Buch ▸ Server …) first checks the server (`ls-remote` plus a fetch into a temporary ref). An **empty** repository gets the whole book. A server with **this book's history** is continued. This includes a repository used before Stet: Stet's main version is a fast-forward of it, so the server afterwards shows the Stet layout, and the old files stay in its history; the sheet says so. A server with **another project** is refused.
- **On open**: full sync. Stet fetches, fast-forwards what the server has (main version and experiments), and sends what's new here. Pending changes are saved as a version first.
- **After ⌘S** (and after starting/shelving experiments, milestones, adoptions): sync **without integrating**. Stet only sends, and reports when the server has new versions. Nothing in the working tree changes while the writer may be typing. A blue banner offers **Holen** (fetch, with the text written to disk first).
- **Both Macs wrote**: the banner offers **Zusammenführen …**. It uses the adoption machinery (`mergeWithServer` = merge of `origin/main`), with the same decision window labelled *Dieser Mac* | *Server*. The result is a merge version "Mit dem Server zusammengeführt" (`Stet-Merged-From:`).
- **What is sent**: all branches that are ahead (`main`, `experiments/*`, `shelved/*`), milestone tags, notes (`refs/notes/commits`, merged with `cat_sort_uniq` on fetch), and this Mac's snapshot ref (the only forced push; one writer per ref). Branches that are behind or diverged are never sent; a diverged experiment is reported and left alone.
- **Shelving travels**: shelving deletes the experiment's old name on the server. A Mac that still has it active, at the same version, renames it to `shelved/…` as well. An experiment shelved here is not brought back by its old name.
- **Fetching never deletes local data**: `--prune` applies only to remote-tracking branches. (With a tags refspec it would delete milestones the server doesn't have yet; a test guards this.)
- **Addresses with a port**: the short form `user@host:path` can't carry a port; `git@host:2222/name/buch.git` would be read as path `2222/…`. The server sheet recognises this and offers `ssh://git@host:2222/name/buch.git` (or the short form without port if `~/.ssh/config` already sets it).
- **Own key per book** (optional): for SSH keys that ask for Touch ID or a passphrase on every use (e.g. Secretive), Stet can create a passphrase-less ed25519 key for one book. It lives in `~/Library/Application Support/Stet/Keys` (folder 700, key 600), outside the book, so it's never synced. It is used only for that book via the book's local `core.sshCommand` (`-i <key> -o IdentitiesOnly=yes -o IdentityAgent=none`). Before creating it, the sheet explains the risks: an unencrypted key readable by any program of the user, and included in Time Machine backups. It recommends adding the key in Gitea as a **deploy key of that one repository** (with write access), not to the account. Removing it deletes it from the Mac; the sheet reminds the writer to remove the deploy key too. "Buch vom Server holen" can create such a key before cloning.
- **Network**: SSH runs with `BatchMode=yes` and `ConnectTimeout=15`, so it never waits for a password or host-key question. git/ssh errors are translated: unknown host, no connection, unknown host key ("connect once in Terminal"), permission denied, no repository. HTTPS uses the system credential helper.
- **Second Mac**: "Buch vom Server holen …" clones the book; experiments come along as local branches. Experiment names travel as their slug (`Kapitel-3-aus-Maras-Sicht` → "Kapitel 3 aus Maras Sicht"); real hyphens in names become spaces on the other Mac.
- **Status bar**: "Server: abgeglichen 14:02 / wird abgeglichen / neue Versionen verfügbar / zusammenführen nötig / nicht erreichbar". Click to sync now (⌃⌘S).

## 14. Signing and timestamps

- **Commit signing**. A commit contains the hash of the complete file tree and its parent commit, so a signed commit covers every file and the whole history before it. Formats:
  - **SSH** (default): key generated by Stet with the system `ssh-keygen`, or an existing key. `gpg.format=ssh`.
  - **OpenPGP**: if `gpg` is installed (GPG Suite / Homebrew).
  - **S/MIME / X.509**: possible via `gpgsm` or `smimesign`; low priority.
- **Trusted timestamps**: a signature proves *who* signed, not *when*, and git dates are self-reported. Stet periodically timestamps the latest commit hash with an RFC 3161 authority or OpenTimestamps. Proofs are stored as `git notes` under `refs/notes/stet-timestamps`.
- **Proof of authorship export**: the repository plus signatures plus timestamp proofs, verifiable with standard tools (`git verify-commit`, `ots verify` / `openssl ts -verify`).

## 15. Git integration

- Uses the **system git** (`/usr/bin/git`, which comes with Xcode's Command Line Tools) via `Process`. On first launch, Stet checks that git works and otherwise explains how to install it (`xcode-select --install`). The Homebrew cask declares `depends_on formula: "git"`.
- **Isolated from the user's git configuration**. Every invocation passes `-c core.hooksPath=/dev/null -c core.quotePath=false -c core.autocrlf=false -c pull.rebase=false -c commit.gpgsign=<stet setting> -c init.defaultBranch=main` and sets `GIT_TERMINAL_PROMPT=0` and `GIT_OPTIONAL_LOCKS=0` (for reads). It parses only machine-readable output (`--porcelain=v2 -z`, `--format` with NUL separators).
- All git access goes through one `GitClient` actor in `StetCore`, so the backend can be swapped.
- Requires git ≥ 2.34 (SSH signing). Apple Git 2.54 was current at the time of writing.

## 16. Architecture

```
creative_writing_app/
├── docs/          design + decisions
├── editor/        TypeScript, CodeMirror 6 → dist/ (index.html, editor.js, editor.css)
│                  shared by the Mac app and the future web app
├── StetCore/      Swift package, UI-free and unit-tested: package format, manifest, Git, history,
│                  word diff, import, sync-location and health checks
└── Stet/          macOS app: SwiftUI shell + WKWebView hosting editor/dist (Xcode project via XcodeGen)
```

The Xcode project is generated from `project.yml` by XcodeGen, so it stays reviewable as text. It declares the `.stet` type (`local.stet.book`, conforming to `com.apple.package`). The bundle identifier `local.stet.Stet` is a placeholder until there is a real domain for signing.

## 17. Roadmap

1. **Core**: package format, navigator, editor, Save = commit, autosave, snapshots, history list with per-scene diff and restore.
2. **Experiments**: start, switch, adopt (merge UI), adopt scenes, shelve, milestones.
3. **Comments/TODOs, feedback inbox, export** (combined Markdown, .docx, .odt, ePUB, PDF), backups, server sync.
4. **Wiki**, quick facts on hover, **signing + timestamps**.
5. Later: statistics from trailers, graphical history, timeline view, `.docx` comment import, local LLM (commit summaries), web app for iPad.

## 18. Open questions

- Are custom refs (`refs/stet/snapshots/*`, `refs/notes/*`) accepted and kept by Gitea on push? If not, snapshots stay local or use a hidden branch prefix.
- Author attribution in comments: is the `@Name:` prefix enough, or are structured comment IDs needed for feedback linking?
- Manuscript-format details (font, spacing, header) for the club.
- Whether to bundle Pandoc in a later version, or keep it as a dependency.
