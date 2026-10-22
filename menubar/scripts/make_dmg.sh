#!/bin/sh
# Builds a universal, ad-hoc signed app and packs it into build/LAN-Model-Proxy-<version>.dmg.
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-1.0.0}"
export VERSION UNIVERSAL=1

"$HERE/scripts/build_app.sh"

STAGE="$HERE/build/dmg"
DMG="$HERE/build/LAN-Model-Proxy-$VERSION.dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$HERE/build/LAN Model Proxy.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "LAN Model Proxy" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "dmg: $DMG"
shasum -a 256 "$DMG"
