"""The menu bar app: the watcher plus a status icon, pause controls and a login toggle."""

from __future__ import annotations

import threading
import time
from pathlib import Path

from . import config, control, identity, macos, vision
from .watcher import Decision, Event, Reading, State, run

# Phosphor icons (MIT), rendered as template images so they match light/dark menu bars
_ICONS = Path(__file__).parent / "icons"
ICON = {
    State.PRESENT: str(_ICONS / "eye-bold.svg"),
    State.AWAY: str(_ICONS / "eye-slash-bold.svg"),
    State.STRANGER: str(_ICONS / "warning-bold.svg"),
}
PAUSED_ICON = str(_ICONS / "pause-bold.svg")
REFRESH_SECONDS = 0.5


def _pause_label(expiry: float) -> str:
    if expiry == control.FOREVER:
        return "paused until resumed"
    left = max(0.0, expiry - time.time())
    return f"paused - {left / 60:.0f}m left" if left >= 60 else f"paused - {left:.0f}s left"


class _Shared:
    """Watcher thread writes, menu bar thread reads. One assignment, no locking needed."""

    def __init__(self) -> None:
        self.icon = ICON[State.PRESENT]
        self.detail = "starting"

    def update(self, decision: Decision, reading: Reading) -> None:
        self.icon = ICON[decision.state]
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
    shared = _Shared()
    stopping = threading.Event()

    class FaceLockApp(rumps.App):
        def __init__(self) -> None:
            super().__init__("facelock", icon=shared.icon, template=True, quit_button=None)
            self.status_item = rumps.MenuItem("starting")
            self.resume_item = rumps.MenuItem("Resume")
            self._was_paused = False
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
                self.resume_item,
                None,
                self.login_item,
                rumps.MenuItem("Quit", callback=self.quit),
            ]

        @rumps.timer(REFRESH_SECONDS)
        def refresh(self, _) -> None:
            expiry = control.pause_expiry()
            paused = expiry is not None
            want = PAUSED_ICON if paused else shared.icon
            if self.icon != want:
                self.icon = want
            label = _pause_label(expiry) if paused else shared.detail
            if self.status_item.title != label:
                self.status_item.title = label
            if paused != self._was_paused:  # Resume is grayed while watching
                self.resume_item.set_callback(self.resume if paused else None)
                self._was_paused = paused

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
