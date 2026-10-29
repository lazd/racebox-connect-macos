#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="$ROOT/macos/.build"
DIST="$ROOT/dist"
APP="$DIST/RaceBox Connect.app"

swift build --package-path "$ROOT/macos" --configuration release
BIN="$(swift build --package-path "$ROOT/macos" --configuration release --show-bin-path)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/RaceBoxConnect" "$APP/Contents/MacOS/RaceBoxConnect"
cp "$ROOT/macos/Info.plist" "$APP/Contents/Info.plist"
swift "$ROOT/macos/scripts/icon.swift" "$BUILD/AppIcon.iconset"
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

STAGING="$(mktemp -d "$BUILD/dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/RaceBox Connect.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "RaceBox Connect" -srcfolder "$STAGING" \
    -ov -format UDZO "$DIST/RaceBox Connect.dmg"
printf '\nBuilt %s\n' "$DIST/RaceBox Connect.dmg"
