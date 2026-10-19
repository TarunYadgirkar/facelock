#!/usr/bin/env bash
set -euo pipefail

# Builds build/FaceLock.app: the release binary, YuNet compiled from models/YuNet320x240.mlpackage, the
# r50 recognizer WITHOUT its weights (ArcFaceR50.skeleton plus Resources/ArcFaceR50.layout.json; the app
# downloads the weights from InsightFace and rebuilds weight.bin on the user's Mac), the icon and the
# accent colour, signed for this team. python -I tools/convert_models.py makes models/.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/FaceLock.app"
TEAM_ID="5AKJYZ7USP"
MODELS=(YuNet320x240)
RECOGNIZER=ArcFaceR50
LAYOUT="Resources/$RECOGNIZER.layout.json"

# Developer ID can be notarized and shipped; Apple Development runs on this Mac; ad-hoc runs here only,
# and an ad-hoc build loses its camera permission and keychain access on every rebuild.
# An identity's name carries a certificate ID, not always the team, so the team is read from the certificate's OU.
belongs_to_team() {
  security find-certificate -c "$1" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | grep -q "OU *= *$TEAM_ID"
}

signing_identity() {
  if [[ -n "${FACELOCK_SIGN_IDENTITY:-}" ]]; then
    [[ "$FACELOCK_SIGN_IDENTITY" == "-" ]] || belongs_to_team "$FACELOCK_SIGN_IDENTITY" || { echo "FACELOCK_SIGN_IDENTITY must belong to team $TEAM_ID" >&2; exit 1; }
    echo "$FACELOCK_SIGN_IDENTITY"
    return
  fi
  local identities name
  identities="$(security find-identity -v -p codesigning)"
  for kind in "Developer ID Application" "Apple Development"; do
    while IFS= read -r name; do
      if [[ -n "$name" ]] && belongs_to_team "$name"; then echo "$name"; return; fi
    done < <(grep "\"$kind: " <<<"$identities" | sed -E 's/.*"(.*)"/\1/')
  done
  echo "No signing certificate for team $TEAM_ID; signing ad-hoc." >&2
  echo "-"
}

cd "$ROOT"
for m in "${MODELS[@]}" "$RECOGNIZER"; do
  [[ -d "models/$m.mlpackage" ]] || { echo "models/$m.mlpackage is missing. Run: python -I tools/convert_models.py" >&2; exit 1; }
done

swift build -c release --arch arm64 --product FaceLock
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/FaceLock" "$APP/Contents/MacOS/FaceLock"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
xcrun actool Resources/Assets.xcassets --compile "$APP/Contents/Resources" \
  --platform macosx --minimum-deployment-target 15.0 --output-format human-readable-text >/dev/null
for m in "${MODELS[@]}"; do
  xcrun coremlcompiler compile "models/$m.mlpackage" "$APP/Contents/Resources" >/dev/null
done
cp Resources/THIRD_PARTY_NOTICES.txt "$APP/Contents/Resources/"

# The recognizer ships as its compiled graph only. The layout must describe exactly the weight.bin this
# skeleton was compiled with, or the app's rebuilt model would not match the tested one.
COMPILED="$(mktemp -d)"
trap 'rm -rf "$COMPILED"' EXIT
xcrun coremlcompiler compile "models/$RECOGNIZER.mlpackage" "$COMPILED" >/dev/null
want="$(plutil -extract weights.sha256 raw -o - "$LAYOUT")"
got="$(shasum -a 256 "$COMPILED/$RECOGNIZER.mlmodelc/weights/weight.bin" | cut -d' ' -f1)"
[[ "$got" == "$want" ]] || { echo "$LAYOUT is stale (weight.bin $got, layout $want). Run: python -I tools/convert_models.py" >&2; exit 1; }
rm -rf "$COMPILED/$RECOGNIZER.mlmodelc/weights"
cp -R "$COMPILED/$RECOGNIZER.mlmodelc" "$APP/Contents/Resources/$RECOGNIZER.skeleton"
cp "$LAYOUT" "$APP/Contents/Resources/"

# Licence guard: no r50 weights in any form may reach the app (and so the DMG).
leaked="$(find "$APP" \( -name 'weight.bin' -path "*$RECOGNIZER*" -o -name '*.onnx' -o -name "$RECOGNIZER.mlmodelc" -o -name '*.mlpackage' \) -print)"
[[ -z "$leaked" ]] || { echo "Refusing to ship r50 weights: $leaked" >&2; exit 1; }

IDENTITY="$(signing_identity)"
SIGN_FLAGS=(--force --sign "$IDENTITY" --entitlements Resources/FaceLock.entitlements)
[[ "$IDENTITY" != "-" ]] && SIGN_FLAGS+=(--options runtime --timestamp)
codesign "${SIGN_FLAGS[@]}" "$APP" >/dev/null
codesign --verify --strict --deep "$APP"
echo "Signed with: $IDENTITY"
echo "$APP"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/FaceLock.app
  cp -R "$APP" /Applications/FaceLock.app
  echo "Installed to /Applications/FaceLock.app"
fi
