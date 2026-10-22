#!/bin/sh
# Builds "LAN Model Proxy.app" into menubar/build/ (ad-hoc signed, no Dock icon).
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
APP="$HERE/build/LAN Model Proxy.app"
CONFIG="${CONFIG:-release}"
VERSION="${VERSION:-1.1.0}"
# UNIVERSAL=1 builds a fat arm64 + x86_64 binary (used for releases).
ARCHS=""
if [ "${UNIVERSAL:-0}" = "1" ]; then ARCHS="--arch arm64 --arch x86_64"; fi

cd "$HERE"
# shellcheck disable=SC2086
swift build -c "$CONFIG" $ARCHS --product LanModelBar
# shellcheck disable=SC2086
BIN="$(swift build -c "$CONFIG" $ARCHS --show-bin-path)/LanModelBar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/service/launchd"
cp "$BIN" "$APP/Contents/MacOS/LanModelBar"

# The bundled service files are what "Install/Update service" runs (install.sh is idempotent).
cp "$REPO/filter.py" "$REPO/lanmodel" "$REPO/install.sh" "$APP/Contents/Resources/service/"
cp "$REPO"/launchd/*.template "$APP/Contents/Resources/service/launchd/"
chmod +x "$APP/Contents/Resources/service/install.sh" "$APP/Contents/Resources/service/lanmodel"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.local.lanmodelbar</string>
  <key>CFBundleName</key><string>LAN Model Proxy</string>
  <key>CFBundleDisplayName</key><string>LAN Model Proxy</string>
  <key>CFBundleExecutable</key><string>LanModelBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

codesign --force --sign - "$APP" >/dev/null
echo "built: $APP"
