#!/bin/bash
# Writes THIRD-PARTY-NOTICES.md: the licenses of everything built into Zadur.app
# (the editor's npm packages without dev tools, Yams and the libYAML it contains).
# Run after changing dependencies: scripts/third-party-notices.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="THIRD-PARTY-NOTICES.md"
YAMS="ZadurCore/.build/checkouts/Yams"
LIBYAML_LICENSE="${LIBYAML_LICENSE:-$(ls /opt/homebrew/Cellar/libyaml/*/License 2>/dev/null | tail -1)}"

[[ -d editor/node_modules ]] || (cd editor && npm ci --silent)
[[ -f "$YAMS/LICENSE" ]] || swift package --package-path ZadurCore resolve

{
  echo "# Third-party notices"
  echo
  echo "Zadur is licensed under the GNU General Public License v3.0 or later (see LICENSE)."
  echo "Zadur.app contains the following components, each under its own license."
  echo "Pandoc (GPL-2.0-or-later), Typst (Apache-2.0) and git are separate programs that Zadur runs;"
  echo "on request Zadur downloads Pandoc's and Typst's official releases from their projects."
  echo "They are not part of Zadur."
  echo
  echo "## Editor (bundled into Zadur.app/Contents/Resources/Editor)"
  (cd editor && npm ls --omit=dev --all --parseable 2>/dev/null | tail -n +2 | sort -u) | while read -r dir; do
    name=$(python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); print(p["name"], p["version"], "–", p.get("license"))' "$dir/package.json")
    license=$(ls "$dir"/LICENSE* "$dir"/LICENCE* "$dir"/license* 2>/dev/null | head -1 || true)
    echo
    echo "### $name"
    echo
    if [[ -n "$license" ]]; then
      echo '```'
      cat "$license"
      echo '```'
    else
      echo "(No license file in the package; license as declared above.)"
    fi
  done
  SPARKLE="build/DerivedData/SourcePackages/checkouts/Sparkle"
  [[ -f "$SPARKLE/LICENSE" ]] || ./scripts/build.sh >/dev/null
  echo
  echo "## Sparkle (Zadur.app/Contents/Frameworks) – updates"
  echo
  echo "$(git -C "$SPARKLE" describe --tags 2>/dev/null || echo "") – MIT, https://sparkle-project.org"
  echo
  echo '```'
  cat "$SPARKLE/LICENSE"
  echo '```'
  echo
  echo "## Yams (compiled into Zadur)"
  echo
  echo "$(git -C "$YAMS" describe --tags 2>/dev/null || echo "") – MIT, https://github.com/jpsim/Yams"
  echo
  echo '```'
  cat "$YAMS/LICENSE"
  echo '```'
  echo
  echo "### libYAML (contained in Yams) – MIT, https://github.com/yaml/libyaml"
  echo
  echo '```'
  if [[ -n "$LIBYAML_LICENSE" && -f "$LIBYAML_LICENSE" ]]; then cat "$LIBYAML_LICENSE"; else echo "MIT License (see https://github.com/yaml/libyaml/blob/master/License)"; fi
  echo '```'
} > "$OUT"
echo "✓ $OUT"
