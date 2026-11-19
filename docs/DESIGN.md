# Stet — Design

> *stet* (Latin, "let it stand"): the proofreader's mark that restores text that was crossed out.

Stet is a macOS app for long-form creative writing that keeps a lossless, branchable history of the work using git, without the writer ever seeing git. In one sentence: **GitKraken for writers.**

Status: design agreed in discussion (Nov 2026). Sections marked **Open** still need a decision.

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

### 4.1 `manuscript.yaml`

```yaml
format: 1
title: Der Leuchtturm
author: Jane Doe
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

The prototype in `editor/` + `app/` exists to validate this choice before anything is built on it (see `docs/editor-spike.md`). Automated checks pass; the hands-on checklist decides.

## 8. Experiments, merging, milestones

- **Start experiment** → `git switch -c experiments/<slug>`; the name is required and descriptive ("Kapitel 3 aus Maras Sicht").
- Switching between main and an experiment **saves first**, so there is never an "unsaved changes" dialog or a stash.
- **Adopt experiment** → `git merge --no-ff --no-commit experiments/<slug>`:
  - Files changed on one side only, or in different paragraphs, are merged automatically. A paragraph is one line in Markdown, so git's line merge works per paragraph.
  - **Conflicts** are presented per paragraph: *Main* | *Experiment*, with **Keep this / Keep that / Edit**. Stet reads the three versions from the index stages (`:1:`, `:2:`, `:3:`) and never shows conflict markers.
  - `manuscript.yaml` is merged by Stet itself (three-way merge of the structure as lists and maps), never as text.
- **Adopt some scenes** → copy the chosen scene files from the experiment, then a normal commit with `Stet-Adopted-From: experiments/<slug> <sha>`.
- **Shelve** → rename to `shelved/<slug>`. Shelved experiments are never deleted.
- **Milestones** → annotated tags, created manually ("Sent to club") or automatically on every export.
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

**Feedback inbox** (`feedback/`): one entry per piece of feedback, with `from`, `received` and `refersTo` (the milestone of the export they read, preselected automatically). Stet can paste in email text, attach a photo of a marked-up printout, or import a `.docx`. While working through an entry, the writer links a passage in it to a passage in the manuscript, and Stet inserts a `{>>@Name: …<<}` comment there.

Later: import Word comments from a returned `.docx` automatically. Pandoc reads comments together with the text they point at, and the exported version is known, so Stet can map them onto today's text.

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

Pipeline: **Stet → combined Markdown → Pandoc → .docx / .odt / ePUB**, and **→ Typst → PDF** (`pandoc --pdf-engine=typst`).

1. Stet assembles the **combined Markdown**: Pandoc YAML metadata (title, author, lang, cover), parts and chapters as headings, scene breaks between scenes, comments removed or converted. This is also the "combined Markdown" export.
2. Pandoc converts it, using a reference `.docx`, ePUB CSS and Typst templates bundled with Stet.
3. Presets: **Manuscript** (standard manuscript format for clubs and agents) and **Book** (trim size, running heads, proper hyphenation, no widows or orphans).
4. **Every export is stamped** with its version: a short ID in the footer and metadata, plus an automatic milestone tag `export/<date>-<preset>`. Feedback on a printout can then be compared against exactly that text.

Typst ships inside the app (small, Apache-2.0). Pandoc is a Homebrew dependency for v1; Stet detects it and explains if it's missing. Bundling it comes later.

## 12. Backup

- **Backup now** → zip of the whole package, history included, to a user-chosen place, plus optional rotating automatic backups.
- Pushing to the server is the other backup. Time Machine covers packages automatically.

## 13. Sync and remotes

If a book has a remote configured, **the remote is the source of truth.**

- **On open**: `git fetch`. If the server is ahead and the local copy has no unsaved changes, fast-forward silently. If both sides changed, show "Your other Mac saved changes too" and use the same adopt/merge screen as for experiments.
- **On save**: commit, then push in the background. If offline, the push is queued. If rejected (server ahead), fetch and merge as above. A push can never silently overwrite newer work, which fixes the original Nextcloud data loss.
- Credentials come from the system: the `osxkeychain` credential helper for HTTPS, and `ssh-agent` / `~/.ssh/config` for SSH.

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
└── app/           Swift
    ├── StetCore   (planned) package format, manifest, GitClient, export pipeline. UI-free and unit-tested
    └── Stet       macOS app: SwiftUI shell + WKWebView hosting editor/dist
```

The current `app/` is the editor spike: a SwiftPM executable assembled into a `.app` by `scripts/build-spike.sh`. The real app moves to an Xcode project (or XcodeGen), because it needs the Info.plist type declarations, signing and Sparkle.

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
