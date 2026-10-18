"""Record the Vision test references for Tests/Fixtures/grace_hopper.jpg (public domain, US Navy) with
implementations independent of FaceLock's Core ML models:

  grace_hopper_reference.json  OpenCV FaceDetectorYN (fp32) on the exact 320x240 detector input
                               FaceLock builds from the stored-image camera frame, in 640x480 pixels
  grace_hopper_r50.f16         ONNX Runtime w600k_r50 (fp32, CPU) on FaceLock's aligned 112x112 crop,
                               L2-normalized, stored as 512 little-endian float16

The raw buffers come from `facelock-bench fixture-inputs` and stay in a temporary directory.

usage: python -I tools/make_fixtures.py [--bench .build/release/facelock-bench]
"""
import argparse
import json
import subprocess
import tempfile
from pathlib import Path

import cv2
import numpy as np
import onnxruntime as ort

ROOT = Path(__file__).resolve().parent.parent
FIX = ROOT / "Tests/Fixtures"
UPSTREAM = ROOT / "models/upstream"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bench", type=Path, default=ROOT / ".build/release/facelock-bench")
    args = ap.parse_args()
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run([str(args.bench), "fixture-inputs", "--out", tmp], check=True, stdout=subprocess.DEVNULL)
        det_in = np.fromfile(Path(tmp) / "detector_320x240.bgra", np.uint8).reshape(240, 320, 4)
        crop = np.fromfile(Path(tmp) / "crop_112.bgra", np.uint8).reshape(112, 112, 4)

    det = cv2.FaceDetectorYN.create(str(UPSTREAM / "face_detection_yunet_2023mar.onnx"), "", (320, 240), 0.85, 0.3, 5000)
    _, faces = det.detect(np.ascontiguousarray(det_in[:, :, :3]))
    if faces is None:
        raise SystemExit("OpenCV YuNet found no face")
    face = faces[np.argmax(faces[:, 2] * faces[:, 3])]
    ref = {
        "image": "grace_hopper.jpg",
        "frame": "aspect-fit into 640x480 on grey 90 (StoredImageCamera), vImageScale to 320x240",
        "detector": {
            "implementation": f"OpenCV {cv2.__version__} FaceDetectorYN, face_detection_yunet_2023mar.onnx, fp32",
            "score": round(float(face[14]), 4),
            "box": [round(float(v) * 2, 3) for v in face[:4]],
            "landmarks": [[round(float(face[4 + 2 * k]) * 2, 3), round(float(face[5 + 2 * k]) * 2, 3)] for k in range(5)],
        },
        "r50": {"file": "grace_hopper_r50.f16", "implementation": f"onnxruntime {ort.__version__} CPU fp32, w600k_r50.onnx"},
    }
    rgb = crop[:, :, [2, 1, 0]].astype(np.float32)
    blob = ((rgb - 127.5) / 127.5).transpose(2, 0, 1)[None]
    sess = ort.InferenceSession(str(UPSTREAM / "w600k_r50.onnx"), providers=["CPUExecutionProvider"])
    e = sess.run(None, {sess.get_inputs()[0].name: blob})[0].ravel()
    e = (e / np.linalg.norm(e)).astype("<f2")
    e.tofile(FIX / "grace_hopper_r50.f16")
    (FIX / "grace_hopper_reference.json").write_text(json.dumps(ref, indent=2) + "\n")
    print(json.dumps(ref["detector"]))


if __name__ == "__main__":
    main()
