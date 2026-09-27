"""The watch loop end to end, with the camera, models and macOS stubbed out."""
import numpy as np
import cv2

from facelock import config, macos, vision, watcher
from facelock.identity import Enrollment

DIM = 512


def unit(seed):
    vec = np.random.default_rng(seed).normal(size=DIM).astype(np.float32)
    return vec / np.linalg.norm(vec)


ME = unit(1)


class FakeCamera:
    def __init__(self, cfg):
        self.is_open = False

    def open(self):
        self.is_open = True

    def read(self):
        return np.zeros((2, 2, 3), dtype=np.uint8)

    def release(self):
        self.is_open = False


class ScriptedEngine:
    """Yields the scripted (faces, embeddings) per check, last entry forever."""

    script = []
    recognizer = "arcface"

    def __init__(self, cfg, recognizer="arcface"):
        self.recognizer = recognizer

    def faces_and_embeddings(self, frame):
        item = ScriptedEngine.script[0]
        if len(ScriptedEngine.script) > 1:
            ScriptedEngine.script.pop(0)
        return item


class FakeAwake:
    calls = []

    def start(self):
        FakeAwake.calls.append("start")

    def stop(self):
        FakeAwake.calls.append("stop")


def drive(monkeypatch, cfg, script, checks, locked_after_lock=True, on_status=lambda message: None):
    """Run the loop for `checks` decisions; the screen reads locked right after a lock."""
    ScriptedEngine.script = list(script)
    FakeAwake.calls = []
    state = {"locked": False, "locks": 0, "seen": 0}
    monkeypatch.setattr(vision, "Camera", FakeCamera)
    monkeypatch.setattr(vision, "FaceEngine", ScriptedEngine)
    monkeypatch.setattr(vision, "warmup", lambda camera: None)
    monkeypatch.setattr(macos, "StayAwake", FakeAwake)
    monkeypatch.setattr(macos, "warn", lambda cfg, message: None)
    monkeypatch.setattr(watcher, "_sleep", lambda seconds, should_stop: None)
    monkeypatch.setattr(watcher.time, "sleep", lambda seconds: None)

    def lock(method):
        state["locks"] += 1
        state["locked"] = locked_after_lock

    def screen_locked():
        if state["locked"]:  # one locked tick, then the user unlocks
            state["locked"] = False
            return True
        return False

    monkeypatch.setattr(macos, "lock", lock)
    monkeypatch.setattr(macos, "screen_locked", screen_locked)
    decisions = []

    def observe(decision, reading):
        decisions.append(decision)
        state["seen"] += 1

    watcher.run(cfg, Enrollment({"me": np.array([ME])}), observe,
                should_stop=lambda: state["seen"] >= checks and state["locks"] >= 1,
                on_status=on_status)
    return decisions, state


ABSENT = (0, np.empty((0, DIM), dtype=np.float32))
PRESENT = (1, np.array([ME]))


def test_cached_enrollment_warning_visible_while_protection_continues(monkeypatch):
    monkeypatch.setattr(Enrollment, "error", "Could not reload enrollment", raising=False)
    statuses = []
    decisions, state = drive(monkeypatch, config.Config(frames_per_check=1),
                             [PRESENT, ABSENT, ABSENT, ABSENT], checks=4,
                             on_status=statuses.append)
    assert state["locks"] == 1
    assert any("Could not reload enrollment" in message for message in statuses)


def test_lock_holds_off_sleep_until_the_screen_is_unlocked(monkeypatch):
    cfg = config.Config(confirm_checks=2, frames_per_check=1, stay_awake=True)
    decisions, state = drive(monkeypatch, cfg, [ABSENT, ABSENT, PRESENT], checks=3)
    # the locked tick resets the tracker, so coming back after a lock is not a RETURN event
    assert [d.event for d in decisions] == [watcher.Event.WARN, watcher.Event.LOCK, None]
    assert decisions[-1].state is watcher.State.PRESENT
    assert state["locks"] == 1
    # engaged at the lock, released when the unlocked screen is next seen, and again on exit
    assert FakeAwake.calls == ["start", "stop", "stop"]


