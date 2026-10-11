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


def test_preview_reports_would_lock_not_locked():
    from facelock.identity import NO_MATCH
    from facelock.watcher import Decision, Event, Reading, State

    shared = menubar._Shared(preview=True)
    shared.update(Decision(State.AWAY, 3, 3, Event.LOCK), Reading(NO_MATCH, 0))
    assert "would lock" in shared.detail
    assert "locked" not in shared.detail


def test_normal_mode_does_not_report_lock_before_confirmation():
    from facelock.identity import NO_MATCH
    from facelock.watcher import Decision, Event, Reading, State

    shared = menubar._Shared()
    shared.update(Decision(State.AWAY, 3, 3, Event.LOCK), Reading(NO_MATCH, 0))
    assert "lock requested" in shared.detail
    assert "locked" not in shared.detail


def test_status_tells_a_stranger_apart_from_an_empty_chair():
    from facelock.identity import NO_MATCH
    from facelock.watcher import Decision, Reading, State

    shared = menubar._Shared()
    shared.update(Decision(State.STRANGER, 1, 3), Reading(NO_MATCH, 1))
    assert shared.detail.startswith("someone else in frame")
    assert "next 2 checks miss" in shared.detail
    shared.update(Decision(State.AWAY, 2, 3), Reading(NO_MATCH, 0))
    assert shared.detail.startswith("you're away")
    assert "next check misses" in shared.detail


def test_switching_preview_cancels_old_run_and_keeps_one_worker(monkeypatch):
    calls = []
    active = []
    monkeypatch.setattr(identity, "Live", lambda: object())

    def run(cfg, enrollment, observer, **kwargs):
        active.append(1)
        assert len(active) == 1
        calls.append(kwargs["dry_run"])
        while not kwargs["should_stop"]():
            time.sleep(.001)
        active.pop()

    monkeypatch.setattr(menubar, "run", run)
    shared = menubar._Shared()
    watcher = menubar._Watcher(shared, False)
    try:
        watcher.start(config.Config())
        until(lambda: calls == [False])
        watcher.set_preview(True)
        until(lambda: calls == [False, True])
        assert watcher.preview and shared.preview
        watcher.set_preview(False)
        until(lambda: calls == [False, True, False])
        assert not watcher.preview and not shared.preview
    finally:
        watcher.stop()


def launch_fake_app(monkeypatch, dry_run=False):
    import sys
    from types import SimpleNamespace

    class Item:
        def __init__(self, title, callback=None):
            self.title, self.callback = title, callback
            self.state = False
            self.items = []

        def add(self, item):
            self.items.append(item)

    apps = []
    class App:
        def __init__(self, *args, **kwargs):
            apps.append(self)

        def run(self):
            pass

    workers = []
    class Worker:
        def __init__(self, shared, preview):
            self.preview = preview
            self.restarts = 0
            workers.append(self)

        @property
        def requested_preview(self):
            return self.preview

        def start(self, cfg):
            pass

        def stop(self):
            pass

        def restart(self, cfg):
            self.restarts += 1

        def set_preview(self, enabled):
            self.preview = enabled

    monkeypatch.setitem(sys.modules, "rumps", SimpleNamespace(
        App=App, MenuItem=Item, separator=None, timer=lambda _: lambda f: f))
    monkeypatch.setitem(sys.modules, "AppKit", SimpleNamespace(
        NSApplication=SimpleNamespace(sharedApplication=lambda: SimpleNamespace(
            setActivationPolicy_=lambda _: None)), NSApplicationActivationPolicyAccessory=1))
    monkeypatch.setattr(menubar, "_Watcher", Worker)
    monkeypatch.setattr(menubar.control, "running_pid", lambda: None)
    for module, name in ((config, "ensure_dirs"), (menubar.control, "setup_logging"),
                         (menubar.control, "write_pid"), (menubar.control, "clear_pid"),
                         (menubar.vision, "silence_opencv_logs")):
        monkeypatch.setattr(module, name, lambda: None)
    monkeypatch.setattr(menubar.macos, "agent_installed", lambda: False)
    menubar.main(config.Config(), dry_run=dry_run)
    apps[0]._test_worker = workers[0]
    return apps[0]


