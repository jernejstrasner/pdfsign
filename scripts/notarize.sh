#!/usr/bin/env bash
# Build a Release PDFSign.app, sign it with Developer ID + Hardened Runtime,
# notarize via asc (Apple Notary API), staple the ticket, and verify.
#
# Prereqs: xcodegen, a "Developer ID Application" cert in the keychain, and asc
# logged in (check with `asc doctor`). PoDoFo must already be built into vendor/
# (run scripts/build-podofo.sh once).
set -euo pipefail

cd "$(dirname "$0")/.."

APP="build/Build/Products/Release/PDFSign.app"
ZIP="dist/PDFSign.zip"

echo "==> Generating Xcode project"
xcodegen generate

echo "==> Building Release (Developer ID + Hardened Runtime)"
xcodebuild -scheme PDFSign -configuration Release -derivedDataPath build clean build | tail -5

echo "==> Verifying code signature"
codesign --verify --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -Ei "Authority|TeamIdentifier|flags|Timestamp" || true

echo "==> Zipping for notarization"
mkdir -p dist
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Submitting to Apple Notary (asc), waiting for result"
asc notarization submit --file "$ZIP" --wait --output table

echo "==> Stapling ticket to the app"
xcrun stapler staple "$APP"

echo "==> Re-zipping the stapled app for distribution"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Gatekeeper assessment"
spctl -a -vvv -t exec "$APP"
xcrun stapler validate "$APP"

echo "==> Done: $ZIP"
