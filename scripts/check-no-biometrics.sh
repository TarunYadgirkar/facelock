#!/bin/bash
# Fails when git tracks (or, with --staged, is about to commit) face data: embedding dumps, model
# files, an enrollment, key or check log copied in, or any image outside the allowlist. README and
# UI screenshots come only from `FaceLock --demo-camera <public-domain image>`; the owner's camera
# never appears in a committed image.
#   scripts/check-no-biometrics.sh             every tracked file
#   scripts/check-no-biometrics.sh --staged    what the next commit adds (the pre-commit hook)
#   scripts/check-no-biometrics.sh --paths     paths on stdin (the tests use this)
set -euo pipefail
cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

case "${1:-}" in
  --staged) files=$(git diff --cached --name-only --diff-filter=ACMR) ;;
  --paths) files=$(cat) ;;
  *) files=$(git ls-files) ;;
esac

forbidden='\.(npz|npy|f16|f32|bin|pt|pth|safetensors|onnx|mlmodel|mlpackage|mlmodelc)(/|$)|(^|/)enrollment\.v2$|(^|/)checks[^/]*\.jsonl$|(^|/)dev\.key$'
# The one tracked embedding: ONNX Runtime's r50 output for the public-domain fixture photo.
allowed_data='^Tests/Fixtures/grace_hopper_r50\.f16$'
image='\.(png|jpe?g|gif|heic|heif|bmp|tiff?|webp|icns|raw|bgra|mov|mp4)$'
# UI screenshots: rendered by `FaceLock --demo-camera Tests/Fixtures/grace_hopper.jpg --snapshot <dir>` only.
allowed='^(Resources/Assets\.xcassets/|Resources/AppIcon\.icns$|Tests/Fixtures/grace_hopper\.jpg$|assets/generated/ui-[a-z0-9-]+\.png$)'

bad=0
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  if [[ "$f" =~ $forbidden ]] && ! [[ "$f" =~ $allowed_data ]]; then
    echo "check-no-biometrics: $f is an embedding, model, enrollment, key or check log; keep it out of git" >&2
    bad=1
  elif [[ "$f" =~ $image ]] && ! [[ "$f" =~ $allowed ]]; then
    echo "check-no-biometrics: $f is an image outside the allowlist (Resources/Assets, Tests/Fixtures/grace_hopper.jpg, assets/generated/ui-*.png)" >&2
    bad=1
  fi
done <<< "$files"
exit $bad
