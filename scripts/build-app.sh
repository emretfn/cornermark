#!/bin/bash
# Builds build/Cornermark.app.
#   scripts/build-app.sh [--release] [--universal] [--no-sign]
# Version: version.txt. --universal builds arm64 and x86_64 into one binary.
# Signing identity: CORNERMARK_SIGN_IDENTITY if set, else the first "Apple Development" identity.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG=debug
SIGN=1
ARCHS=()
for arg in "$@"; do
    case "$arg" in
        --release) CONFIG=release ;;
        --universal) ARCHS=(--arch arm64 --arch x86_64) ;;
        --no-sign) SIGN=0 ;;
        -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

BUNDLE_ID="local.emretufan.cornermark"
VERSION="$(tr -d '[:space:]' < "$ROOT/version.txt")"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
APP="$ROOT/build/Cornermark.app"

cd "$ROOT"
echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG" --product Cornermark ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/Cornermark"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Cornermark"

ICON_CACHE="$ROOT/build/cache/Cornermark.icns"
if [ ! -f "$ICON_CACHE" ] || [ "$ROOT/scripts/make-icon.swift" -nt "$ICON_CACHE" ]; then
    echo "==> generating app icon"
    swift "$ROOT/scripts/make-icon.swift" "$ICON_CACHE"
fi
cp "$ICON_CACHE" "$APP/Contents/Resources/Cornermark.icns"

sed -e "s/__BUNDLE_ID__/${BUNDLE_ID}/g" -e "s/__VERSION__/${VERSION}/g" -e "s/__BUILD__/${BUILD_NUMBER}/g" \
    "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"

if [ "$SIGN" -eq 0 ]; then
    echo "==> --no-sign: bundle left unsigned (only the linker's ad-hoc signature on the executable)."
    echo "    macOS ties the Screen Recording grant to the signature, so sign before relying on it."
    echo "built $APP"
    exit 0
fi

IDENTITY="${CORNERMARK_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    # The certificate's SHA-1 hash is unambiguous even when several certificates share a name.
    IDENTITY="$(security find-identity -v -p codesigning | awk '/Apple Development/ { print $2; exit }')"
fi

if [ -n "$IDENTITY" ]; then
    echo "==> signing with identity $IDENTITY (hardened runtime off, no sandbox)"
    codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
else
    cat >&2 <<WARN
WARNING: no "Apple Development" signing identity found, falling back to ad-hoc signing.
         An ad-hoc signature changes with every build, so macOS forgets the Screen Recording
         permission each time you rebuild and you have to grant it again.
         Create a free Apple Development certificate in Xcode (Settings > Accounts > Manage
         Certificates) or set CORNERMARK_SIGN_IDENTITY to a certificate hash.
WARN
    codesign --force --sign - "$APP"
fi
codesign --verify --verbose=2 "$APP"
echo "built $APP"
