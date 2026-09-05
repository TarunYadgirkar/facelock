"""The menu bar app: the watcher, plus training and settings, all without a terminal."""

from __future__ import annotations

import threading
import time
from dataclasses import replace
from pathlib import Path

from . import config, control, enroll, identity, macos, vision
from .watcher import Decision, Event, Reading, State, run

# Phosphor icons (MIT), rendered as template images so they match light/dark menu bars
_ICONS = Path(__file__).parent / "icons"
ICON = {
    State.PRESENT: str(_ICONS / "eye-bold.svg"),
    State.AWAY: str(_ICONS / "eye-slash-bold.svg"),
    State.STRANGER: str(_ICONS / "warning-bold.svg"),
}
PAUSED_ICON = str(_ICONS / "pause-bold.svg")
LEARNING_ICON = str(_ICONS / "student-bold.svg")

REFRESH_SECONDS = 0.5
LEARN_COUNTDOWN = 4.0  # seconds to get into the pose after clicking
LEARN_SAMPLES = 15
LEARN_WINDOW = 15.0  # give up if the pose never produces a clean face

# Training menu: label -> what to do while the countdown runs.
LESSONS = (
    ("Teach: looking at my screen", "look at your screen normally"),
    ("Teach: looking down at my phone", "look down at your phone"),
    ("Teach: looking down at the keyboard", "look down at the keyboard"),
    ("Teach: turned to one side", "turn your head to one side"),
    ("Teach: with AirPods in", "put your AirPods in and look at the screen"),
    ("Teach: without AirPods", "take your AirPods out and look at the screen"),
    ("Teach: whatever I am doing now", "hold still"),
)


def _pause_label(expiry: float) -> str:
    if expiry == control.FOREVER:
        return "paused until resumed"
    left = max(0.0, expiry - time.time())
    return f"paused - {left / 60:.0f}m left" if left >= 60 else f"paused - {left:.0f}s left"


class _Shared:
    """Watcher thread writes, menu bar thread reads. One assignment, no locking needed."""

    def __init__(self) -> None:
        self.icon = ICON[State.PRESENT]
        self.detail = "watching"

    def update(self, decision: Decision, reading: Reading) -> None:
        self.icon = ICON[decision.state]
        score = f"match {reading.match.score:.2f}"
        if decision.event is Event.LOCK:
            self.detail = f"locked ({score})"
        elif decision.state is State.PRESENT:
            self.detail = f"watching - {score}"
        else:
            left = decision.needed - decision.misses
            self.detail = f"not seen - {left} checks from locking ({score})"


class _Watcher:
    """Owns the watcher thread so a settings change can restart it with the new config."""

    def __init__(self, shared: _Shared, dry_run: bool) -> None:
        self._shared = shared
        self._dry_run = dry_run
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self, cfg: config.Config) -> None:
        self.stop()
        self._stop = threading.Event()
        self._thread = threading.Thread(
            target=run,
            args=(cfg, identity.Live(), self._shared.update),
            kwargs={
                "dry_run": self._dry_run,
                "paused": control.is_paused,
                "should_stop": self._stop.is_set,
            },
            daemon=True,
        )
        self._thread.start()

    def stop(self, timeout: float = 10.0) -> None:
        """Returns once the watcher has let go of the camera."""
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=timeout)
            self._thread = None

    def restart(self, cfg: config.Config) -> None:
        """Off the main thread: stopping waits for a check to finish, which would freeze the menu."""
        threading.Thread(target=self.start, args=(cfg,), daemon=True).start()


