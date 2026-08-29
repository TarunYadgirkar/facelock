import pytest

from facelock.config import Config
from facelock.identity import Match
from facelock.watcher import Decision, Event, PresenceTracker, Reading, State, look, poll_delay

CFG = Config(threshold=0.4, interval=30.0, recheck_interval=10.0,
             stranger_interval=2.0, confirm_checks=2)


def me(score=0.8):
    return Reading(Match(score, "me"), 1)


def nobody():
    return Reading(Match(0.0, None), 0)


def stranger(score=0.1):
    return Reading(Match(score, "me"), 1)


def test_present_while_i_match():
    tracker = PresenceTracker(CFG)
    decision = tracker.update(me())
    assert decision.state is State.PRESENT
    assert decision.event is None


def test_two_missed_checks_lock():
    tracker = PresenceTracker(CFG)
    assert tracker.update(nobody()).event is Event.WARN
    assert tracker.update(nobody()).event is Event.LOCK


def test_returning_between_checks_resets_the_count():
    tracker = PresenceTracker(CFG)
    tracker.update(nobody())
    assert tracker.update(me()).event is Event.RETURN
    assert tracker.update(nobody()).event is Event.WARN  # back to check 1 of 2


def test_count_restarts_after_a_lock():
    tracker = PresenceTracker(CFG)
    tracker.update(nobody())
    assert tracker.update(nobody()).event is Event.LOCK
    assert tracker.update(nobody()).event is Event.WARN


def test_stranger_state_is_reported():
    tracker = PresenceTracker(CFG)
    decision = tracker.update(stranger())
    assert decision.state is State.STRANGER


def test_single_check_config_locks_immediately_without_warning():
    tracker = PresenceTracker(Config(confirm_checks=1))
    assert tracker.update(nobody()).event is Event.LOCK


def test_poll_delay_matches_state():
    assert poll_delay(CFG, Decision(State.PRESENT, 0, 2)) == CFG.interval
    assert poll_delay(CFG, Decision(State.AWAY, 1, 2)) == CFG.recheck_interval
    assert poll_delay(CFG, Decision(State.STRANGER, 1, 2)) == CFG.stranger_interval


def test_look_takes_the_best_frame_of_the_burst():
    class FakeCamera:
        def read(self):
            return "frame"

    class FakeEngine:
        def __init__(self):
            self.scores = iter([0.1, 0.9, 0.2])

        def faces_and_embeddings(self, frame):
            return 1, next(self.scores)

    class FakeEnrollment:
        def best(self, score):
            return Match(score, "me")

    reading = look(FakeCamera(), FakeEngine(), FakeEnrollment(), frames=3)
    assert reading.match.score == 0.9
    assert reading.face_count == 1


def test_look_reports_camera_failure():
    class DeadCamera:
        def read(self):
            return None

    assert look(DeadCamera(), None, None, frames=2) is None


def test_config_rejects_impossible_settings():
    with pytest.raises(ValueError):
        Config(interval=0).validate()
    with pytest.raises(ValueError):
        Config(confirm_checks=0).validate()
    with pytest.raises(ValueError):
        Config(threshold=1.5).validate()
    with pytest.raises(ValueError):
        Config(lock_method="explode").validate()
