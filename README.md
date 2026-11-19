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
project.yml XcodeGen spec for Stet.xcodeproj (generated, not committed)
scripts/    build.sh builds build/Stet.app
```

## Requirements

Xcode, Node.js with npm, XcodeGen (`brew install xcodegen`), macOS 14+.

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

The second one imports the folder into a temporary book and drives the whole flow: scenes, editing, versions, notes, snapshots, history, restore, structure and health. It deletes the temporary book afterwards and only reads the folder.
