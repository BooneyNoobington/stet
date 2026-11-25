#!/bin/bash
# Regenerates Zadur/Resources/ZadurBook.icns (books in Finder) from Zadur/Shared/ZadurArtwork.swift.
# Only needed after changing the artwork; the .icns is committed. The app icon itself is part of
# Zadur-Icon-Kit (ZadurIcons.xcassets), which the project uses directly.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Top-level code is only allowed in a file named main.swift when compiling several files.
cp "$ROOT/scripts/make-icons.swift" "$WORK/main.swift"
swiftc -O "$ROOT/Zadur/Shared/ZadurArtwork.swift" "$WORK/main.swift" -o "$WORK/make-icons"
"$WORK/make-icons" "$WORK"

mkdir -p "$ROOT/Zadur/Resources"
iconutil -c icns "$WORK/ZadurBook.iconset" -o "$ROOT/Zadur/Resources/ZadurBook.icns"

# Previews for a quick look at the result (not committed).
mkdir -p "$ROOT/build/icon-previews"
cp "$WORK/ZadurBook.iconset/icon_512x512.png" "$ROOT/build/icon-previews/book.png"
cp "$WORK/ZadurBook.iconset/icon_32x32.png" "$ROOT/build/icon-previews/book-32.png"
cp "$WORK/title-page-sample.png" "$ROOT/build/icon-previews/title-page.png"
echo "✓ Zadur/Resources/ZadurBook.icns (previews in build/icon-previews)"
