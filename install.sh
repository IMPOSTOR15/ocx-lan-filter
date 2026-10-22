#!/bin/sh
# Idempotent installer. Safe to re-run after editing filter.py or lanmodel.
# Never overwrites an existing key or config.json.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="$HOME/.local/share/ocx-lan-filter"
BIN_DIR="$HOME/.local/bin"
LABEL="com.local.ocx-lan-filter"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
# GUI apps start with a minimal PATH, so look in the usual places too.
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/Library/Frameworks/Python.framework/Versions/Current/bin"
PYTHON="$(command -v python3 || true)"
if [ -z "$PYTHON" ]; then echo "python3 not found: install Python 3 (https://www.python.org/downloads/ or 'brew install python')" >&2; exit 1; fi

mkdir -p "$STATE_DIR" "$BIN_DIR" "$HOME/Library/LaunchAgents"

# Copy, not symlink: launchd agents are often denied access to ~/Documents (macOS TCC).
cp "$HERE/filter.py" "$STATE_DIR/filter.py"
cp "$HERE/lanmodel" "$BIN_DIR/lanmodel"
chmod +x "$BIN_DIR/lanmodel"

if [ ! -f "$STATE_DIR/key" ]; then
  "$PYTHON" -c "import secrets;print('lan_'+secrets.token_urlsafe(32),end='')" > "$STATE_DIR/key"
  chmod 600 "$STATE_DIR/key"
  echo "generated new key: $STATE_DIR/key"
fi

if [ ! -f "$STATE_DIR/config.json" ]; then
  # Pick the first model ocx currently serves; fall back to a placeholder to be changed later.
  FIRST_MODEL="$("$PYTHON" - <<'PYEOF' 2>/dev/null || true
import json, urllib.request
try:
    d = json.load(urllib.request.urlopen("http://127.0.0.1:10100/v1/models", timeout=3))
    print(d["data"][0]["id"], end="")
except Exception:
    pass
PYEOF
)"
  "$PYTHON" -c 'import json,sys;print(json.dumps({"upstream_model": sys.argv[1] or "unset/choose-a-model"}))' "$FIRST_MODEL" > "$STATE_DIR/config.json"
  echo "created default config.json (model: ${FIRST_MODEL:-unset, choose one with lanmodel or the menu bar app})"
fi

sed -e "s#__PYTHON__#$PYTHON#g" -e "s#__STATE_DIR__#$STATE_DIR#g" \
  "$HERE/launchd/$LABEL.plist.template" > "$PLIST"
plutil -lint "$PLIST" >/dev/null

DOMAIN="gui/$(id -u)"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
# bootout is asynchronous: wait until the service is really gone, then retry bootstrap.
i=0
while launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 && [ "$i" -lt 20 ]; do sleep 0.25; i=$((i+1)); done
n=0
until launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null; do
  n=$((n+1))
  if [ "$n" -ge 5 ]; then echo "launchctl bootstrap failed after $n attempts" >&2; exit 1; fi
  sleep 1
done
sleep 1
echo "installed. listening check:"
lsof -nP -iTCP:10200 -sTCP:LISTEN | tail -1 || true
echo "current model: $("$BIN_DIR/lanmodel" show)"