def test_stay_awake_off_never_touches_sleep(monkeypatch):
    cfg = config.Config(confirm_checks=2, frames_per_check=1, stay_awake=False)
    drive(monkeypatch, cfg, [ABSENT, ABSENT, PRESENT], checks=3)
    assert FakeAwake.calls == ["stop"]  # only the unconditional release on exit


def test_engine_follows_the_enrollment_recognizer(monkeypatch):
    from facelock import identity

    cfg = config.Config()
    ScriptedEngine.script = [PRESENT]
    monkeypatch.setattr(vision, "FaceEngine", ScriptedEngine)
    legacy = identity.Enrollment({"me": np.array([unit(1)[:128] / np.linalg.norm(unit(1)[:128])])},
                                 "sface")
    engine = watcher._engine_for(cfg, legacy, None)
    assert engine.recognizer == "sface"
    upgraded = identity.Enrollment({"me": np.array([ME])})
    assert watcher._engine_for(cfg, upgraded, engine).recognizer == "arcface"
    assert watcher._engine_for(cfg, upgraded, engine) is not engine


def test_camera_failures_are_reported_and_count_toward_lock(monkeypatch):
    class BrokenCamera(FakeCamera):
        opens = 0

        def open(self):
            BrokenCamera.opens += 1
            raise vision.CameraError("camera unavailable")

    cfg = config.Config(confirm_checks=2, frames_per_check=1)
    state = {"locks": 0, "checks": 0}
    statuses = []
    monkeypatch.setattr(vision, "Camera", BrokenCamera)
    monkeypatch.setattr(vision, "FaceEngine", ScriptedEngine)
    monkeypatch.setattr(macos, "StayAwake", FakeAwake)
    monkeypatch.setattr(macos, "screen_locked", lambda: False)
    monkeypatch.setattr(macos, "lock", lambda method: state.__setitem__("locks", state["locks"] + 1))
    monkeypatch.setattr(watcher, "_sleep", lambda seconds, should_stop: None)

    def observe(_decision, _reading):
        state["checks"] += 1

    watcher.run(cfg, Enrollment({"me": np.array([ME])}), observe, on_status=statuses.append,
                should_stop=lambda: state["locks"] == 1)
    assert BrokenCamera.opens == 4
    assert state == {"locks": 1, "checks": 2}
    assert any("camera unavailable" in status for status in statuses)


def test_persistent_camera_status_follows_observer_and_includes_checks_remaining(monkeypatch):
    class BrokenCamera(FakeCamera):
        def open(self):
            raise vision.CameraError("camera unavailable")

    cfg = config.Config(confirm_checks=2, frames_per_check=1)
    trace = []
    state = {"observed": 0}
    monkeypatch.setattr(vision, "Camera", BrokenCamera)
    monkeypatch.setattr(vision, "FaceEngine", ScriptedEngine)
    monkeypatch.setattr(macos, "StayAwake", FakeAwake)
    monkeypatch.setattr(macos, "screen_locked", lambda: False)
    monkeypatch.setattr(watcher, "_sleep", lambda seconds, should_stop: None)

    def observe(_decision, _reading):
        state["observed"] += 1
        trace.append("observer")

    watcher.run(cfg, Enrollment({"me": np.array([ME])}), observe, dry_run=True,
                on_status=lambda status: trace.append(status),
                should_stop=lambda: state["observed"] == 1 and trace[-1].startswith(
                    "camera read failed (3 in a row) -"))
    assert trace[-2] == "observer"
    assert trace[-1] == "camera read failed (3 in a row) - 1 check remaining before lock"


