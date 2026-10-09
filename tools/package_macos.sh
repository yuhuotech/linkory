#!/usr/bin/env bash
# Build the macOS release app and wrap it into a .dmg (unsigned; sign/notarize separately for distribution).
set -euo pipefail
cd "$(dirname "$0")/../linkory-app"
flutter build macos --release
APP="build/macos/Build/Products/Release/连信 Linkory.app"
VERSION=$(grep '^version:' pubspec.yaml | sed 's/version: *//; s/+.*//')
OUT=build/Linkory-${VERSION}-macos.dmg
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/Linkory.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT"
hdiutil create -volname "Linkory" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
rm -rf "$STAGE"
echo "$OUT"
