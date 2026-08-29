#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

PY=${PYTHON:-python3.11}
command -v "$PY" >/dev/null || { echo "need $PY (brew install python@3.11)"; exit 1; }

[ -d .venv ] || "$PY" -m venv .venv
.venv/bin/pip install -q --upgrade pip
.venv/bin/pip install -q -e ".[menubar,dev]"

.venv/bin/python -m pytest -q

cat <<'MSG'

ready. next:
  .venv/bin/facelock enroll        # capture your face (downloads the models on first use)
  .venv/bin/facelock test          # check the match scores
  .venv/bin/facelock install-app   # FaceLock.app in ~/Applications
MSG
