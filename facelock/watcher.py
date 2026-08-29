"""Presence state machine and the watch loop that drives it."""

from __future__ import annotations

import time
from collections.abc import Callable
from dataclasses import dataclass
from enum import Enum

from . import config, session, vision
from .identity import Enrollment, Match


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
    match: Match
    face_count: int


@dataclass(frozen=True)
class Decision:
    state: State
    away: float
    deadline: float
    event: Event | None = None

    @property
    def urgent(self) -> bool:
        return self.state is not State.PRESENT


class PresenceTracker:
    """Pure decision logic - no camera, no clock of its own. Deliberately easy to test."""

    def __init__(self, cfg: config.Config, now: float):
        self._cfg = cfg
        self._last_seen = now
        self._warned = False
        self._was_present = True

    def update(self, reading: Reading, now: float) -> Decision:
        cfg = self._cfg
        if reading.match.accepted(cfg.threshold):
            returning = not self._was_present
            self._last_seen = now
            self._warned = False
            self._was_present = True
            return Decision(State.PRESENT, 0.0, cfg.timeout, Event.RETURN if returning else None)

        away = now - self._last_seen
        stranger = reading.face_count > 0
        state = State.STRANGER if stranger else State.AWAY
        deadline = cfg.unknown_face_timeout if stranger else cfg.timeout
        self._was_present = False

        if away >= deadline:
            self._last_seen = now  # the caller locks; restart the clock either way
            self._warned = False
            return Decision(state, away, deadline, Event.LOCK)
        if not self._warned and away >= max(0.0, deadline - cfg.warn_before):
            self._warned = True
            return Decision(state, away, deadline, Event.WARN)
        return Decision(state, away, deadline)


def poll_delay(cfg: config.Config, decision: Decision) -> float:
    """Poll faster once someone is on the clock, slower while I am plainly here."""
    return cfg.alert_interval if decision.urgent else cfg.interval


Observer = Callable[[Decision, Reading], None]


def run(
    cfg: config.Config,
    enrollment: Enrollment,
    observer: Observer,
    dry_run: bool = False,
    paused: Callable[[], bool] = lambda: False,
    clock: Callable[[], float] = time.monotonic,
    should_stop: Callable[[], bool] = lambda: False,
) -> None:
    """Watch until interrupted. Releases the camera whenever it is not needed."""
    engine = vision.FaceEngine(cfg)
    camera = vision.Camera(cfg)
    tracker = PresenceTracker(cfg, clock())
    read_failures = 0

    try:
        while not should_stop():
            if session.screen_locked() or paused():
                camera.release()
                tracker = PresenceTracker(cfg, clock())
                time.sleep(1.0)
                continue

            if not camera.is_open:
                camera.open()
                vision.warmup(camera)
                tracker = PresenceTracker(cfg, clock())

            frame = camera.read()
            if frame is None:
                read_failures += 1
                camera.release()
                time.sleep(min(2.0 ** read_failures * 0.1, 5.0))
                continue
            read_failures = 0

            count, embeddings = engine.faces_and_embeddings(frame)
            reading = Reading(enrollment.best(embeddings), count)
            decision = tracker.update(reading, clock())
            observer(decision, reading)

            if decision.event is Event.LOCK and not dry_run:
                session.lock(cfg.lock_method)
                time.sleep(1.5)
                camera.release()
                continue

            time.sleep(poll_delay(cfg, decision))
    finally:
        camera.release()
