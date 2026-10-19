#!/bin/bash
# Fails when git tracks (or, with --staged, is about to commit) face data: embedding dumps, model
# files, or any image outside the allowlist. README and UI screenshots come only from
# `FaceLock --demo-camera <public-domain image>`; the owner's camera never appears in a committed image.
set -euo pipefail
cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

if [[ "${1:-}" == "--staged" ]]; then
  files=$(git diff --cached --name-only --diff-filter=ACMR)
else
  files=$(git ls-files)
fi

forbidden='\.(npz|npy|f32|onnx|mlmodel|mlpackage|mlmodelc)(/|$)'
image='\.(png|jpe?g|gif|heic|heif|bmp|tiff?|webp|icns|raw|bgra|mov|mp4)$'
# UI screenshots: rendered by `FaceLock --demo-camera Tests/Fixtures/grace_hopper.jpg --snapshot <dir>` only.
allowed='^(Resources/Assets\.xcassets/|Resources/AppIcon\.icns$|Tests/Fixtures/grace_hopper\.jpg$|docs/img/|assets/generated/ui-[a-z0-9-]+\.png$)'

bad=0
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  if [[ "$f" =~ $forbidden ]]; then
    echo "check-no-biometrics: $f is an embedding or model file; keep it out of git" >&2
    bad=1
  elif [[ "$f" =~ $image ]] && ! [[ "$f" =~ $allowed ]]; then
    echo "check-no-biometrics: $f is an image outside the allowlist (Resources/Assets, Tests/Fixtures/grace_hopper.jpg, docs/img/, assets/generated/ui-*.png)" >&2
    bad=1
  fi
done <<< "$files"
exit $bad
