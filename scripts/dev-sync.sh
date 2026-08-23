#!/usr/bin/env bash
# Sync the working tree into the Omarchy plugin directory. The shell
# hot-reloads plugin code on save, so a sync is all a dev iteration needs.
# Usage: scripts/dev-sync.sh [--watch]
set -euo pipefail

PLUGIN_ID="io.github.dominicboettger.prompter"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$HOME/.config/omarchy/plugins/$PLUGIN_ID"

sync_once() {
  mkdir -p "$DEST"
  rsync -a --delete \
    --exclude '.git' \
    --exclude 'scripts' \
    --exclude 'tests' \
    --exclude 'preview.png' \
    "$SRC/" "$DEST/"
  omarchy-shell -q shell rescanPlugins || true
  echo "synced -> $DEST"
}

sync_once

if [[ "${1:-}" == "--watch" ]]; then
  command -v inotifywait >/dev/null || {
    echo "inotifywait missing (omarchy pkg add inotify-tools)" >&2
    exit 1
  }
  while inotifywait -qq -r -e modify,create,delete,move \
    --exclude '(\.git|scripts)/' "$SRC"; do
    sync_once
  done
fi
