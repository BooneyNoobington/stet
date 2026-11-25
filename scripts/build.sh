#!/bin/bash
# Builds Zadur into build/Zadur.app (Debug, signed ad hoc for local use).
#   scripts/build.sh            build
#   scripts/build.sh --test     also run the ZadurCore tests first
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ "${1:-}" == "--test" ]]; then
  echo "▸ Testing ZadurCore"
  swift test --package-path ZadurCore 2>&1 | tail -3
fi

echo "▸ Generating Xcode project"
xcodegen generate --quiet

echo "▸ Building"
xcodebuild -project Zadur.xcodeproj -scheme Zadur -configuration Debug \
  -derivedDataPath build/DerivedData -quiet build

rm -rf build/Zadur.app
cp -R build/DerivedData/Build/Products/Debug/Zadur.app build/Zadur.app
echo "✓ build/Zadur.app"
