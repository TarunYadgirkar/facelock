"""Capture reference samples of a face from the webcam."""

from __future__ import annotations

import time
from collections.abc import Callable

import numpy as np

from . import config, vision
from .identity import Calibration, Enrollment, calibrate

Progress = Callable[[str], None]
MIN_USEFUL_SAMPLES = 8
POSES = (
    "look straight at the camera",
    "turn your head slightly left",
    "turn your head slightly right",
    "tilt your chin up a little",
    "look down at your keyboard",
    "look down at your phone, like you are reading it",
    "look at where your screen usually is",
)
# Teaching one pose does not need the tour, and must not veto itself on sample count.
LEARN_POSES = ("hold the pose you want it to know",)


def prepare(current: Enrollment, samples: np.ndarray, profile: str = "me",
            append: bool = True, replace_all: bool = False,
            threshold: float = 0.42) -> tuple[Enrollment, Calibration]:
    captured = Enrollment({profile: samples}, current.recognizer)
    samples = captured.templates
    if not append and len(samples) < MIN_USEFUL_SAMPLES:
        raise ValueError(f"need at least {MIN_USEFUL_SAMPLES} clear samples; previous enrollment kept")
    if len(current) and not replace_all:
        minimum = max(threshold, current.threshold or config.default_threshold(current.recognizer))
        samples = samples[current.scores(samples) >= minimum]
        if len(samples) < 3:
            raise ValueError("too few samples match the enrolled owner; keep your face visible or use Start Over")
    else:
        if len(samples) < MIN_USEFUL_SAMPLES:
            raise ValueError(f"need at least {MIN_USEFUL_SAMPLES} clear samples; previous enrollment kept")
        anchor = Enrollment({profile: samples[:1]}, current.recognizer)
        minimum = max(threshold, config.default_threshold(current.recognizer))
        if (anchor.scores(samples) < minimum).any():
            raise ValueError("samples are not consistent with the first face; try again alone with better light and smaller head turns")
    base = Enrollment({}, current.recognizer) if replace_all else current
    updated = base.with_profile(profile, samples, append=append)
    updated = updated.without_outliers(config.default_threshold(updated.recognizer))
    if len(updated) < MIN_USEFUL_SAMPLES:
        raise ValueError("too few consistent samples; previous enrollment kept")
    calibration = calibrate(updated)
    if calibration.own_p05 <= calibration.threshold:
        raise ValueError("enrollment is inconsistent; try again with better light and smaller head turns")
    return updated.calibrated(calibration.threshold), calibration


def capture(
    cfg: config.Config,
    samples: int,
    progress: Progress,
    spacing: float = 0.35,
    timeout: float = 90.0,
    poses: tuple[str, ...] = POSES,
    minimum: int = MIN_USEFUL_SAMPLES,
    recognizer: str = config.DEFAULT_RECOGNIZER,
    reference: Enrollment | None = None,
    should_stop: Callable[[], bool] = lambda: False,
) -> np.ndarray:
    """Collect `samples` embeddings, prompting through `poses` as they are filled."""
    if should_stop():
        raise ValueError("capture cancelled")
    if samples < minimum or not poses:
        raise ValueError(f"request at least {minimum} samples and one pose")
    engine = vision.FaceEngine(cfg, recognizer)
    collected: list[np.ndarray] = []
    per_pose = max(1, samples // len(poses))
    deadline = time.monotonic() + timeout
    last_pose = None
    existing_reference = reference is not None

    with vision.Camera(cfg) as camera:
        vision.warmup(camera)
        while len(collected) < samples and time.monotonic() < deadline:
            if should_stop():
                raise ValueError("capture cancelled")
            pose = poses[min(len(collected) // per_pose, len(poses) - 1)]
            if pose != last_pose:
                progress(f"{len(collected)}/{samples}  {pose}")
                last_pose = pose
                time.sleep(0.8)
            frame = camera.read()
            if frame is None:
                time.sleep(0.1)
                continue
            count, embeddings = engine.faces_and_embeddings(frame)
            if count == 1 and len(embeddings) == 1:
                threshold = max(cfg.threshold, reference.threshold or
                                config.default_threshold(recognizer)) if reference is not None else 0
                if reference is not None and not reference.best(embeddings).accepted(threshold):
                    message = ("face does not match enrolled owner" if existing_reference else
                               "face differs from first sample; face camera with better light")
                    progress(f"{len(collected)}/{samples}  {message}")
                    time.sleep(spacing)
                    continue
                if reference is None:
                    reference = Enrollment({"me": embeddings}, recognizer)
                collected.append(embeddings[0])
                progress(f"{len(collected)}/{samples}  {pose}")
                time.sleep(spacing)
            elif count > 1:
                progress(f"{len(collected)}/{samples}  more than one face in shot - hold on")
                time.sleep(spacing)
            else:
                progress(f"{len(collected)}/{samples}  no face detected - {pose}")
                time.sleep(0.1)

    if len(collected) < minimum:
        raise SystemExit(
            f"only captured {len(collected)} samples - try again with more light on your face"
        )
    return np.array(collected, dtype=np.float32)


def quality_note(enrollment: Enrollment, threshold: float) -> str:
    """How my own views fare against each other, scored the way a live frame is."""
    own = enrollment.leave_one_out()
    if len(own) == 0:
        return "too few views to judge"
    weakest, typical = float(own.min()), float(np.median(own))
    if weakest < threshold:
        return (f"weakest view scores {weakest:.3f} against the rest, below the {threshold:.3f} "
                "threshold - it does not look like you and will be pruned on the next lesson")
    return f"your views score {weakest:.3f}-{typical:.3f} against each other - healthy"
