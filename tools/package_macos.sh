#!/usr/bin/env bash
# Build the macOS release app and wrap it into a .dmg + .zip.
# Unsigned by default. With SIGN_IDENTITY set (a "Developer ID Application: …" identity) the app is signed with the
# hardened runtime; with NOTARY_APPLE_ID / NOTARY_TEAM_ID / NOTARY_PASSWORD (app-specific password) it is also notarized
# and stapled, so Gatekeeper opens it without warnings.
set -euo pipefail
cd "$(dirname "$0")/../linkory-app"
# CI passes VERSION (from the tag); locally it is read from pubspec.yaml.
VERSION="${VERSION:-$(grep '^version:' pubspec.yaml | sed 's/version: *//; s/+.*//')}"
flutter build macos --release --build-name="${VERSION%%-*}" ${BUILD_ARGS:-} # numeric x.y.z only; the suffix stays in the file name
APP="build/macos/Build/Products/Release/连信 Linkory.app"
OUT=build/Linkory-${VERSION}-macos.dmg
ZIP=build/Linkory-${VERSION}-macos.zip
ENT=macos/Runner/Release.entitlements

notarize() { # file
  xcrun notarytool submit "$1" --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD" --wait --timeout 30m
}

if [ -n "${SIGN_IDENTITY:-}" ]; then
  echo "==> codesign (hardened runtime) with: $SIGN_IDENTITY"
  sign() { codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$@"; }
  # Inside-out: nested code first, the app bundle last. (No --deep: it signs with the wrong options.)
  while IFS= read -r f; do sign "$f"; done < <(find "$APP/Contents" \( -name '*.dylib' -o -name '*.so' \) -type f)
  while IFS= read -r f; do sign "$f"; done < <(find "$APP/Contents" \( -name '*.xpc' -o -name '*.app' -o -name '*.framework' \) -prune -not -path "$APP")
  sign --entitlements "$ENT" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
  if [ -n "${NOTARY_APPLE_ID:-}" ]; then
    echo "==> notarize app"
    tmpzip=$(mktemp -d)/app.zip
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$tmpzip"
    notarize "$tmpzip"
    xcrun stapler staple "$APP"
  fi
fi

STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/连信 Linkory.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT"
hdiutil create -volname "Linkory" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
rm -rf "$STAGE"
if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$OUT"
  if [ -n "${NOTARY_APPLE_ID:-}" ]; then
    echo "==> notarize dmg"
    notarize "$OUT"
    xcrun stapler staple "$OUT"
  fi
fi
# The in-app updater installs from a zip (ditto keeps the bundle intact); the dmg is for people.
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "$OUT"
echo "$ZIP"
