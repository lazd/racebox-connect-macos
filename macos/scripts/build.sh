#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="$ROOT/macos/.build"
DIST="$ROOT/dist"
APP="$DIST/RaceBox Connect.app"

if [[ $# -gt 1 || ($# -eq 1 && "$1" != "--app-only") ]]; then
    printf 'Usage: %s [--app-only]\n' "$0" >&2
    exit 1
fi

swift build --package-path "$ROOT/macos" --configuration release
BIN="$(swift build --package-path "$ROOT/macos" --configuration release --show-bin-path)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/RaceBoxConnect" "$APP/Contents/MacOS/RaceBoxConnect"
cp "$ROOT/macos/Info.plist" "$APP/Contents/Info.plist"
swift "$ROOT/macos/scripts/icon.swift" "$BUILD/AppIcon.iconset"
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$APP/Contents/Resources/AppIconBow.icns"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

if [[ "${1:-}" == "--app-only" ]]; then
    printf '\nBuilt %s\n' "$APP"
    exit 0
fi

STAGING="$(mktemp -d "$BUILD/dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/RaceBox Connect.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "RaceBox Connect" -srcfolder "$STAGING" \
    -ov -format UDZO "$DIST/RaceBoxConnect.dmg"
printf '\nBuilt %s\n' "$DIST/RaceBoxConnect.dmg"
