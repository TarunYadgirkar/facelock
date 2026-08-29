"""Presence state machine and the watch loop that drives it."""

from __future__ import annotations

import logging
import time
from collections.abc import Callable
from dataclasses import dataclass
from enum import Enum

from . import config, macos, vision
from .identity import NO_MATCH, Enrollment, Match

# Keeping the camera powered between checks only pays off when the next one is close.
KEEP_CAMERA_OPEN_UNDER = 5.0
LOCK_SETTLE = 1.5


class State(str, Enum):
    PRESENT = "present"
    AWAY = "away"
    STRANGER = "stranger"  # a face is visible and it is not mine


class Event(str, Enum):
    WARN = "warn"
    LOCK = "lock"
    RETURN = "return"


@dataclass(frozen=True)
class Reading:
    """What one check saw: the best match of the frame burst, and how many faces at most."""

    match: Match
    face_count: int


@dataclass(frozen=True)
class Decision:
    state: State
    misses: int  # consecutive checks without me, this one included
    needed: int  # misses required before locking
    event: Event | None = None

    @property
    def urgent(self) -> bool:
        return self.state is not State.PRESENT


class PresenceTracker:
    """Pure decision logic - counts checks, owns no camera and no clock. Easy to test."""

    def __init__(self, cfg: config.Config):
        self._cfg = cfg
        self._misses = 0
        self._was_present = True

    def reset(self) -> None:
        self._misses = 0
        self._was_present = True

    def update(self, reading: Reading) -> Decision:
        needed = self._cfg.confirm_checks
        if reading.match.accepted(self._cfg.threshold):
            returning = not self._was_present
            self.reset()
            return Decision(State.PRESENT, 0, needed, Event.RETURN if returning else None)

        self._misses += 1
        self._was_present = False
        state = State.STRANGER if reading.face_count > 0 else State.AWAY

        if self._misses >= needed:
            self._misses = 0  # the caller locks; start the next absence from scratch
            return Decision(state, needed, needed, Event.LOCK)
        if self._misses == needed - 1:
            return Decision(state, self._misses, needed, Event.WARN)
        return Decision(state, self._misses, needed)


def poll_delay(cfg: config.Config, decision: Decision) -> float:
    """Slow cadence while I am plainly here, faster once something is on the clock."""
    if decision.state is State.PRESENT:
        return cfg.interval
    return cfg.stranger_interval if decision.state is State.STRANGER else cfg.recheck_interval


def look(camera: vision.Camera, engine: vision.FaceEngine, enrollment: Enrollment,
         frames: int) -> Reading | None:
    """One check: a short burst of frames, scored as its best match. None if the camera failed."""
    best = NO_MATCH
    faces = 0
    for _ in range(frames):
        frame = camera.read()
        if frame is None:
            return None
        count, embeddings = engine.faces_and_embeddings(frame)
        match = enrollment.best(embeddings)
        faces = max(faces, count)
        if match.score > best.score:
            best = match
    return Reading(best, faces)


Observer = Callable[[Decision, Reading], None]


def _sleep(seconds: float, should_stop: Callable[[], bool]) -> None:
    """Sleep in short ticks so stop and pause are honoured within half a second."""
    deadline = time.monotonic() + seconds
    while not should_stop():
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return
        time.sleep(min(0.5, remaining))


def run(
    cfg: config.Config,
    enrollment: Enrollment,
    observer: Observer,
    dry_run: bool = False,
    paused: Callable[[], bool] = lambda: False,
    should_stop: Callable[[], bool] = lambda: False,
) -> None:
    """Watch until stopped. Holds the camera only for as long as a check needs it."""
    engine = vision.FaceEngine(cfg)
    camera = vision.Camera(cfg)
    tracker = PresenceTracker(cfg)
    log = logging.getLogger(config.APP)
    read_failures = 0

    try:
        while not should_stop():
            if macos.screen_locked() or paused():
                camera.release()
                tracker.reset()
                _sleep(1.0, should_stop)
                continue

            if not camera.is_open:
                camera.open()
                vision.warmup(camera)

            reading = look(camera, engine, enrollment, cfg.frames_per_check)
            if reading is None:  # unreadable camera: back off, then count it as a miss
                read_failures += 1
                if read_failures in (1, 10) or read_failures % 100 == 0:
                    log.warning("camera read failed (%d in a row) - no camera permission?",
                                read_failures)
                camera.release()
                _sleep(min(2.0 ** read_failures * 0.1, 5.0), should_stop)
                if read_failures < 3:
                    continue
                reading = Reading(NO_MATCH, 0)  # camera gone: fail toward locking, not open
            read_failures = 0

            decision = tracker.update(reading)
            observer(decision, reading)
            if decision.event is not None:
                log.info("%s (state %s, score %+.2f)",
                         decision.event.value, decision.state.value, reading.match.score)

            if decision.event is Event.LOCK and not dry_run:
                macos.lock(cfg.lock_method)
                camera.release()
                time.sleep(LOCK_SETTLE)
                continue

            delay = poll_delay(cfg, decision)
            if delay >= KEEP_CAMERA_OPEN_UNDER:
                camera.release()  # green light off, sensor unpowered, between checks
            _sleep(delay, should_stop)
    finally:
        camera.release()
