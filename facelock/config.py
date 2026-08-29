"""Configuration: defaults, TOML file, CLI overrides."""

from __future__ import annotations

import os
import tomllib
from dataclasses import asdict, dataclass, fields, replace
from pathlib import Path

APP = "facelock"


def _xdg(var: str, fallback: str) -> Path:
    return Path(os.environ.get(var) or Path.home() / fallback) / APP


CONFIG_DIR = _xdg("XDG_CONFIG_HOME", ".config")
STATE_DIR = _xdg("XDG_STATE_HOME", ".local/state")
DATA_DIR = _xdg("XDG_DATA_HOME", ".local/share")

CONFIG_FILE = CONFIG_DIR / "config.toml"
ENROLLMENT_FILE = DATA_DIR / "enrollment.npz"
LOG_FILE = STATE_DIR / "facelock.log"
PAUSE_FILE = STATE_DIR / "pause"
PID_FILE = STATE_DIR / "watcher.pid"

MODELS_DIR = Path(__file__).resolve().parent.parent / "models"
MODEL_SOURCE = "https://github.com/opencv/opencv_zoo/raw/main/models"
# filename -> directory in the opencv_zoo repo
MODELS = {
    "face_detection_yunet_2023mar.onnx": "face_detection_yunet",
    "face_recognition_sface_2021dec.onnx": "face_recognition_sface",
}
DETECTOR_MODEL = MODELS_DIR / "face_detection_yunet_2023mar.onnx"
RECOGNIZER_MODEL = MODELS_DIR / "face_recognition_sface_2021dec.onnx"


@dataclass(frozen=True)
class Config:
    camera: int = 0
    frame_width: int = 640
    frame_height: int = 480
    detect_width: int = 320  # detection runs downscaled; alignment stays full res
    detect_score: float = 0.85

    threshold: float = 0.363  # SFace reference operating point

    # Timing. A "check" is one look at the camera; the loop is a cadence, not a stopwatch.
    interval: float = 30.0  # seconds between checks while I am here
    recheck_interval: float = 10.0  # seconds until the next check once I am missing
    stranger_interval: float = 2.0  # ... but only this long when someone else is in frame
    confirm_checks: int = 2  # consecutive checks without me before the screen locks
    frames_per_check: int = 3  # frames per check; the best match of the burst wins

    lock_method: str = "suspend"  # suspend | sleep
    sound: bool = True
    notify: bool = True

    def validate(self) -> Config:
        if not 0.0 < self.threshold < 1.0:
            raise ValueError("threshold must be between 0 and 1")
        for name in ("interval", "recheck_interval", "stranger_interval"):
            if getattr(self, name) <= 0:
                raise ValueError(f"{name} must be positive")
        if self.confirm_checks < 1:
            raise ValueError("confirm_checks must be at least 1")
        if self.frames_per_check < 1:
            raise ValueError("frames_per_check must be at least 1")
        if self.lock_method not in ("suspend", "sleep"):
            raise ValueError("lock_method must be 'suspend' or 'sleep'")
        return self


def load(path: Path = CONFIG_FILE) -> Config:
    if not path.exists():
        return Config()
    with path.open("rb") as handle:
        raw = tomllib.load(handle)
    known = {f.name for f in fields(Config)}
    unknown = set(raw) - known
    if unknown:
        raise ValueError(
            f"unknown keys in {path}: {', '.join(sorted(unknown))}\n"
            "  the timing settings were renamed - `facelock config --write` regenerates the file"
        )
    return Config(**raw).validate()


def with_overrides(config: Config, **overrides) -> Config:
    live = {k: v for k, v in overrides.items() if v is not None}
    return replace(config, **live).validate() if live else config


def write_default(path: Path = CONFIG_FILE) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = ["# facelock config - delete a line to fall back to the default", ""]
    for key, value in asdict(Config()).items():
        rendered = str(value).lower() if isinstance(value, bool) else repr(value)
        lines.append(f"{key} = {rendered}")
    path.write_text("\n".join(lines) + "\n")
    return path


def ensure_dirs() -> None:
    for directory in (CONFIG_DIR, STATE_DIR, DATA_DIR):
        directory.mkdir(parents=True, exist_ok=True)
