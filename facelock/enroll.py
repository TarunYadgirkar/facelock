"""Capture reference samples of a face from the webcam."""

from __future__ import annotations

import time
from collections.abc import Callable

import numpy as np

from . import config, vision
from .identity import Enrollment

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


def capture(
    cfg: config.Config,
    samples: int,
    progress: Progress,
    spacing: float = 0.35,
    timeout: float = 90.0,
    poses: tuple[str, ...] = POSES,
    minimum: int = MIN_USEFUL_SAMPLES,
    recognizer: str = config.DEFAULT_RECOGNIZER,
) -> np.ndarray:
    """Collect `samples` embeddings, prompting through `poses` as they are filled."""
    engine = vision.FaceEngine(cfg, recognizer)
    collected: list[np.ndarray] = []
    per_pose = max(1, samples // len(poses))
    deadline = time.monotonic() + timeout

    with vision.Camera(cfg) as camera:
        vision.warmup(camera)
        while len(collected) < samples and time.monotonic() < deadline:
            pose = poses[min(len(collected) // per_pose, len(poses) - 1)]
            frame = camera.read()
            if frame is None:
                continue
            count, embeddings = engine.faces_and_embeddings(frame)
            if count == 1 and len(embeddings) == 1:
                collected.append(embeddings[0])
                progress(f"{len(collected)}/{samples}  {pose}")
                time.sleep(spacing)
            elif count > 1:
                progress(f"{len(collected)}/{samples}  more than one face in shot - hold on")
                time.sleep(spacing)
            else:
                progress(f"{len(collected)}/{samples}  no face detected - {pose}")

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