def test_opencv_read_failure_is_recoverable(monkeypatch):
    class BrokenReadCamera(FakeCamera):
        reads = 0

        def read(self):
            BrokenReadCamera.reads += 1
            raise cv2.error("read failed")

    cfg = config.Config(confirm_checks=1, frames_per_check=1)
    monkeypatch.setattr(vision, "Camera", BrokenReadCamera)
    monkeypatch.setattr(vision, "FaceEngine", ScriptedEngine)
    monkeypatch.setattr(vision, "warmup", lambda camera: None)
    monkeypatch.setattr(macos, "StayAwake", FakeAwake)
    monkeypatch.setattr(macos, "screen_locked", lambda: False)
    monkeypatch.setattr(macos, "lock", lambda method: None)
    monkeypatch.setattr(watcher, "_sleep", lambda seconds, should_stop: None)
    statuses = []
    watcher.run(cfg, Enrollment({"me": np.array([ME])}), lambda *_args: None,
                on_status=statuses.append, dry_run=True,
                should_stop=lambda: BrokenReadCamera.reads >= 3)
    assert any("read failed" in status for status in statuses)


def test_pause_after_capture_prevents_observe_and_lock(monkeypatch):
    cfg = config.Config(confirm_checks=1, frames_per_check=1)
    state = {"paused": False, "stopped": False, "locks": 0, "observed": 0}
    class PausingCamera(FakeCamera):
        def read(self):
            state["paused"] = True
            return super().read()
    monkeypatch.setattr(vision, "Camera", PausingCamera)
    monkeypatch.setattr(vision, "FaceEngine", ScriptedEngine)
    ScriptedEngine.script = [ABSENT]
    monkeypatch.setattr(vision, "warmup", lambda camera: None)
    monkeypatch.setattr(macos, "StayAwake", FakeAwake)
    monkeypatch.setattr(macos, "screen_locked", lambda: False)
    monkeypatch.setattr(macos, "lock", lambda method: state.__setitem__("locks", 1))
    monkeypatch.setattr(watcher, "_sleep", lambda seconds, should_stop: state.__setitem__("stopped", True))
    watcher.run(cfg, Enrollment({"me": np.array([ME])}),
                lambda *_args: state.__setitem__("observed", 1), paused=lambda: state["paused"],
                should_stop=lambda: state["stopped"])
    assert state["locks"] == state["observed"] == 0


def test_stop_after_capture_prevents_observe_and_lock(monkeypatch):
    cfg = config.Config(confirm_checks=1, frames_per_check=1)
    state = {"stopped": False, "locks": 0, "observed": 0}
    class StoppingCamera(FakeCamera):
        def read(self):
            state["stopped"] = True
            return super().read()
    monkeypatch.setattr(vision, "Camera", StoppingCamera)
    monkeypatch.setattr(vision, "FaceEngine", ScriptedEngine)
    ScriptedEngine.script = [ABSENT]
    monkeypatch.setattr(vision, "warmup", lambda camera: None)
    monkeypatch.setattr(macos, "StayAwake", FakeAwake)
    monkeypatch.setattr(macos, "screen_locked", lambda: False)
    monkeypatch.setattr(macos, "lock", lambda method: state.__setitem__("locks", 1))
    watcher.run(cfg, Enrollment({"me": np.array([ME])}),
                lambda *_args: state.__setitem__("observed", 1),
                should_stop=lambda: state["stopped"])
    assert state["locks"] == state["observed"] == 0


def test_camera_retry_delay_is_bounded_for_large_failure_counts():
    assert watcher._failure_delay(10_000) == watcher.FAILURE_RETRY_MAX


def test_pause_resets_camera_failure_streak(monkeypatch):
    class BrokenCamera(FakeCamera):
        attempts = 0

        def open(self):
            BrokenCamera.attempts += 1
            raise vision.CameraError("camera unavailable")

    state = {"paused": False, "stopped": False}
    statuses = []
    monkeypatch.setattr(vision, "Camera", BrokenCamera)
    monkeypatch.setattr(vision, "FaceEngine", ScriptedEngine)
    monkeypatch.setattr(macos, "StayAwake", FakeAwake)
    monkeypatch.setattr(macos, "screen_locked", lambda: False)

    def sleep(_seconds, _should_stop):
        if BrokenCamera.attempts == 2 and not state["paused"]:
            state["paused"] = True
        elif state["paused"]:
            state["paused"] = False
        elif BrokenCamera.attempts == 3:
            state["stopped"] = True

    monkeypatch.setattr(watcher, "_sleep", sleep)
    watcher.run(config.Config(frames_per_check=1), Enrollment({"me": np.array([ME])}),
                lambda *_args: None, paused=lambda: state["paused"],
                should_stop=lambda: state["stopped"], on_status=statuses.append)
    assert [status for status in statuses if status.startswith("camera read failed (")] == [
        "camera read failed (1 in a row)",
        "camera read failed (2 in a row)",
        "camera read failed (1 in a row)",
    ]


