#!/usr/bin/env bash
# Validate the plugin: manifest schema plus QML lint against the shell's
# import path. Run from anywhere.
set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}"
status=0

omarchy plugin validate "$SRC" || status=1

# The qt6 qmllint is required; a legacy Qt5 `qmllint 1.0` on PATH exits 255
# without output. One file per invocation keeps failures attributable.
QMLLINT="${QMLLINT:-/usr/lib/qt6/bin/qmllint}"
command -v "$QMLLINT" >/dev/null || QMLLINT=qmllint
for qml in "$SRC"/*.qml; do
  [[ -e "$qml" ]] || continue
  "$QMLLINT" -I "$OMARCHY_PATH/shell" "$qml" || status=1
done

if command -v node >/dev/null && [[ -f "$SRC/tests/model.test.js" ]]; then
  node "$SRC/tests/model.test.js" || status=1
fi

exit "$status"
