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
rm -rf "$DEST/Claudon.app"
cp -R build/Claudon.app "$DEST/"
open "$DEST/Claudon.app"
echo "Installed $DEST/Claudon.app"