def test_screen_lock_resets_camera_failure_streak(monkeypatch):
    class BrokenCamera(FakeCamera):
        attempts = 0

        def open(self):
            BrokenCamera.attempts += 1
            raise vision.CameraError("camera unavailable")

    state = {"locked": False, "stopped": False}
    statuses = []
    monkeypatch.setattr(vision, "Camera", BrokenCamera)
    monkeypatch.setattr(vision, "FaceEngine", ScriptedEngine)
    monkeypatch.setattr(macos, "StayAwake", FakeAwake)
    monkeypatch.setattr(macos, "screen_locked", lambda: state["locked"])

    def sleep(_seconds, _should_stop):
        if BrokenCamera.attempts == 2 and not state["locked"]:
            state["locked"] = True
        elif state["locked"]:
            state["locked"] = False
        elif BrokenCamera.attempts == 3:
            state["stopped"] = True

    monkeypatch.setattr(watcher, "_sleep", sleep)
    watcher.run(config.Config(frames_per_check=1), Enrollment({"me": np.array([ME])}),
                lambda *_args: None, should_stop=lambda: state["stopped"],
                on_status=statuses.append)
    assert [status for status in statuses if status.startswith("camera read failed (")] == [
        "camera read failed (1 in a row)",
        "camera read failed (2 in a row)",
        "camera read failed (1 in a row)",
    ]


def test_failed_lock_retries_after_backoff_and_fresh_absent_check(monkeypatch):
    cfg = config.Config(confirm_checks=3, frames_per_check=1)
    ScriptedEngine.script = [ABSENT] * 4
    state = {"attempts": 0, "checks_at_lock": [], "seen": 0, "backoffs": 0}
    monkeypatch.setattr(vision, "Camera", FakeCamera)
    monkeypatch.setattr(vision, "FaceEngine", ScriptedEngine)
    monkeypatch.setattr(vision, "warmup", lambda camera: None)
    monkeypatch.setattr(macos, "StayAwake", FakeAwake)
    monkeypatch.setattr(macos, "screen_locked", lambda: False)
    monkeypatch.setattr(macos, "warn", lambda *_args: None)

    def lock(_method):
        state["attempts"] += 1
        state["checks_at_lock"].append(state["seen"])
        if state["attempts"] == 1:
            raise RuntimeError("lock failed")

    def sleep(seconds, _should_stop):
        if seconds == watcher.FAILURE_RETRY_MAX and state["attempts"] == 1:
            state["backoffs"] += 1

    monkeypatch.setattr(macos, "lock", lock)
    monkeypatch.setattr(watcher, "_sleep", sleep)
    watcher.run(cfg, Enrollment({"me": np.array([ME])}),
                lambda *_args: state.__setitem__("seen", state["seen"] + 1),
                should_stop=lambda: state["attempts"] == 2)
    assert state == {"attempts": 2, "checks_at_lock": [3, 4], "seen": 4, "backoffs": 1}


