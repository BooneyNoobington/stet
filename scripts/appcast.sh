#!/bin/bash
# Writes build/release/appcast.xml, Sparkle's update feed, for the ZIP that scripts/release.sh
# built. Version and build number come from the built app itself, the signature from the EdDSA
# update key: in the login keychain (macOS asks once whether sign_update may use it: "Always
# Allow"), or for tests a key file via STET_SPARKLE_KEY_FILE. release.sh runs this at the end;
# run it on its own to redo just the feed, without building and notarizing again.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OUT="build/release"
INFO="$OUT/Stet.app/Contents/Info.plist"
SIGN_UPDATE="build/ReleaseData/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
REPO="https://github.com/BooneyNoobington/stet"

if [[ ! -f "$INFO" ]]; then
  echo "No release build in $OUT: run scripts/release.sh first." >&2
  exit 1
fi
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$INFO"; }
VERSION="$(plist CFBundleShortVersionString)"
BUILD="$(plist CFBundleVersion)"
MINIMUM="$(plist LSMinimumSystemVersion)"
NAME="Stet-$VERSION"
if [[ ! -f "$OUT/$NAME.zip" ]]; then
  echo "$OUT/$NAME.zip is missing: run scripts/release.sh first." >&2
  exit 1
fi
if [[ ! -x "$SIGN_UPDATE" ]]; then
  echo "Sparkle's sign_update is missing (it comes with the release build): run scripts/release.sh first." >&2
  exit 1
fi

echo "▸ Update feed (appcast.xml) for Stet $VERSION (build $BUILD)"
if [[ -n "${STET_SPARKLE_KEY_FILE:-}" ]]; then
  SIGNATURE="$("$SIGN_UPDATE" --ed-key-file "$STET_SPARKLE_KEY_FILE" "$OUT/$NAME.zip")"
else
  SIGNATURE="$("$SIGN_UPDATE" "$OUT/$NAME.zip")"
fi

cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Stet</title>
    <link>$REPO</link>
    <item>
      <title>Stet $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINIMUM</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>$REPO/releases/tag/v$VERSION</sparkle:releaseNotesLink>
      <enclosure url="$REPO/releases/download/v$VERSION/$NAME.zip" $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
echo "✓ $OUT/appcast.xml"