def main(cfg: config.Config, dry_run: bool = False) -> int:
    try:
        import AppKit
        import rumps
    except ImportError:
        raise SystemExit("menu bar mode needs rumps: .venv/bin/pip install rumps")

    running = control.running_pid()
    if running is not None:
        # Opening the app while it is already up would put a second eye in the menu bar and a
        # second process on the camera. Exit 0 so launchd's KeepAlive does not retry in a loop.
        macos.banner("facelock", "already running - the eye is in the menu bar")
        print(f"facelock is already running (pid {running})")
        return 0

    identity.require()
    config.ensure_dirs()
    vision.silence_opencv_logs()
    control.setup_logging()
    control.write_pid()
    shared = _Shared()
    watcher = _Watcher(shared, dry_run)

    class FaceLockApp(rumps.App):
        def __init__(self) -> None:
            super().__init__("FaceLock", icon=shared.icon, template=True, quit_button=None)
            self.cfg = cfg
            self.learning = ""  # non-empty while a lesson is capturing
            self._named = False  # rumps builds the status item in run(), not here
            self.status_item = rumps.MenuItem("starting")
            self.resume_item = rumps.MenuItem("Resume")
            self._was_paused = False
            self.menu = [
                self.status_item,
                None,
                rumps.MenuItem("Lock Now", callback=self.lock_now),
                rumps.MenuItem("Pause 15 minutes", callback=self.pause_15),
                rumps.MenuItem("Pause 1 hour", callback=self.pause_hour),
                rumps.MenuItem("Pause until resumed", callback=self.pause_forever),
                self.resume_item,
                None,
                self._training_menu(),
                self._settings_menu(),
                None,
                rumps.MenuItem("Quit FaceLock", callback=self.quit),
            ]
            watcher.start(self.cfg)

        # --- menus ---------------------------------------------------------

        def _training_menu(self) -> rumps.MenuItem:
            menu = rumps.MenuItem("Training")
            self.enrollment_item = rumps.MenuItem("counting what it knows")
            self._enrollment_stamp = None
            self.threshold_item = rumps.MenuItem("")
            self.upgrade_item = rumps.MenuItem(
                "Start Over to upgrade recognition - the old model let strangers through")
            menu.add(self.enrollment_item)
            menu.add(self.threshold_item)
            menu.add(self.upgrade_item)
            menu.add(rumps.separator)
            for label, hint in LESSONS:
                item = rumps.MenuItem(label, callback=self._lesson_callback(label, hint))
                menu.add(item)
            menu.add(rumps.separator)
            menu.add(rumps.MenuItem("Start Over (full enrollment)", callback=self.re_enroll))
            return menu

        def _settings_menu(self) -> rumps.MenuItem:
            menu = rumps.MenuItem("Settings")
            self.preset_items = {}
            for name in config.PRESETS:
                item = rumps.MenuItem(name, callback=self._preset_callback(name))
                self.preset_items[name] = item
                menu.add(item)
            menu.add(rumps.separator)
            self.lock_item = rumps.MenuItem("Also turn the display off",
                                            callback=self.toggle_lock_method)
            self.sound_item = rumps.MenuItem("Warning sound", callback=self.toggle_sound)
            self.notify_item = rumps.MenuItem("Warning banner", callback=self.toggle_notify)
            self.awake_item = rumps.MenuItem("Stay awake while locked",
                                             callback=self.toggle_stay_awake)
            self.login_item = rumps.MenuItem("Start at Login", callback=self.toggle_login)
            for item in (self.lock_item, self.awake_item, self.sound_item, self.notify_item):
                menu.add(item)
            menu.add(rumps.separator)
            menu.add(self.login_item)
            self._sync_settings()
            return menu

        def _sync_settings(self) -> None:
            active = config.preset_of(self.cfg)
            for name, item in self.preset_items.items():
                item.state = name == active
                values = config.PRESETS[name]
                grace = config.grace_seconds(replace(self.cfg, **values))
                item.title = f"{name} - locks ~{grace / 60:.0f} min after you leave" if grace >= 90 \
                    else f"{name} - locks ~{grace:.0f}s after you leave"
            self.lock_item.state = self.cfg.lock_method == "sleep"
            self.awake_item.state = self.cfg.stay_awake
            self.sound_item.state = self.cfg.sound
            self.notify_item.state = self.cfg.notify
            self.login_item.state = macos.agent_installed()

        def _apply(self, **changes) -> None:
            """Persist a settings change and hand the watcher the new config."""
            self.cfg = config.with_overrides(self.cfg, **changes)
            config.write(self.cfg)
            self._sync_settings()
            watcher.restart(self.cfg)

        # --- state ---------------------------------------------------------

        @rumps.timer(REFRESH_SECONDS)
        def refresh(self, _) -> None:
            if not self._named:
                # Name the slot so where you cmd-drag the eye to survives a restart; unnamed,
                # it is keyed to org.python.python and shared with any other python app.
                item = getattr(self, "nsstatusitem", None)
                if item is not None:
                    item.setAutosaveName_("facelock")
                    self._named = True
            expiry = control.pause_expiry()
            paused = expiry is not None
            if self.learning:
                want, label = LEARNING_ICON, self.learning
            elif paused:
                want, label = PAUSED_ICON, _pause_label(expiry)
            else:
                want, label = shared.icon, shared.detail
            if self.icon != want:
                self.icon = want
            if self.status_item.title != label:
                self.status_item.title = label
            if paused != self._was_paused:  # Resume is grayed while watching
                self.resume_item.set_callback(self.resume if paused else None)
                self._was_paused = paused
            requested = control.take_lesson_request()
            if requested is not None:
                self._run_requested(requested)
            current = identity.stamp()  # cheap stat; the npz is only read when it changes
            if current != self._enrollment_stamp:
                self._enrollment_stamp = current
                enrollment = identity.load()
                known = sum(enrollment.profiles.values())
                own = enrollment.leave_one_out()
                weakest = f"{own.min():.2f}" if len(own) else "-"
                self.enrollment_item.title = (
                    f"knows {known} views ({enrollment.recognizer}) - weakest scores {weakest}"
                )
                legacy = enrollment.recognizer != config.DEFAULT_RECOGNIZER
                self.upgrade_item.hidden = not legacy
            if self.threshold_item.title != (want := self._threshold_label()):
                self.threshold_item.title = want

        def _run_requested(self, name: str) -> None:
            """`facelock teach` from a terminal lands here - the app owns the camera grant."""
            if name == control.START_OVER:
                self.re_enroll(None)
                return
            for label, hint in LESSONS:
                if label.lower().endswith(name.lower()):
                    self._teach(hint, samples=LEARN_SAMPLES, poses=enroll.LEARN_POSES)
                    return
            self.learning = f"no lesson called {name!r}"
            threading.Timer(3.0, lambda: setattr(self, "learning", "")).start()

        def _threshold_label(self) -> str:
            return f"counts as you at match {self.cfg.threshold:.2f} or better"

        # --- actions -------------------------------------------------------

        def lock_now(self, _) -> None:
            macos.lock(self.cfg.lock_method)

        def pause_15(self, _) -> None:
            control.pause(15 * 60)

        def pause_hour(self, _) -> None:
            control.pause(60 * 60)

        def pause_forever(self, _) -> None:
            control.pause(control.FOREVER)

        def resume(self, _) -> None:
            control.resume()

        def toggle_lock_method(self, _) -> None:
            self._apply(lock_method="suspend" if self.cfg.lock_method == "sleep" else "sleep")

        def toggle_stay_awake(self, _) -> None:
            self._apply(stay_awake=not self.cfg.stay_awake)

        def toggle_sound(self, _) -> None:
            self._apply(sound=not self.cfg.sound)

        def toggle_notify(self, _) -> None:
            self._apply(notify=not self.cfg.notify)

        def toggle_login(self, _) -> None:
            if macos.agent_installed():
                macos.uninstall_agent()
            else:
                macos.install_agent()
            self.login_item.state = macos.agent_installed()

        def _preset_callback(self, name: str):
            def choose(_) -> None:
                self._apply(**config.PRESETS[name])
            return choose

        # --- training ------------------------------------------------------

        def _lesson_callback(self, label: str, hint: str):
            def teach(_) -> None:
                self._teach(hint, samples=LEARN_SAMPLES, poses=enroll.LEARN_POSES)
            return teach

        def re_enroll(self, _) -> None:
            self._teach("run through the poses", samples=25, poses=enroll.POSES, replace_all=True)

        def _teach(self, hint: str, samples: int, poses: tuple[str, ...],
                   replace_all: bool = False) -> None:
            if self.learning:
                return
            threading.Thread(target=self._teach_worker,
                             args=(hint, samples, poses, replace_all), daemon=True).start()

        def _teach_worker(self, hint: str, samples: int, poses: tuple[str, ...],
                          replace_all: bool) -> None:
            """Hold the camera alone: stop the watcher, capture, then start it again."""
            self.learning = "getting ready"
            try:
                watcher.stop()
                for left in range(int(LEARN_COUNTDOWN), 0, -1):
                    self.learning = f"{hint} - starting in {left}"
                    time.sleep(1.0)
                current = identity.load()
                # A lesson extends the views it already has, so it must use their recognizer;
                # Start Over is where the current model comes in.
                recognizer = (config.DEFAULT_RECOGNIZER if replace_all or not len(current)
                              else current.recognizer)
                captured = enroll.capture(
                    self.cfg, samples, lambda text: setattr(self, "learning", text),
                    timeout=LEARN_WINDOW if poses is enroll.LEARN_POSES else 90.0,
                    poses=poses, minimum=1, recognizer=recognizer,
                )
                base = current if not replace_all else identity.Enrollment({}, recognizer)
                updated = base.with_profile("me", captured, append=not replace_all)
                calibration = identity.calibrate(updated)
                updated = updated.without_outliers(calibration.threshold)
                updated.save()
                self.cfg = config.with_overrides(self.cfg, threshold=calibration.threshold)
                config.write(self.cfg)
                self.learning = (f"learned {len(captured)} views - "
                                 f"strangers top out at {calibration.stranger_max:.2f}, "
                                 f"you count from {calibration.threshold:.2f}")
            except (SystemExit, Exception) as error:  # a failed lesson must not kill the app
                self.learning = f"could not learn that: {error}"
            finally:
                time.sleep(2.0)  # leave the outcome on screen before the watcher resumes
                self.learning = ""
                watcher.start(self.cfg)

        def quit(self, _) -> None:
            watcher.stop(timeout=2.0)  # a daemon thread; do not make quitting wait on a check
            rumps.quit_application()

    # The agent runs the bare python binary, whose bundle is Python.app - a Foreground app,
    # hence a rocket in the Dock. Accessory at runtime keeps the status item (LSUIElement in a
    # bundle plist does not, on macOS 26).
    AppKit.NSApplication.sharedApplication().setActivationPolicy_(
        AppKit.NSApplicationActivationPolicyAccessory
    )

    try:
        FaceLockApp().run()
    finally:
        watcher.stop()
        control.clear_pid()
    return 0
