#!/bin/bash
# Builds the editor spike into build/Stet.app:
#   1. editor/ (TypeScript, CodeMirror 6) → editor/dist
#   2. app/ (SwiftPM, SwiftUI + WKWebView) → release binary
#   3. assembles the .app bundle and signs it ad hoc (local use only)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Stet.app"

echo "▸ Building editor"
cd "$ROOT/editor"
[ -d node_modules ] || npm install --no-audit --no-fund
npm run --silent build

echo "▸ Building app"
cd "$ROOT"
swift build -c release --package-path app
BIN="$(swift build -c release --package-path app --show-bin-path)/Stet"

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Stet"
cp -R "$ROOT/editor/dist" "$APP/Contents/Resources/editor"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Stet</string>
  <key>CFBundleDisplayName</key><string>Stet (Editor-Prototyp)</string>
  <key>CFBundleIdentifier</key><string>local.stet.editor-spike</string>
  <key>CFBundleExecutable</key><string>Stet</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleDevelopmentRegion</key><string>de</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "✓ Built $APP"
