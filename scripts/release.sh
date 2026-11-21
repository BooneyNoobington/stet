#!/bin/bash
# Builds a release of Stet: Release configuration, Apple silicon + Intel, hardened runtime,
# packed as Stet-<version>.dmg (drag to Applications) and Stet-<version>.zip in build/release/.
#
#   scripts/release.sh                 version from project.yml, signed ad hoc (for testing)
#   scripts/release.sh 0.9.1           another version
#
# Signed and notarized (needs an Apple Developer account, see docs/RELEASING.md):
#   STET_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
#   STET_NOTARY_PROFILE=stet-notary scripts/release.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml | head -1)}"
BUILD="$(git rev-list --count HEAD)"
IDENTITY="${STET_SIGN_IDENTITY:--}"
PROFILE="${STET_NOTARY_PROFILE:-}"
OUT="build/release"
APP="$OUT/Stet.app"
NAME="Stet-$VERSION"

if [[ -n "$PROFILE" && "$IDENTITY" == "-" ]]; then
  echo "Notarizing needs a Developer ID signature: set STET_SIGN_IDENTITY." >&2
  exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "⚠︎ The working tree has uncommitted changes; the release won't match a commit." >&2
fi

echo "▸ Stet $VERSION (build $BUILD), signed with: $([[ "$IDENTITY" == "-" ]] && echo "ad hoc" || echo "$IDENTITY")"
echo "▸ Generating Xcode project"
xcodegen generate --quiet

TEAM=""
if [[ "$IDENTITY" != "-" ]]; then
  TEAM="$(echo "$IDENTITY" | sed -n 's/.*(\([A-Z0-9]*\))$/\1/p')"
fi

echo "▸ Building (Release, arm64 + x86_64)"
rm -rf "$OUT" build/ReleaseData
xcodebuild -project Stet.xcodeproj -scheme Stet -configuration Release \
  -derivedDataPath build/ReleaseData -quiet build \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  ENABLE_HARDENED_RUNTIME=YES \
  CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
  OTHER_CODE_SIGN_FLAGS="$([[ "$IDENTITY" == "-" ]] && echo "" || echo "--timestamp")"
mkdir -p "$OUT"
ditto build/ReleaseData/Build/Products/Release/Stet.app "$APP"

if [[ "$IDENTITY" == "-" ]]; then
  # Ad hoc there's no team ID, so the hardened runtime would refuse Sparkle.framework.
  codesign --force --sign - --options runtime --entitlements Stet/AdHocRelease.entitlements "$APP"
fi

echo "▸ Checking the signature"
codesign --verify --deep --strict "$APP"
lipo -archs "$APP/Contents/MacOS/Stet"

notarize() {
  echo "▸ Notarizing $(basename "$1") (Apple checks it; takes a few minutes)"
  xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait
}

if [[ -n "$PROFILE" ]]; then
  ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
  notarize "$OUT/notarize.zip"
  rm "$OUT/notarize.zip"
  xcrun stapler staple "$APP"
fi

echo "▸ Packing"
ditto -c -k --keepParent "$APP" "$OUT/$NAME.zip"
STAGE="$(mktemp -d)"
ditto "$APP" "$STAGE/Stet.app"
ln -s /Applications "$STAGE/Programme"
hdiutil create -quiet -volname "Stet $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$OUT/$NAME.dmg"
rm -rf "$STAGE"

if [[ "$IDENTITY" != "-" ]]; then
  codesign --sign "$IDENTITY" --timestamp "$OUT/$NAME.dmg"
fi
if [[ -n "$PROFILE" ]]; then
  notarize "$OUT/$NAME.dmg"
  xcrun stapler staple "$OUT/$NAME.dmg"
  echo "▸ Gatekeeper"
  spctl --assess --type execute --verbose "$APP"
  spctl --assess --type open --context context:primary-signature --verbose "$OUT/$NAME.dmg"
fi

# The update feed for Sparkle: the ZIP, signed with the EdDSA key (in the keychain, or a file
# for tests via STET_SPARKLE_KEY_FILE). Upload appcast.xml with the release (docs/RELEASING.md).
SIGN_UPDATE="build/ReleaseData/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
if [[ -x "$SIGN_UPDATE" ]]; then
  echo "▸ Update feed (appcast.xml)"
  KEY_ARGS=()
  [[ -n "${STET_SPARKLE_KEY_FILE:-}" ]] && KEY_ARGS=(--ed-key-file "$STET_SPARKLE_KEY_FILE")
  # With the key in the keychain, macOS asks once whether sign_update may use it: "Always Allow".
  if ! SIGNATURE="$("$SIGN_UPDATE" "${KEY_ARGS[@]}" "$OUT/$NAME.zip")"; then
    echo "⚠︎ No appcast.xml: the update key wasn't available (keychain access refused?)." >&2
    SIGNATURE=""
  fi
fi
if [[ -n "${SIGNATURE:-}" ]]; then
  REPO="https://github.com/BooneyNoobington/stet"
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
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>$REPO/releases/tag/v$VERSION</sparkle:releaseNotesLink>
      <enclosure url="$REPO/releases/download/v$VERSION/$NAME.zip" $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
  echo "✓ $OUT/appcast.xml"
fi

shasum -a 256 "$OUT/$NAME.dmg" "$OUT/$NAME.zip" | sed "s|$OUT/||" > "$OUT/$NAME.sha256"
echo "✓ $OUT/$NAME.dmg"
echo "✓ $OUT/$NAME.zip"
cat "$OUT/$NAME.sha256"
