import threading
import time

from facelock import config, identity, menubar


def until(predicate):
    deadline = time.monotonic() + 2
    while not predicate() and time.monotonic() < deadline:
        time.sleep(.005)
    assert predicate()


def test_worker_exception_is_visible_and_retried(monkeypatch):
    calls = []
    monkeypatch.setattr(identity, "Live", lambda: object())
    monkeypatch.setattr(menubar, "RETRY_SECONDS", .01, raising=False)

    def run(cfg, enrollment, observer, **kwargs):
        calls.append(1)
        raise ValueError("enrollment unreadable")

    monkeypatch.setattr(menubar, "run", run)
    shared = menubar._Shared()
    watcher = menubar._Watcher(shared, True)
    try:
        watcher.start(config.Config())
        until(lambda: len(calls) >= 2)
        assert "enrollment unreadable" in shared.detail
        assert "watching" not in shared.detail
    finally:
        watcher.stop()


def test_rapid_settings_changes_keep_one_camera_owner(monkeypatch):
    lock = threading.Lock()
    state = {"active": 0, "peak": 0, "seen": []}
    monkeypatch.setattr(identity, "Live", lambda: object())

    def run(cfg, enrollment, observer, **kwargs):
        with lock:
            state["active"] += 1
            state["peak"] = max(state["peak"], state["active"])
            state["seen"].append(cfg.interval)
        while not kwargs["should_stop"]():
            time.sleep(.001)
        with lock:
            state["active"] -= 1

    monkeypatch.setattr(menubar, "run", run)
    watcher = menubar._Watcher(menubar._Shared(), True)
    try:
        watcher.start(config.Config())
        until(lambda: state["active"] == 1)
        for value in range(1, 20):
            watcher.restart(config.Config(interval=float(value)))
        until(lambda: 19.0 in state["seen"])
        assert state["peak"] == 1
    finally:
        watcher.stop()
    assert state["active"] == 0


def test_stop_timeout_keeps_thread_owned(monkeypatch):
    release = threading.Event()
    entered = threading.Event()
    monkeypatch.setattr(identity, "Live", lambda: object())

    def run(*args, **kwargs):
        entered.set()
        release.wait(2)

    monkeypatch.setattr(menubar, "run", run)
    watcher = menubar._Watcher(menubar._Shared(), True)
    watcher.start(config.Config())
    assert entered.wait(1)
    try:
        assert watcher.stop(timeout=.01) is False
        assert watcher._thread is not None and watcher._thread.is_alive()
    finally:
        release.set()
        watcher.stop()


def test_restart_after_slow_stop_resumes_when_camera_releases(monkeypatch):
    release = threading.Event()
    calls = []
    monkeypatch.setattr(identity, "Live", lambda: object())

    def run(cfg, *args, **kwargs):
        calls.append(cfg.interval)
        if len(calls) == 1:
            release.wait(2)
        else:
            while not kwargs["should_stop"]():
                time.sleep(.001)

    monkeypatch.setattr(menubar, "run", run)
    watcher = menubar._Watcher(menubar._Shared(), True)
    try:
        watcher.start(config.Config())
        until(lambda: len(calls) == 1)
        assert watcher.stop(timeout=.01) is False
        watcher.restart(config.Config(interval=12))
        release.set()
        until(lambda: calls == [30.0, 12])
    finally:
        release.set()
        watcher.stop()


def test_quit_cancels_pending_restart(monkeypatch):
    release = threading.Event()
    calls = []
    monkeypatch.setattr(identity, "Live", lambda: object())
    def run(*args, **kwargs):
        calls.append(1)
        release.wait(2)
    monkeypatch.setattr(menubar, "run", run)
    watcher = menubar._Watcher(menubar._Shared(), True)
    watcher.start(config.Config())
    until(lambda: len(calls) == 1)
    watcher.stop(timeout=.01)
    watcher.restart(config.Config())
    watcher.stop(timeout=.01)
    release.set()
    watcher.stop()
    time.sleep(.03)
    assert calls == [1]
