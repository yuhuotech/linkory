#!/usr/bin/env bash
# Build the macOS release app and wrap it into a .dmg (unsigned; sign/notarize separately for distribution).
set -euo pipefail
cd "$(dirname "$0")/../linkory-app"
# CI passes VERSION (from the tag); locally it is read from pubspec.yaml.
VERSION="${VERSION:-$(grep '^version:' pubspec.yaml | sed 's/version: *//; s/+.*//')}"
flutter build macos --release --build-name="${VERSION%%-*}" ${BUILD_ARGS:-} # numeric x.y.z only; the suffix stays in the file name
APP="build/macos/Build/Products/Release/连信 Linkory.app"
OUT=build/Linkory-${VERSION}-macos.dmg
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/连信 Linkory.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT"
hdiutil create -volname "Linkory" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
rm -rf "$STAGE"
echo "$OUT"
