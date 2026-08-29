import pytest

from facelock.config import Config
from facelock.identity import Match
from facelock.watcher import (MIN_RECHECK, Decision, Event, PresenceTracker, Reading, State,
                              poll_delay)

CFG = Config(threshold=0.4, interval=30.0, recheck_interval=10.0,
             stranger_interval=2.0, confirm_checks=2)


def me(score=0.8):
    return Reading(Match(score, "me"), 1)


def nobody():
    return Reading(Match(0.0, None), 0)


def stranger(score=0.1):
    return Reading(Match(score, "me"), 1)


def test_present_while_i_match():
    decision = PresenceTracker(CFG).update(me())
    assert decision.state is State.PRESENT
    assert decision.event is None


def test_one_miss_warns_and_the_second_locks():
    tracker = PresenceTracker(CFG)
    assert tracker.update(nobody()).event is Event.WARN
    assert tracker.update(nobody()).event is Event.LOCK


def test_a_single_miss_never_locks():
    decision = PresenceTracker(CFG).update(nobody())
    assert decision.state is State.AWAY
    assert (decision.misses, decision.needed) == (1, 2)
    assert decision.event is not Event.LOCK


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
    assert tracker.update(nobody()).event is Event.LOCK


def test_a_visible_face_that_is_not_mine_is_a_stranger():
    assert PresenceTracker(CFG).update(stranger()).state is State.STRANGER


def test_single_check_config_locks_without_warning():
    assert PresenceTracker(Config(confirm_checks=1)).update(nobody()).event is Event.LOCK


def test_more_confirmations_delay_the_lock():
    tracker = PresenceTracker(Config(confirm_checks=3))
    assert [tracker.update(nobody()).event for _ in range(3)] == [None, Event.WARN, Event.LOCK]


@pytest.mark.parametrize(
    "state,expected",
    [
        (State.PRESENT, CFG.interval),
        (State.AWAY, CFG.recheck_interval),
        (State.STRANGER, CFG.stranger_interval),
    ],
)
def test_poll_delay_follows_the_state(state, expected):
    assert poll_delay(CFG, Decision(state, 1, 2)) == expected


def test_each_further_miss_rechecks_sooner():
    cfg = Config(recheck_interval=10.0, recheck_decay=0.5)
    waits = [poll_delay(cfg, Decision(State.AWAY, miss, 4)) for miss in (1, 2, 3)]
    assert waits == [10.0, 5.0, 2.5]


def test_rechecks_never_spin_faster_than_the_floor():
    cfg = Config(recheck_interval=4.0, recheck_decay=0.1)
    assert poll_delay(cfg, Decision(State.AWAY, 5, 6)) == MIN_RECHECK


@pytest.mark.parametrize(
    "kwargs",
    [
        {"threshold": 1.5},
        {"lock_method": "explode"},
        {"confirm_checks": 0},
        {"frames_per_check": 0},
        {"recheck_interval": 0.0},
        {"recheck_decay": 0.0},
        {"recheck_decay": 1.5},
        {"interval": 0.0},
    ],
)
def test_config_rejects_impossible_settings(kwargs):
    with pytest.raises(ValueError):
        Config(**kwargs).validate()
