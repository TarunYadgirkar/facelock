#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

PY=${PYTHON:-python3.11}
ZOO=https://github.com/opencv/opencv_zoo/raw/main/models

command -v "$PY" >/dev/null || { echo "need $PY (brew install python@3.11)"; exit 1; }

[ -d .venv ] || "$PY" -m venv .venv
.venv/bin/pip install -q --upgrade pip
.venv/bin/pip install -q -e ".[menubar,dev]"

mkdir -p models
fetch() {
  [ -f "models/$1" ] || { echo "downloading $1"; curl -sSLf -o "models/$1" "$ZOO/$2/$1"; }
}
fetch face_detection_yunet_2023mar.onnx face_detection_yunet
fetch face_recognition_sface_2021dec.onnx face_recognition_sface

.venv/bin/python -m pytest -q

cat <<'MSG'

ready. next:
  .venv/bin/facelock enroll     # capture your face
  .venv/bin/facelock test       # check the match scores
  .venv/bin/facelock watch      # arm it
MSG
