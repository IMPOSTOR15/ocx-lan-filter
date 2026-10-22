#!/bin/sh
# Copies the built app to ~/Applications and starts it. Does not touch the running proxy service.
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$HERE/build/LAN Model Proxy.app"
DEST="$HOME/Applications/LAN Model Proxy.app"
[ -d "$SRC" ] || { echo "run scripts/build_app.sh first" >&2; exit 1; }
mkdir -p "$HOME/Applications"
pkill -x LanModelBar 2>/dev/null || true
sleep 0.5
rm -rf "$DEST"
cp -R "$SRC" "$DEST"
open "$DEST"
echo "installed: $DEST"
