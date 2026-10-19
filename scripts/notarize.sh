#!/usr/bin/env bash
set -euo pipefail

# Builds FaceLock with a Developer ID signature, sends it to Apple's notary service, staples the ticket,
# and leaves build/FaceLock.dmg (drag FaceLock into Applications). Other Macs then open it without a Gatekeeper warning.
#
# Licence: the DMG holds no InsightFace w600k_r50 weights (non-commercial research only), so it can be
# published. build-app.sh ships the recognizer's graph without weights and refuses to build if any r50
# weights reach the app; each user downloads them from InsightFace on first run. YuNet (MIT) is bundled,
# with its notice in THIRD_PARTY_NOTICES.txt. See README > Licences.
#
# One-time setup on this Mac. The notary profile belongs to the Apple developer account, not to one app, so any saved profile for team 5AKJYZ7USP works (herd-notary is the one on this Mac):
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
# hdiutil's own estimate for an APFS image from a folder runs short ("No space left on device"), so size it:
# the app plus 30% and 32 MB of headroom.
SIZE_MB=$(( $(du -sm "$STAGING/FaceLock.app" | cut -f1) * 13 / 10 + 32 ))
hdiutil create -volname FaceLock -srcfolder "$STAGING" -fs APFS -format ULFO -size "${SIZE_MB}m" -ov "$DMG" >/dev/null
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"
echo "$DMG"
