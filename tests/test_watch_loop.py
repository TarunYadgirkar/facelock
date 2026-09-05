"""The watch loop end to end, with the camera, models and macOS stubbed out."""
import numpy as np

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


def drive(monkeypatch, cfg, script, checks, locked_after_lock=True):
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
                should_stop=lambda: state["seen"] >= checks)
    return decisions, state


ABSENT = (0, np.empty((0, DIM), dtype=np.float32))
PRESENT = (1, np.array([ME]))


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
