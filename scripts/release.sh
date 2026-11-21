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

echo "▸ Building (Release, arm64 + x86_64)"
rm -rf "$OUT" build/ReleaseData
# Built with the project's own ad hoc signature and signed for real below. (An identity given
# to xcodebuild clashes with the Swift packages' automatically signed resource bundles, and it
# wouldn't reach Sparkle's helper programs, which notarization checks too.) No debugger
# entitlement (get-task-allow) either: notarization refuses it.
xcodebuild -project Stet.xcodeproj -scheme Stet -configuration Release \
  -derivedDataPath build/ReleaseData -quiet build \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
mkdir -p "$OUT"
ditto build/ReleaseData/Build/Products/Release/Stet.app "$APP"

echo "▸ Signing"
# Inside out: Sparkle's helper programs, the frameworks, the Quick Look extensions (each keeps
# its own entitlements), then the app. Developer ID signatures get Apple's secure timestamp.
TIMESTAMP="--timestamp=none"
[[ "$IDENTITY" != "-" ]] && TIMESTAMP="--timestamp"
sign() { codesign --force --sign "$IDENTITY" --options runtime "$TIMESTAMP" "$@"; }
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/Current"
for code in "$SPARKLE"/XPCServices/*.xpc "$SPARKLE/Autoupdate" "$SPARKLE/Updater.app" \
            "$APP"/Contents/Frameworks/*.framework "$APP"/Contents/Frameworks/*.dylib \
            "$APP"/Contents/PlugIns/*.appex; do
  if [[ -e "$code" ]]; then sign --preserve-metadata=entitlements "$code"; fi
done
if [[ "$IDENTITY" == "-" ]]; then
  # Ad hoc there's no team ID, so the hardened runtime would refuse Sparkle.framework.
  sign --entitlements Stet/AdHocRelease.entitlements "$APP"
else
  sign "$APP"
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

# The update feed for Sparkle (upload appcast.xml with the release, docs/RELEASING.md).
if ! scripts/appcast.sh; then
  echo "⚠︎ No appcast.xml (update key not available?). Only the feed can be redone: scripts/appcast.sh" >&2
fi

shasum -a 256 "$OUT/$NAME.dmg" "$OUT/$NAME.zip" | sed "s|$OUT/||" > "$OUT/$NAME.sha256"
echo "✓ $OUT/$NAME.dmg"
echo "✓ $OUT/$NAME.zip"
cat "$OUT/$NAME.sha256"
