# Stet

A macOS app for long-form creative writing with a lossless, branchable history: git under the hood, without the writer ever seeing git. *Stet* is the proofreader's mark for "let it stand", i.e. restore what was crossed out.

- [docs/DESIGN.md](docs/DESIGN.md): the design (package format, saving, experiments, comments, wiki, export, signing)
- [docs/editor-spike.md](docs/editor-spike.md): the editor prototype, its results and the hands-on checklist

## Layout

```
docs/      design and decisions
editor/    writing pane: TypeScript + CodeMirror 6 (shared with the future web app)
app/       macOS shell: SwiftUI + WKWebView (currently the editor spike)
scripts/   build-spike.sh assembles build/Stet.app
```

## Requirements

Xcode (Swift 5.10+), Node.js with npm, macOS 14+.

## Build and run the editor spike

```bash
./scripts/build-spike.sh
```

```bash
open build/Stet.app
```
