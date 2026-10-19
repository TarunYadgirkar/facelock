#!/usr/bin/env bash
set -euo pipefail

# Renders the UI screenshots in assets/generated/ui-*.png from the app's own views. The app runs on the
# demo camera with Tests/Fixtures/grace_hopper.jpg (public domain), walks through setup, watching,
# leaving and the countdown, and never locks. No screen capture and no real camera are involved, so
# the owner's camera can never appear in a committed image.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/FaceLock.app"
OUT="$ROOT/assets/generated"
[[ -x "$APP/Contents/MacOS/FaceLock" ]] || "$ROOT/scripts/build-app.sh"
mkdir -p "$OUT"
DATA="$(mktemp -d)"
trap 'rm -rf "$DATA"' EXIT
"$APP/Contents/MacOS/FaceLock" --demo-camera "$ROOT/Tests/Fixtures/grace_hopper.jpg" --snapshot "$OUT" --data-dir "$DATA"
