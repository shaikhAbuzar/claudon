#!/usr/bin/env bash
# Quits Claudon and removes the app, its settings and its usage history.
set -euo pipefail

pkill -x Claudon 2>/dev/null || true
for dir in /Applications "$HOME/Applications"; do
    rm -rf "$dir/Claudon.app"
done
rm -rf "$HOME/Library/Application Support/Claudon"
# The widget's sandbox container; macOS may protect it, in which case it stays.
rm -rf "$HOME/Library/Containers/app.claudon.Claudon.Widget" 2>/dev/null || true
defaults delete app.claudon.Claudon 2>/dev/null || true
echo "Claudon removed. If it still shows under System Settings > General > Login Items, remove it there."
