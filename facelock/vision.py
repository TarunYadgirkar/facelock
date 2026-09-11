"""Camera capture, face detection (YuNet) and identity embeddings (ArcFace, or legacy SFace)."""

from __future__ import annotations

import io
import sys
import time
import urllib.error
import urllib.request
import zipfile
from collections.abc import Callable

import cv2
import numpy as np

from . import config
from .identity import embedding_dim

CAMERA_HELP = (
    "grant your terminal Camera access in System Settings > Privacy & Security > Camera, "
    "then restart the terminal"
)
ARCFACE_INPUT = 112  # aligned crop side; the SFace aligner produces exactly this template
ARCFACE_SCALE = 1 / 127.5
ARCFACE_MEAN = (127.5, 127.5, 127.5)


class CameraError(RuntimeError):
    pass


def _fetch(url: str) -> bytes:
    with urllib.request.urlopen(url) as response:
        return response.read()


def ensure_models(log: Callable[[str], None] = print,
                  names: tuple[str, ...] | None = None) -> None:
    """Fetch the ONNX models on first use. A few tens of MB, once, then never again."""
    config.MODELS_DIR.mkdir(parents=True, exist_ok=True)
    for name in names or tuple(config.MODELS):
        target = config.MODELS_DIR / name
        if target.exists():
            continue
        url, member = config.MODELS[name]
        log(f"downloading {name}")
        try:
            payload = _fetch(url)
            if member is not None:
                with zipfile.ZipFile(io.BytesIO(payload)) as archive:
                    payload = archive.read(member)
        except (urllib.error.URLError, OSError, zipfile.BadZipFile, KeyError) as exc:
            raise SystemExit(f"could not download {name} from {url}: {exc}") from exc
        partial = target.with_suffix(".part")
        partial.write_bytes(payload)
        partial.rename(target)


def _models_for(recognizer: str) -> tuple[str, ...]:
    """Detector, the SFace file (its aligner serves every recognizer), and the recognizer."""
    return tuple(dict.fromkeys((config.DETECTOR_MODEL.name, config.RECOGNIZERS["sface"][0].name,
                                config.RECOGNIZERS[recognizer][0].name)))


class FaceEngine:
    """Detects faces on a downscaled frame, embeds them from the full-resolution frame."""

    def __init__(self, cfg: config.Config, recognizer: str = config.DEFAULT_RECOGNIZER):
        if recognizer not in config.RECOGNIZERS:
            raise ValueError(f"unknown recognizer {recognizer!r}")
        ensure_models(names=_models_for(recognizer))
        self._cfg = cfg
        self.recognizer = recognizer
        self._detector = cv2.FaceDetectorYN.create(
            str(config.DETECTOR_MODEL), "", (cfg.detect_width, cfg.detect_width),
            cfg.detect_score, 0.3, 5000,
        )
        # SFace's aligner is the standard 5-point ArcFace template, so it feeds both models.
        self._aligner = cv2.FaceRecognizerSF.create(str(config.RECOGNIZERS["sface"][0]), "")
        self._arcface = (
            cv2.dnn.readNetFromONNX(str(config.RECOGNIZERS["arcface"][0]))
            if recognizer == "arcface" else None
        )
        self._input_size: tuple[int, int] | None = None
        self._empty = np.empty((0, embedding_dim(recognizer)), dtype=np.float32)

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

    def _feature(self, aligned: np.ndarray) -> np.ndarray:
        if self._arcface is None:
            return self._aligner.feature(aligned).flatten()
        blob = cv2.dnn.blobFromImage(aligned, ARCFACE_SCALE, (ARCFACE_INPUT, ARCFACE_INPUT),
                                     ARCFACE_MEAN, swapRB=True)
        self._arcface.setInput(blob)
        return self._arcface.forward().flatten()

    def embed(self, frame: np.ndarray, faces: np.ndarray) -> np.ndarray:
        """(N, dim) L2-normalized embeddings, one per detected face."""
        if len(faces) == 0:
            return self._empty
        out = []
        for face in faces:
            aligned = self._aligner.alignCrop(frame, face)
            feature = self._feature(aligned).astype(np.float32)
            norm = float(np.linalg.norm(feature))
            if norm > 0:
                out.append(feature / norm)
        return np.array(out, dtype=np.float32) if out else self._empty

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
            raise CameraError(f"cannot open camera {self._cfg.camera}: {CAMERA_HELP}")
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
    if hasattr(cv2, "setLogLevel"):
        cv2.setLogLevel(getattr(cv2, "LOG_LEVEL_ERROR", 2))
        if not sys.stdout.isatty():
            cv2.setLogLevel(getattr(cv2, "LOG_LEVEL_SILENT", 0))
        return
    logging = cv2.utils.logging
    logging.setLogLevel(logging.LOG_LEVEL_ERROR)
    if not sys.stdout.isatty():
        logging.setLogLevel(logging.LOG_LEVEL_SILENT)
