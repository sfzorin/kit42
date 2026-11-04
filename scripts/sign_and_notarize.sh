#!/bin/zsh
# Signs the apps with your Developer ID and notarizes them with Apple, so they open on any Mac
# without warnings. Requires a paid Apple Developer account.
#
# One-time setup:
#   1. Xcode → Settings → Accounts, or developer.apple.com: create a "Developer ID Application" certificate
#      (it appears in your login Keychain).
#   2. Store notarization credentials (app-specific password from appleid.apple.com):
#        xcrun notarytool store-credentials suite42 --apple-id YOU@EXAMPLE.COM --team-id TEAMID
#
# Usage:  DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" ./scripts/sign_and_notarize.sh [PDF42 DOC42 XLS42]
set -euo pipefail
cd "$(dirname "$0")/.."
: "${DEVELOPER_ID:?Set DEVELOPER_ID to your 'Developer ID Application: …' identity}"
PROFILE=${NOTARY_PROFILE:-suite42}
APPS=(${@:-PDF42 DOC42 XLS42})

./build.sh
mkdir -p build/dist
for APP in $APPS; do
  BUNDLE="build/$APP.app"
  echo "== $APP: signing"
  # Quick Look extensions first, with their sandbox entitlements; then the app (not --deep, which would drop them).
  for X in "$BUNDLE"/Contents/PlugIns/*.appex(N); do
    codesign --force --options runtime --timestamp --entitlements Resources/QuickLook/Extension.entitlements --sign "$DEVELOPER_ID" "$X"
  done
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$BUNDLE"
  codesign --verify --deep --strict --verbose=2 "$BUNDLE"
  ZIP="build/dist/$APP.zip"
  ditto -c -k --keepParent "$BUNDLE" "$ZIP"
  echo "== $APP: notarizing (a few minutes)"
  xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$BUNDLE"
  rm "$ZIP"
  ditto -c -k --keepParent "$BUNDLE" "$ZIP"
  spctl --assess --type execute --verbose "$BUNDLE"
  echo "== $APP: ready → $ZIP"
done