def test_preview_menu_blocks_manual_lock(monkeypatch):
    locks = []
    monkeypatch.setattr(menubar.macos, "lock", locks.append)
    app = launch_fake_app(monkeypatch, dry_run=True)
    app.lock_now(None)
    assert locks == []
    assert app.preview_item.state
    app.toggle_preview(None)
    app.lock_now(None)
    assert locks == ["suspend"]
    assert not app.preview_item.state


def test_preview_toggle_during_training_is_ignored(monkeypatch):
    app = launch_fake_app(monkeypatch)
    app.learning = "capturing"
    app.toggle_preview(None)
    assert not app.preview_item.state


def test_check_now_preserves_pause(monkeypatch):
    app = launch_fake_app(monkeypatch)
    resumed = []
    monkeypatch.setattr(menubar.control, "is_paused", lambda: True)
    monkeypatch.setattr(menubar.control, "resume", lambda: resumed.append(True))
    app.check_now(None)
    assert not resumed
    assert app._test_worker.restarts == 0


def test_check_now_requests_new_check_unless_training(monkeypatch):
    app = launch_fake_app(monkeypatch)
    monkeypatch.setattr(menubar.control, "is_paused", lambda: False)
    app.check_now(None)
    assert app._test_worker.restarts == 1
    app.learning = "capturing"
    app.check_now(None)
    assert app._test_worker.restarts == 1


def test_help_actions_open_privacy_and_logs(monkeypatch):
    app = launch_fake_app(monkeypatch)
    opened = []
    monkeypatch.setattr(menubar.subprocess, "run", lambda args, **kwargs: opened.append(args))
    app.open_camera_settings(None)
    app.open_log(None)
    assert opened == [
        ["open", "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"],
        ["open", "-a", "Console", str(config.LOG_FILE)],
    ]


def test_help_open_failure_is_reported(monkeypatch):
    app = launch_fake_app(monkeypatch)
    statuses = []
    monkeypatch.setattr(menubar._Shared, "status", lambda self, text: statuses.append(text))
    def fail(*args, **kwargs):
        raise OSError("could not open")
    monkeypatch.setattr(menubar.subprocess, "run", fail)
    app.open_log(None)
    assert statuses == ["could not open: could not open"]


def test_health_check_uses_read_only_diagnostics(monkeypatch):
    import sys
    app = launch_fake_app(monkeypatch)
    checks = [{"name": "camera", "status": "unverified", "detail": "not tested"}]
    alerts = []
    monkeypatch.setattr(menubar.diagnostics, "run_checks", lambda: checks)
    monkeypatch.setattr(sys.modules["rumps"], "alert", lambda **kw: alerts.append(kw), raising=False)
    app.health_check(None)
    assert "not tested" in alerts[0]["message"]


def test_preview_is_not_reported_active_until_old_worker_exits(monkeypatch):
    release = threading.Event()
    entered = threading.Event()
    monkeypatch.setattr(identity, "Live", lambda: object())
    def run(*args, **kwargs):
        if not kwargs["dry_run"]:
            entered.set()
            release.wait(2)
        else:
            while not kwargs["should_stop"]():
                time.sleep(.001)
    monkeypatch.setattr(menubar, "run", run)
    shared = menubar._Shared()
    watcher = menubar._Watcher(shared, False)
    try:
        watcher.start(config.Config())
        assert entered.wait(1)
        watcher.set_preview(True)
        assert not watcher.preview
        assert not shared.preview
        assert watcher.requested_preview
        release.set()
        until(lambda: watcher.preview)
    finally:
        release.set()
        watcher.stop()
