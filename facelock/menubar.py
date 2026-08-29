"""The menu bar app: the watcher plus a glyph, pause controls and a login toggle."""

from __future__ import annotations

import threading

from . import config, control, identity, macos, vision
from .watcher import Decision, Event, Reading, State, run

# emoji-presentation glyphs; the bare text forms render nearly invisible in the menu bar
GLYPH = {State.PRESENT: "👀", State.AWAY: "💤", State.STRANGER: "⚠️"}
PAUSED_GLYPH = "⏸️"
REFRESH_SECONDS = 0.5


class _Shared:
    """Watcher thread writes, menu bar thread reads. One assignment, no locking needed."""

    def __init__(self, cfg: config.Config) -> None:
        self._cfg = cfg
        self.title = GLYPH[State.PRESENT]
        self.detail = "starting"

    def update(self, decision: Decision, reading: Reading) -> None:
        self.title = GLYPH[decision.state]
        if decision.event is Event.WARN:
            wait = (self._cfg.stranger_interval if decision.state is State.STRANGER
                    else self._cfg.recheck_interval)
            macos.warn(self._cfg, f"locking in ~{wait:.0f}s unless I see you")
        if decision.event is Event.LOCK:
            self.detail = "locked"
        elif decision.state is State.PRESENT:
            self.detail = f"here (score {reading.match.score:+.2f})"
        else:
            self.detail = (
                f"not seen - check {decision.misses} of {decision.needed} "
                f"(score {reading.match.score:+.2f})"
            )


def main(cfg: config.Config, dry_run: bool = False) -> int:
    try:
        import rumps
    except ImportError:
        raise SystemExit("menu bar mode needs rumps: .venv/bin/pip install rumps")

    enrollment = identity.require()
    config.ensure_dirs()
    vision.silence_opencv_logs()
    control.setup_logging()
    control.write_pid()
    shared = _Shared(cfg)
    stopping = threading.Event()

    class FaceLockApp(rumps.App):
        def __init__(self) -> None:
            super().__init__("facelock", title=shared.title, quit_button=None)
            self.status_item = rumps.MenuItem("starting")
            self.login_item = rumps.MenuItem("Start at Login", callback=self.toggle_login)
            self.login_item.state = macos.agent_installed()
            self.menu = [
                self.status_item,
                None,
                rumps.MenuItem("Lock Now", callback=self.lock_now),
                None,
                rumps.MenuItem("Pause 15 minutes", callback=self.pause_15),
                rumps.MenuItem("Pause 1 hour", callback=self.pause_hour),
                rumps.MenuItem("Pause until resumed", callback=self.pause_forever),
                rumps.MenuItem("Resume", callback=self.resume),
                None,
                self.login_item,
                rumps.MenuItem("Quit", callback=self.quit),
            ]

        @rumps.timer(REFRESH_SECONDS)
        def refresh(self, _) -> None:
            paused = control.is_paused()
            self.title = PAUSED_GLYPH if paused else shared.title
            self.status_item.title = "paused" if paused else shared.detail

        def lock_now(self, _) -> None:
            macos.lock(cfg.lock_method)

        def pause_15(self, _) -> None:
            control.pause(15 * 60)

        def pause_hour(self, _) -> None:
            control.pause(60 * 60)

        def pause_forever(self, _) -> None:
            control.pause(control.FOREVER)

        def resume(self, _) -> None:
            control.resume()

        def toggle_login(self, _) -> None:
            if macos.agent_installed():
                macos.uninstall_agent()
            else:
                macos.install_agent()
            self.login_item.state = macos.agent_installed()

        def quit(self, _) -> None:
            stopping.set()
            rumps.quit_application()

    worker = threading.Thread(
        target=run,
        args=(cfg, enrollment, shared.update),
        kwargs={
            "dry_run": dry_run,
            "paused": control.is_paused,
            "should_stop": stopping.is_set,
        },
        daemon=True,
    )
    worker.start()
    try:
        FaceLockApp().run()
    finally:
        stopping.set()
        control.clear_pid()
    return 0
