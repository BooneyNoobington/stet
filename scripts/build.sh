#!/bin/bash
# Builds Stet into build/Stet.app (Debug, signed ad hoc for local use).
#   scripts/build.sh            build
#   scripts/build.sh --test     also run the StetCore tests first
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ "${1:-}" == "--test" ]]; then
  echo "▸ Testing StetCore"
  swift test --package-path StetCore 2>&1 | tail -3
fi

echo "▸ Generating Xcode project"
xcodegen generate --quiet

echo "▸ Building"
xcodebuild -project Stet.xcodeproj -scheme Stet -configuration Debug \
  -derivedDataPath build/DerivedData -quiet build

rm -rf build/Stet.app
cp -R build/DerivedData/Build/Products/Debug/Stet.app build/Stet.app
echo "✓ build/Stet.app"
