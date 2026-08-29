"""Camera capture, face detection (YuNet) and identity embeddings (SFace)."""

from __future__ import annotations

import sys
import time

import cv2
import numpy as np

from . import config
from .identity import EMBEDDING_DIM

CAMERA_HELP = (
    "grant your terminal Camera access in System Settings > Privacy & Security > Camera, "
    "then restart the terminal"
)
EMPTY = np.empty((0, EMBEDDING_DIM), dtype=np.float32)


class ModelsMissing(SystemExit):
    pass


class FaceEngine:
    """Detects faces on a downscaled frame, embeds them from the full-resolution frame."""

    def __init__(self, cfg: config.Config):
        for path in (config.DETECTOR_MODEL, config.RECOGNIZER_MODEL):
            if not path.exists():
                raise ModelsMissing(f"missing model {path}\nrun ./setup.sh to download it")
        self._cfg = cfg
        self._detector = cv2.FaceDetectorYN.create(
            str(config.DETECTOR_MODEL), "", (cfg.detect_width, cfg.detect_width),
            cfg.detect_score, 0.3, 5000,
        )
        self._recognizer = cv2.FaceRecognizerSF.create(str(config.RECOGNIZER_MODEL), "")
        self._input_size: tuple[int, int] | None = None

    def detect(self, frame: np.ndarray) -> np.ndarray:
        """Face rows [x, y, w, h, 5 landmarks, score] in full-frame coordinates."""
        height, width = frame.shape[:2]
        scale = min(1.0, self._cfg.detect_width / width)
        small = (
            cv2.resize(frame, (int(width * scale), int(height * scale)))
            if scale < 1.0 else frame
        )
        size = (small.shape[1], small.shape[0])
        if size != self._input_size:
            self._detector.setInputSize(size)
            self._input_size = size
        _, faces = self._detector.detect(small)
        if faces is None:
            return np.empty((0, 15), dtype=np.float32)
        faces = np.asarray(faces, dtype=np.float32).copy()
        if scale < 1.0:
            faces[:, :14] /= scale
        return faces

    def embed(self, frame: np.ndarray, faces: np.ndarray) -> np.ndarray:
        """(N, 128) L2-normalized embeddings, one per detected face."""
        if len(faces) == 0:
            return EMPTY
        out = []
        for face in faces:
            aligned = self._recognizer.alignCrop(frame, face)
            feature = self._recognizer.feature(aligned).flatten().astype(np.float32)
            norm = float(np.linalg.norm(feature))
            if norm > 0:
                out.append(feature / norm)
        return np.array(out, dtype=np.float32) if out else EMPTY

    def faces_and_embeddings(self, frame: np.ndarray) -> tuple[int, np.ndarray]:
        faces = self.detect(frame)
        return len(faces), self.embed(frame, faces)


class Camera:
    """Webcam handle that can be released while idle and reopened on demand."""

    def __init__(self, cfg: config.Config):
        self._cfg = cfg
        self._capture: cv2.VideoCapture | None = None

    @property
    def is_open(self) -> bool:
        return self._capture is not None

    def open(self) -> None:
        if self._capture is not None:
            return
        capture = cv2.VideoCapture(self._cfg.camera, cv2.CAP_AVFOUNDATION)
        capture.set(cv2.CAP_PROP_FRAME_WIDTH, self._cfg.frame_width)
        capture.set(cv2.CAP_PROP_FRAME_HEIGHT, self._cfg.frame_height)
        if not capture.isOpened():
            capture.release()
            raise SystemExit(f"cannot open camera {self._cfg.camera}\n{CAMERA_HELP}")
        self._capture = capture

    def read(self) -> np.ndarray | None:
        self.open()
        assert self._capture is not None
        ok, frame = self._capture.read()
        return frame if ok else None

    def release(self) -> None:
        if self._capture is not None:
            self._capture.release()
            self._capture = None

    def __enter__(self) -> Camera:
        self.open()
        return self

    def __exit__(self, *exc) -> None:
        self.release()


def warmup(camera: Camera, seconds: float = 0.6) -> None:
    """Discard the first frames while the sensor settles on exposure."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        camera.read()


def silence_opencv_logs() -> None:
    cv2.utils.logging.setLogLevel(cv2.utils.logging.LOG_LEVEL_ERROR)
    if not sys.stdout.isatty():
        cv2.utils.logging.setLogLevel(cv2.utils.logging.LOG_LEVEL_SILENT)