def test_owner_return_cancels_failed_lock_retry(monkeypatch):
    cfg = config.Config(confirm_checks=2, frames_per_check=1)
    ScriptedEngine.script = [ABSENT, ABSENT, PRESENT, ABSENT]
    state = {"attempts": 0, "seen": 0}
    monkeypatch.setattr(vision, "Camera", FakeCamera)
    monkeypatch.setattr(vision, "FaceEngine", ScriptedEngine)
    monkeypatch.setattr(vision, "warmup", lambda camera: None)
    monkeypatch.setattr(macos, "StayAwake", FakeAwake)
    monkeypatch.setattr(macos, "screen_locked", lambda: False)
    monkeypatch.setattr(macos, "warn", lambda *_args: None)
    monkeypatch.setattr(watcher, "_sleep", lambda *_args: None)

    def lock(_method):
        state["attempts"] += 1
        raise RuntimeError("lock failed")

    monkeypatch.setattr(macos, "lock", lock)
    watcher.run(cfg, Enrollment({"me": np.array([ME])}),
                lambda *_args: state.__setitem__("seen", state["seen"] + 1),
                should_stop=lambda: state["seen"] == 4)
    assert state == {"attempts": 1, "seen": 4}


def test_pause_cancels_failed_lock_retry(monkeypatch):
    cfg = config.Config(confirm_checks=3, frames_per_check=1)
    ScriptedEngine.script = [ABSENT] * 5
    state = {"attempts": 0, "seen": 0, "paused": False, "backoff_done": False}
    monkeypatch.setattr(vision, "Camera", FakeCamera)
    monkeypatch.setattr(vision, "FaceEngine", ScriptedEngine)
    monkeypatch.setattr(vision, "warmup", lambda camera: None)
    monkeypatch.setattr(macos, "StayAwake", FakeAwake)
    monkeypatch.setattr(macos, "screen_locked", lambda: False)
    monkeypatch.setattr(macos, "warn", lambda *_args: None)

    def lock(_method):
        state["attempts"] += 1
        raise RuntimeError("lock failed")

    def sleep(_seconds, _should_stop):
        if state["attempts"] == 1 and not state["backoff_done"]:
            state["paused"] = True
            state["backoff_done"] = True
        elif state["paused"]:
            state["paused"] = False

    monkeypatch.setattr(macos, "lock", lock)
    monkeypatch.setattr(watcher, "_sleep", sleep)
    watcher.run(cfg, Enrollment({"me": np.array([ME])}),
                lambda *_args: state.__setitem__("seen", state["seen"] + 1),
                paused=lambda: state["paused"],
                should_stop=lambda: state["seen"] == 5 or state["attempts"] == 2)
    assert state["attempts"] == 1
    assert state["seen"] == 5


def test_pause_from_observer_prevents_lock(monkeypatch):
    cfg = config.Config(confirm_checks=1, frames_per_check=1)
    ScriptedEngine.script = [ABSENT]
    state = {"paused": False, "stopped": False, "locks": 0}
    monkeypatch.setattr(vision, "Camera", FakeCamera)
    monkeypatch.setattr(vision, "FaceEngine", ScriptedEngine)
    monkeypatch.setattr(vision, "warmup", lambda camera: None)
    monkeypatch.setattr(macos, "StayAwake", FakeAwake)
    monkeypatch.setattr(macos, "screen_locked", lambda: False)
    monkeypatch.setattr(macos, "lock", lambda _method: state.__setitem__("locks", 1))
    monkeypatch.setattr(watcher, "_sleep", lambda *_args: state.__setitem__("stopped", True))
    watcher.run(cfg, Enrollment({"me": np.array([ME])}),
                lambda *_args: state.__setitem__("paused", True),
                paused=lambda: state["paused"], should_stop=lambda: state["stopped"])
    assert state["locks"] == 0


def test_stop_from_observer_prevents_lock(monkeypatch):
    cfg = config.Config(confirm_checks=1, frames_per_check=1)
    ScriptedEngine.script = [ABSENT]
    state = {"stopped": False, "locks": 0}
    monkeypatch.setattr(vision, "Camera", FakeCamera)
    monkeypatch.setattr(vision, "FaceEngine", ScriptedEngine)
    monkeypatch.setattr(vision, "warmup", lambda camera: None)
    monkeypatch.setattr(macos, "StayAwake", FakeAwake)
    monkeypatch.setattr(macos, "screen_locked", lambda: False)
    monkeypatch.setattr(macos, "lock", lambda _method: state.__setitem__("locks", 1))
    watcher.run(cfg, Enrollment({"me": np.array([ME])}),
                lambda *_args: state.__setitem__("stopped", True),
                should_stop=lambda: state["stopped"])
    assert state["locks"] == 0


