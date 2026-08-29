import pytest

from facelock.config import Config
from facelock.identity import Match
from facelock.watcher import Decision, Event, PresenceTracker, Reading, State, poll_delay

CFG = Config(threshold=0.4, timeout=3.0, warn_before=1.0, unknown_face_timeout=1.0)


def me(score=0.8):
    return Reading(Match(score, "me"), 1)


def nobody():
    return Reading(Match(0.0, None), 0)


def stranger(score=0.1):
    return Reading(Match(score, "me"), 1)


def test_present_while_i_match():
    tracker = PresenceTracker(CFG, 0.0)
    decision = tracker.update(me(), 1.0)
    assert decision.state is State.PRESENT
    assert decision.event is None


def test_locks_after_timeout_without_me():
    tracker = PresenceTracker(CFG, 0.0)
    assert tracker.update(nobody(), 1.0).event is None
    assert tracker.update(nobody(), 2.5).event is Event.WARN
    assert tracker.update(nobody(), 3.5).event is Event.LOCK


def test_does_not_lock_one_tick_early():
    tracker = PresenceTracker(CFG, 0.0)
    assert tracker.update(nobody(), 2.99).event is not Event.LOCK


def test_warning_fires_once_per_absence():
    tracker = PresenceTracker(CFG, 0.0)
    assert tracker.update(nobody(), 2.1).event is Event.WARN
    assert tracker.update(nobody(), 2.4).event is None


def test_returning_resets_the_clock():
    tracker = PresenceTracker(CFG, 0.0)
    tracker.update(nobody(), 2.9)
    assert tracker.update(me(), 3.0).event is Event.RETURN
    assert tracker.update(nobody(), 5.0).event is not Event.LOCK
    assert tracker.update(nobody(), 6.1).event is Event.LOCK


def test_stranger_gets_the_shorter_deadline():
    tracker = PresenceTracker(CFG, 0.0)
    decision = tracker.update(stranger(), 1.2)
    assert decision.state is State.STRANGER
    assert decision.event is Event.LOCK


def test_clock_restarts_after_a_lock():
    tracker = PresenceTracker(CFG, 0.0)
    assert tracker.update(nobody(), 4.0).event is Event.LOCK
    assert tracker.update(nobody(), 5.0).event is None
    assert tracker.update(nobody(), 8.1).event is Event.LOCK


def test_poll_delay_speeds_up_when_not_present():
    slow = Decision(State.PRESENT, 0.0, 3.0)
    fast = Decision(State.AWAY, 1.0, 3.0)
    assert poll_delay(CFG, slow) == CFG.interval
    assert poll_delay(CFG, fast) == CFG.alert_interval


def test_config_rejects_impossible_settings():
    with pytest.raises(ValueError):
        Config(warn_before=5.0, timeout=3.0).validate()
    with pytest.raises(ValueError):
        Config(threshold=1.5).validate()
    with pytest.raises(ValueError):
        Config(lock_method="explode").validate()
