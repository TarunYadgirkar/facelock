"""Presence state machine and the watch loop that drives it."""

from __future__ import annotations

import logging
import time
from collections.abc import Callable
from dataclasses import dataclass
from enum import Enum

from . import config, macos, vision
from .identity import NO_MATCH, Enrollment, Live, Match

# Keeping the camera powered between checks only pays off when the next one is close.
KEEP_CAMERA_OPEN_UNDER = 5.0
LOCK_SETTLE = 1.5
FAILURE_RETRY_MAX = 5.0
FAILURE_RETRY_BASE = 0.1
MIN_RECHECK = 2.0  # however far the rechecks escalate, never spin the camera faster than this
READ_FAILURES_BEFORE_MISS = 3  # camera errors tolerated before they count against presence
READ_FAILURE_LOG_MARKS = (1, 10)  # log the first, the tenth, then every hundredth


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

    def update(self, reading: Reading, threshold: float | None = None) -> Decision:
        needed = self._cfg.confirm_checks
        if reading.match.accepted(self._cfg.threshold if threshold is None else threshold):
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


def recheck_delay(cfg: config.Config, misses: int) -> float:
    """Each further miss waits less: once you look gone, stay unlocked for as little as possible."""
    return max(MIN_RECHECK, cfg.recheck_interval * cfg.recheck_decay ** max(0, misses - 1))


def poll_delay(cfg: config.Config, decision: Decision) -> float:
    """Slow cadence while I am plainly here, faster once something is on the clock."""
    if decision.state is State.PRESENT:
        return cfg.interval
    if decision.state is State.STRANGER:
        return cfg.stranger_interval
    return recheck_delay(cfg, decision.misses)


def _alert(cfg: config.Config, decision: Decision, log: logging.Logger) -> None:
    """WARN gets the sound and banner; every event gets a log line."""
    if decision.event is Event.WARN:
        macos.warn(cfg, f"locking in ~{poll_delay(cfg, decision):.0f}s unless I see you")
    log.info("%s (state %s)", decision.event.value, decision.state.value)


def look(camera: vision.Camera, engine: vision.FaceEngine, enrollment: Enrollment | Live,
         frames: int) -> Reading | None:
    """One check: a burst supported by two frames. None if the camera failed."""
    matches = []
    faces = 0
    for _ in range(frames):
        frame = camera.read()
        if frame is None:
            return None
        count, embeddings = engine.faces_and_embeddings(frame)
        match = enrollment.best(embeddings)
        faces = max(faces, count)
        matches.append(match)
    matches.sort(key=lambda candidate: candidate.score, reverse=True)
    required = 1 if frames == 1 else 2
    return Reading(matches[required - 1], faces)


Observer = Callable[[Decision, Reading], None]


def _sleep(seconds: float, should_stop: Callable[[], bool]) -> None:
    """Sleep in short ticks so stop and pause are honoured within half a second."""
    deadline = time.monotonic() + seconds
    while not should_stop():
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return
        time.sleep(min(0.5, remaining))


def _engine_for(cfg: config.Config, enrollment: Enrollment | Live,
                current: vision.FaceEngine | None) -> vision.FaceEngine:
    """The recognizer must be the one the enrolled views came from; Start Over can change it."""
    if current is not None and current.recognizer == enrollment.recognizer:
        return current
    return vision.FaceEngine(cfg, enrollment.recognizer)


def _failure_delay(failures: int) -> float:
    exponent = min(failures, 6)
    return min(FAILURE_RETRY_BASE * 2 ** exponent, FAILURE_RETRY_MAX)


def run(
    cfg: config.Config,
    enrollment: Enrollment | Live,
    observer: Observer,
    dry_run: bool = False,
    paused: Callable[[], bool] = lambda: False,
    should_stop: Callable[[], bool] = lambda: False,
    on_status: Callable[[str], None] = lambda _message: None,
) -> None:
    """Watch until stopped. Holds the camera only for as long as a check needs it."""
    engine = _engine_for(cfg, enrollment, None)
    camera = vision.Camera(cfg)
    tracker = PresenceTracker(cfg)
    awake = macos.StayAwake()
    log = logging.getLogger(config.APP)
    read_failures = 0
    locked_by_us = False

    try:
        while not should_stop():
            if macos.screen_locked():
                camera.release()
                tracker.reset()
                _sleep(1.0, should_stop)
                continue

            if locked_by_us:  # the screen has been unlocked since
                locked_by_us = False
                awake.stop()

            if paused():
                camera.release()
                tracker.reset()
                _sleep(1.0, should_stop)
                continue

            engine = _engine_for(cfg, enrollment, engine)
            try:
                if not camera.is_open:
                    camera.open()
                    vision.warmup(camera)
                reading = look(camera, engine, enrollment, cfg.frames_per_check)
            except (vision.CameraError, vision.cv2.error) as exc:
                reading = None
                on_status(f"camera failed: {exc}")
            if reading is None:  # unreadable camera: back off, then count it as a miss
                read_failures += 1
                on_status(f"camera read failed ({read_failures} in a row)")
                if read_failures in READ_FAILURE_LOG_MARKS or read_failures % 100 == 0:
                    log.warning("camera read failed (%d in a row) - no camera permission?",
                                read_failures)
                camera.release()
                _sleep(_failure_delay(read_failures), lambda: should_stop() or paused())
                if should_stop():
                    return
                if paused():
                    tracker.reset()
                    continue
                if read_failures < READ_FAILURES_BEFORE_MISS:
                    continue
                reading = Reading(NO_MATCH, 0)  # camera gone: fail toward locking, not open
            else:
                if read_failures:
                    on_status("camera recovered")
                read_failures = 0

            if should_stop():
                return
            if paused():
                camera.release()
                tracker.reset()
                continue

            calibrated = enrollment.threshold
            identity_threshold = (
                calibrated
                if calibrated is not None
                else config.default_threshold(enrollment.recognizer)
            )
            threshold = max(cfg.threshold, identity_threshold)
            decision = tracker.update(reading, threshold)
            observer(decision, reading)
            if reload_error := getattr(enrollment, "error", None):
                on_status(f"watching with last saved face - {reload_error}")
            if decision.event is not None:
                _alert(cfg, decision, log)
            if read_failures:
                remaining = max(0, decision.needed - decision.misses)
                check_word = "check" if remaining == 1 else "checks"
                on_status(
                    f"camera read failed ({read_failures} in a row) - "
                    f"{remaining} {check_word} remaining before lock"
                )

            if decision.event is Event.LOCK and not dry_run:
                camera.release()
                try:
                    macos.lock(cfg.lock_method)
                except RuntimeError as exc:
                    on_status(f"lock failed: {exc}")
                    _sleep(FAILURE_RETRY_MAX, lambda: should_stop() or paused())
                    continue
                if should_stop() or paused():
                    continue
                if cfg.stay_awake:
                    locked_by_us = True
                    awake.start()
                _sleep(LOCK_SETTLE, lambda: should_stop() or paused())
                continue

            delay = poll_delay(cfg, decision)
            if delay >= KEEP_CAMERA_OPEN_UNDER:
                camera.release()  # green light off, sensor unpowered, between checks
            _sleep(delay, lambda: should_stop() or paused())
    finally:
        camera.release()
        awake.stop()