def test_lock_failure_is_reported_without_starting_stay_awake(monkeypatch):
    cfg = config.Config(confirm_checks=1, frames_per_check=1, stay_awake=True)
    ScriptedEngine.script = [ABSENT]
    FakeAwake.calls = []
    statuses = []
    state = {"attempts": 0}
    monkeypatch.setattr(vision, "Camera", FakeCamera)
    monkeypatch.setattr(vision, "FaceEngine", ScriptedEngine)
    monkeypatch.setattr(vision, "warmup", lambda camera: None)
    monkeypatch.setattr(macos, "StayAwake", FakeAwake)
    monkeypatch.setattr(macos, "screen_locked", lambda: False)
    def fail_lock(_method):
        state["attempts"] += 1
        raise RuntimeError("lock did not engage")
    monkeypatch.setattr(macos, "lock", fail_lock)
    monkeypatch.setattr(watcher, "_sleep", lambda seconds, should_stop: None)
    watcher.run(cfg, Enrollment({"me": np.array([ME])}), lambda *_args: None,
                on_status=statuses.append,
                should_stop=lambda: state["attempts"] >= 1)
    assert FakeAwake.calls == ["stop"]
    assert statuses[-1] == "lock failed: lock did not engage"


def test_pause_after_unlock_releases_stay_awake(monkeypatch):
    cfg = config.Config(confirm_checks=1, frames_per_check=1, stay_awake=True)
    ScriptedEngine.script = [ABSENT]
    FakeAwake.calls = []
    state = {"locked_once": False, "paused": False, "stopped": False, "held_while_paused": None}
    monkeypatch.setattr(vision, "Camera", FakeCamera)
    monkeypatch.setattr(vision, "FaceEngine", ScriptedEngine)
    monkeypatch.setattr(vision, "warmup", lambda camera: None)
    monkeypatch.setattr(macos, "StayAwake", FakeAwake)
    monkeypatch.setattr(macos, "screen_locked", lambda: False)

    def lock(_method):
        state["locked_once"] = True

    def sleep(_seconds, _should_stop):
        if state["paused"]:
            state["held_while_paused"] = FakeAwake.calls.count("stop") == 0
            state["stopped"] = True
        elif state["locked_once"]:
            state["paused"] = True

    monkeypatch.setattr(macos, "lock", lock)
    monkeypatch.setattr(watcher, "_sleep", sleep)
    watcher.run(cfg, Enrollment({"me": np.array([ME])}), lambda *_args: None,
                paused=lambda: state["paused"], should_stop=lambda: state["stopped"])
    assert state["held_while_paused"] is False


def test_enrollment_threshold_cannot_be_weakened_by_config(monkeypatch):
    probe = 0.8 * ME + 0.6 * unit(2)
    probe = probe / np.linalg.norm(probe)
    cfg = config.Config(threshold=0.1, confirm_checks=2, frames_per_check=1)
    ScriptedEngine.script = [(1, np.array([probe]))]
    monkeypatch.setattr(vision, "Camera", FakeCamera)
    monkeypatch.setattr(vision, "FaceEngine", ScriptedEngine)
    monkeypatch.setattr(vision, "warmup", lambda camera: None)
    monkeypatch.setattr(macos, "StayAwake", FakeAwake)
    monkeypatch.setattr(macos, "screen_locked", lambda: False)
    monkeypatch.setattr(macos, "warn", lambda cfg, message: None)
    monkeypatch.setattr(watcher, "_sleep", lambda seconds, should_stop: None)
    decisions = []
    enrollment = Enrollment({"me": np.array([ME])}, threshold=0.9)
    watcher.run(cfg, enrollment, lambda decision, reading: decisions.append(decision), dry_run=True,
                should_stop=lambda: len(decisions) == 1)
    assert decisions[0].state is watcher.State.STRANGER
