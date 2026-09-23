#!/usr/bin/env bash
# Builds Claudon, puts it in /Applications (or ~/Applications) and starts it.
set -euo pipefail

cd "$(dirname "$0")/.."
./scripts/build-app.sh

DEST="/Applications"
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"

# Replace a running copy.
if pgrep -x Claudon >/dev/null; then
    pkill -x Claudon || true
    while pgrep -x Claudon >/dev/null; do sleep 0.2; done
fi
# Update the bundle in place: deleting it first, even briefly, makes macOS drop any Claudon
# widgets from the desktop.
mkdir -p "$DEST/Claudon.app"
rsync -a --delete build/Claudon.app/ "$DEST/Claudon.app/"
open "$DEST/Claudon.app"
echo "Installed $DEST/Claudon.app"
