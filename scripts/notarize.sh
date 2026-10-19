#!/usr/bin/env bash
set -euo pipefail

# Builds FaceLock with a Developer ID signature, sends it to Apple's notary service, staples the ticket,
# and leaves build/FaceLock.dmg (drag FaceLock into Applications). Other Macs then open it without a Gatekeeper warning.
#
# Licence: the DMG bundles the InsightFace w600k_r50 weights, which are for non-commercial research only.
# A personal or private copy is fine; publishing the DMG redistributes them. See README > Licences.
#
# One-time setup on this Mac (FaceLock shares herd's team and Apple ID, so herd's stored profile works):
#   1. Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application
#   2. xcrun notarytool store-credentials herd-notary --apple-id <apple id> --team-id 5AKJYZ7USP
#      (asks for an app-specific password from account.apple.com)

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/FaceLock.app"
ZIP="$ROOT/build/FaceLock.zip"
DMG="$ROOT/build/FaceLock.dmg"
PROFILE="${FACELOCK_NOTARY_PROFILE:-herd-notary}"

IDENTITY="$(security find-identity -v -p codesigning | grep '"Developer ID Application: .*(5AKJYZ7USP)"' | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"
if [[ -z "$IDENTITY" ]]; then
  echo "No Developer ID Application certificate for team 5AKJYZ7USP. Create one in Xcode first (see the top of this script)." >&2
  exit 1
fi

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "No notary credentials saved as \"$PROFILE\". Run step 2 at the top of this script first." >&2
  exit 1
fi

FACELOCK_SIGN_IDENTITY="$IDENTITY" "$ROOT/scripts/build-app.sh"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"
spctl --assess --type execute --verbose "$APP"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/FaceLock.app"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname FaceLock -srcfolder "$STAGING" -fs APFS -format ULFO -ov "$DMG" >/dev/null
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"
echo "$DMG"
