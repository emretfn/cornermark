#!/bin/bash
# Builds build/Cornermark.dmg: a universal release build in a drag-to-Applications installer window.
#   scripts/build-dmg.sh
# Needs pipx, which runs dmgbuild. Signing follows build-app.sh, so set CORNERMARK_SIGN_IDENTITY=- for an ad-hoc signature.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Cornermark.app"
DMG="$ROOT/build/Cornermark.dmg"
BACKGROUND="$ROOT/build/cache/dmg-background.png"

"$ROOT/scripts/build-app.sh" --release --universal

if [ ! -f "$BACKGROUND" ] || [ "$ROOT/scripts/make-dmg-background.swift" -nt "$BACKGROUND" ]; then
    echo "==> generating installer background"
    swift "$ROOT/scripts/make-dmg-background.swift" "$BACKGROUND"
fi

echo "==> building $DMG"
rm -f "$DMG"
pipx run dmgbuild==1.6.7 -s "$ROOT/scripts/dmg-settings.py" \
    -D app="$APP" -D icns="$APP/Contents/Resources/Cornermark.icns" -D background="$BACKGROUND" \
    Cornermark "$DMG"
hdiutil verify "$DMG"
echo "built $DMG"
