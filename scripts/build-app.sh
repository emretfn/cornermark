#!/bin/bash
# Builds a development app by default, or the release app with --release.
#   scripts/build-app.sh [--release] [--universal] [--no-sign]
# Development: build/Cornermark Dev.app, its own bundle ID, signed with scripts/make-dev-signing-cert.sh.
# Release: build/Cornermark.app, signed with CORNERMARK_SIGN_IDENTITY, or ad-hoc when that is not set.
# Version: version.txt. --universal builds arm64 and x86_64 into one binary.
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
        -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

if [ "$CONFIG" = release ]; then
    APP_NAME="Cornermark"
    BUNDLE_ID="local.emretufan.cornermark"
    URL_SCHEME="cornermark"
    ICON_ARGS=()
else
    APP_NAME="Cornermark Dev"
    BUNDLE_ID="local.emretufan.cornermark.dev"
    URL_SCHEME="cornermark-dev"
    ICON_ARGS=(--dev)
fi
VERSION="$(tr -d '[:space:]' < "$ROOT/version.txt")"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
APP="$ROOT/build/$APP_NAME.app"

cd "$ROOT"
echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG" --product Cornermark ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/Cornermark"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Cornermark"

ICON_CACHE="$ROOT/build/cache/$APP_NAME.icns"
if [ ! -f "$ICON_CACHE" ] || [ "$ROOT/scripts/make-icon.swift" -nt "$ICON_CACHE" ]; then
    echo "==> generating app icon"
    swift "$ROOT/scripts/make-icon.swift" "$ICON_CACHE" ${ICON_ARGS[@]+"${ICON_ARGS[@]}"}
fi
cp "$ICON_CACHE" "$APP/Contents/Resources/Cornermark.icns"

sed -e "s/__APP_NAME__/${APP_NAME}/g" -e "s/__URL_SCHEME__/${URL_SCHEME}/g" -e "s/__BUNDLE_ID__/${BUNDLE_ID}/g" -e "s/__VERSION__/${VERSION}/g" -e "s/__BUILD__/${BUILD_NUMBER}/g" \
    "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"

if [ "$SIGN" -eq 0 ]; then
    echo "==> --no-sign: bundle left unsigned (only the linker's ad-hoc signature on the executable)."
    echo "    macOS ties the Screen Recording grant to the signature, so sign before relying on it."
    echo "built $APP"
    exit 0
fi

if [ "$CONFIG" = release ]; then
    IDENTITY="${CORNERMARK_SIGN_IDENTITY:-}"
    if [ -z "$IDENTITY" ]; then
        echo "WARNING: CORNERMARK_SIGN_IDENTITY is not set, signing ad-hoc. Only the release certificate can update an installed app." >&2
        IDENTITY="-"
    fi
else
    # The certificate is self-signed and untrusted, so find-identity -v would hide it.
    IDENTITY="$(security find-identity -p codesigning | awk '/"Cornermark Dev Self-Signed"/ { print $2; exit }')"
    if [ -z "$IDENTITY" ]; then
        echo "No development certificate. Run scripts/make-dev-signing-cert.sh once." >&2
        exit 1
    fi
fi

echo "==> signing with identity $IDENTITY (hardened runtime off, no sandbox)"
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
codesign --verify --verbose=2 "$APP"
echo "built $APP"
