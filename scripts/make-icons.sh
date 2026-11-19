#!/bin/bash
# Regenerates Stet/Resources/Stet.icns and StetBook.icns from Stet/Shared/StetArtwork.swift.
# Only needed after changing the artwork; the .icns files are committed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Top-level code is only allowed in a file named main.swift when compiling several files.
cp "$ROOT/scripts/make-icons.swift" "$WORK/main.swift"
swiftc -O "$ROOT/Stet/Shared/StetArtwork.swift" "$WORK/main.swift" -o "$WORK/make-icons"
"$WORK/make-icons" "$WORK"

mkdir -p "$ROOT/Stet/Resources"
iconutil -c icns "$WORK/Stet.iconset" -o "$ROOT/Stet/Resources/Stet.icns"
iconutil -c icns "$WORK/StetBook.iconset" -o "$ROOT/Stet/Resources/StetBook.icns"

# Previews for a quick look at the result (not committed).
mkdir -p "$ROOT/build/icon-previews"
cp "$WORK/Stet.iconset/icon_512x512.png" "$ROOT/build/icon-previews/app.png"
cp "$WORK/StetBook.iconset/icon_512x512.png" "$ROOT/build/icon-previews/book.png"
cp "$WORK/Stet.iconset/icon_32x32.png" "$ROOT/build/icon-previews/app-32.png"
cp "$WORK/title-page-sample.png" "$ROOT/build/icon-previews/title-page.png"
echo "✓ Stet/Resources/Stet.icns, StetBook.icns (previews in build/icon-previews)"
