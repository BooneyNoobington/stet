# Stet

A macOS app for long-form creative writing with a lossless, branchable history: git under the hood, without the writer ever seeing git. *Stet* is the proofreader's mark for "let it stand", i.e. restore what was crossed out.

- [docs/DESIGN.md](docs/DESIGN.md): the design (package format, saving, experiments, comments, wiki, export, signing)
- [docs/editor-spike.md](docs/editor-spike.md): the editor prototype, its results and the hands-on checklist

## Layout

```
docs/       design and decisions
editor/     writing pane: TypeScript + CodeMirror 6 (shared with the future web app)
StetCore/   Swift package, no UI: book format, git, history, word diff, import, safety checks (+ tests)
Stet/       macOS app: SwiftUI shell + WKWebView hosting the editor
            QuickLookThumbnail/, QuickLookPreview/: Finder icons and space-bar preview for books
            Shared/StetArtwork.swift: icons and title page, drawn in code; Resources/: rendered .icns
project.yml XcodeGen spec for Stet.xcodeproj (generated, not committed)
scripts/    build.sh builds build/Stet.app; make-icons.sh re-renders the icons after artwork changes
```

## Requirements

Xcode, Node.js with npm, XcodeGen (`brew install xcodegen`), macOS 14+. For exporting, Pandoc and Typst: Stet offers to download them, or `brew install pandoc typst`.

Releases (DMG/ZIP, signing and notarization): see [docs/RELEASING.md](docs/RELEASING.md).

## Build and run

```bash
./scripts/build.sh --test
```

```bash
open build/Stet.app
```

To work in Xcode, run `xcodegen` once and open `Stet.xcodeproj`.

## Self-tests

Both print a JSON report and exit non-zero on failure. Neither prints manuscript text.

```bash
build/Stet.app/Contents/MacOS/Stet --selftest
```

```bash
build/Stet.app/Contents/MacOS/Stet --selftest-book <folder with Markdown scenes>
```

To check the Quick Look preview page of a book in a browser:

```bash
build/Stet.app/Contents/MacOS/Stet --preview-html <book.stet> preview.html
```

The `--selftest-book` check imports the folder into a temporary book and drives the whole flow: scenes, editing, versions, notes, snapshots, history, restore, structure and health. It deletes the temporary book afterwards and only reads the folder.

## License

Stet is free software, licensed under the [GNU General Public License v3.0 or later](LICENSE). Copyright © 2026 Markus Roth.

The app contains third-party components under the MIT license (CodeMirror and Lezer in the editor, Yams with libYAML in the core, Sparkle for updates); their notices are in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md), which `scripts/third-party-notices.sh` regenerates after dependency changes. Pandoc, Typst and git are separate programs that Stet runs; on request Stet downloads Pandoc's and Typst's official releases from their projects. They are not part of it.
