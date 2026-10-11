"""The menu bar app: the watcher, plus training and settings, all without a terminal."""

from __future__ import annotations

import threading
import time
import logging
import subprocess
from dataclasses import replace
from pathlib import Path

from . import config, control, diagnostics, enroll, identity, macos, vision
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
RETRY_SECONDS = 5.0
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
    ("Teach: evening light", "look at your screen in your usual evening light"),
    ("Teach: daylight", "look at your screen in daylight"),
    ("Teach: whatever I am doing now", "hold still"),
)


def _pause_label(expiry: float) -> str:
    if expiry == control.FOREVER:
        return "paused until you resume"
    left = max(0.0, expiry - time.time())
    return f"paused · {left / 60:.0f} min left" if left >= 60 else f"paused · {left:.0f} s left"


def _lock_countdown(left: int) -> str:
    return "locks if the next check misses" if left == 1 else f"locks if the next {left} checks miss"


class _Shared:
    """Watcher thread writes, menu bar thread reads. One assignment, no locking needed."""

    def __init__(self, preview: bool = False) -> None:
        self.preview = preview
        self.icon = ICON[State.STRANGER]
        self.detail = "starting up"

    def update(self, decision: Decision, reading: Reading) -> None:
        self.icon = ICON[decision.state]
        score = f"match {reading.match.score:.2f}"
        if decision.event is Event.LOCK:
            action = "would lock now" if self.preview else "lock requested"
            self.detail = f"{action} · {score}"
        elif decision.state is State.PRESENT:
            self.detail = f"you're here · {score}"
        else:
            who = "someone else in frame" if decision.state is State.STRANGER else "you're away"
            countdown = _lock_countdown(decision.needed - decision.misses)
            self.detail = f"{who} · {countdown} · {score}"

    def status(self, detail: str) -> None:
        self.icon = ICON[State.STRANGER]
        self.detail = detail


class _Watcher:
    """Owns the watcher thread so a settings change can restart it with the new config."""

    def __init__(self, shared: _Shared, dry_run: bool) -> None:
        self._shared = shared
        self._dry_run = dry_run
        self._shared.preview = dry_run
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._mutex = threading.RLock()
        self._revision = 0
        self._cfg = config.Config()

    @property
    def preview(self) -> bool:
        return self._shared.preview

    @property
    def requested_preview(self) -> bool:
        return self._dry_run

    def set_preview(self, enabled: bool) -> None:
        with self._mutex:
            self._dry_run = enabled
            self._shared.status("switching to preview after this check" if enabled
                                else "turning locking back on")
            self.restart(self._cfg)

    def start(self, cfg: config.Config) -> None:
        with self._mutex:
            if not self.stop():
                raise RuntimeError("camera is still closing; retry shortly")
            self._cfg = cfg
            self._stop = threading.Event()
            self._thread = threading.Thread(target=self._supervise, daemon=True)
            self._thread.start()

    def _supervise(self) -> None:
        while not self._stop.is_set():
            revision = self._revision
            cfg = self._cfg
            dry_run = self._dry_run
            self._shared.preview = dry_run
            try:
                run(cfg, identity.Live(), self._shared.update, dry_run=dry_run,
                    paused=control.is_paused,
                    should_stop=lambda: self._stop.is_set() or revision != self._revision,
                    on_status=self._shared.status)
            except (Exception, SystemExit) as error:
                logging.getLogger(config.APP).exception("watcher failed; retrying")
                self._shared.status(f"not protecting · {error} · retrying in {RETRY_SECONDS:.0f} s")
                self._stop.wait(RETRY_SECONDS)

    def stop(self, timeout: float = 10.0) -> bool:
        """Returns once the watcher has let go of the camera."""
        with self._mutex:
            self._revision += 1
            self._stop.set()
            if self._thread is not None:
                self._thread.join(timeout=timeout)
                if self._thread.is_alive():
                    self._shared.status("camera is still closing")
                    return False
                self._thread = None
            return True

    def restart(self, cfg: config.Config) -> None:
        """Off the main thread: stopping waits for a check to finish, which would freeze the menu."""
        with self._mutex:
            self._cfg = cfg
            self._revision += 1
            if self._thread is None or not self._thread.is_alive():
                self.start(cfg)
            elif self._stop.is_set():
                threading.Thread(target=self._restart_after_stop,
                                 args=(self._thread, self._revision), daemon=True).start()

    def _restart_after_stop(self, previous: threading.Thread, revision: int) -> None:
        previous.join()
        with self._mutex:
            if self._thread is previous and self._revision == revision:
                self.start(self._cfg)


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
        macos.banner("facelock", "already running. Look for the eye in the menu bar.")
        print(f"facelock is already running (pid {running})")
        return 0

    config.ensure_dirs()
    vision.silence_opencv_logs()
    control.setup_logging()
    control.write_pid()
    shared = _Shared(preview=dry_run)
    watcher = _Watcher(shared, dry_run)

    class FaceLockApp(rumps.App):
        def __init__(self) -> None:
            super().__init__("FaceLock", icon=shared.icon, template=True, quit_button=None)
            self.cfg = cfg
            self.learning = ""  # non-empty while a lesson is capturing
            self._quitting = threading.Event()
            self._named = False  # rumps builds the status item in run(), not here
            self.status_item = rumps.MenuItem("starting")
            self.resume_item = rumps.MenuItem("Resume")
            self.preview_item = rumps.MenuItem("Preview mode (never locks)",
                                               callback=self.toggle_preview)
            self.preview_item.state = dry_run
            self._was_paused = False
            self.menu = [
                self.status_item,
                None,
                rumps.MenuItem("Lock Now", callback=self.lock_now),
                rumps.MenuItem("Check Now", callback=self.check_now),
                self.preview_item,
                rumps.MenuItem("Pause 15 minutes", callback=self.pause_15),
                rumps.MenuItem("Pause 1 hour", callback=self.pause_hour),
                rumps.MenuItem("Pause until resumed", callback=self.pause_forever),
                self.resume_item,
                None,
                self._training_menu(),
                self._settings_menu(),
                self._help_menu(),
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
                "Old model lets some strangers through. Start Over to upgrade.")
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
                item.title = f"{name} · locks ~{grace / 60:.0f} min after you leave" if grace >= 90 \
                    else f"{name} · locks ~{grace:.0f} s after you leave"
            self.lock_item.state = self.cfg.lock_method == "sleep"
            self.awake_item.state = self.cfg.stay_awake
            self.sound_item.state = self.cfg.sound
            self.notify_item.state = self.cfg.notify
            self.login_item.state = macos.agent_installed()

        def _help_menu(self) -> rumps.MenuItem:
            menu = rumps.MenuItem("Help & Diagnostics")
            menu.add(rumps.MenuItem("Health Check", callback=self.health_check))
            menu.add(rumps.MenuItem("Camera Privacy Settings", callback=self.open_camera_settings))
            menu.add(rumps.MenuItem("Open Log", callback=self.open_log))
            return menu

        def health_check(self, _) -> None:
            rumps.alert(title="FaceLock Health Check",
                        message=diagnostics.format_report(diagnostics.run_checks()))

        def _open(self, *arguments: str) -> None:
            try:
                subprocess.run(["open", *arguments], check=True, capture_output=True, timeout=5)
            except (OSError, subprocess.SubprocessError) as error:
                shared.status(f"could not open: {error}")

        def open_camera_settings(self, _) -> None:
            self._open("x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")

        def open_log(self, _) -> None:
            self._open("-a", "Console", str(config.LOG_FILE))

        def _apply(self, **changes) -> None:
            """Persist a settings change and hand the watcher the new config."""
            if self.learning:
                return
            updated = config.with_overrides(self.cfg, **changes)
            try:
                config.write(updated)
            except OSError as error:
                shared.status(f"could not save settings: {error}")
                return
            self.cfg = updated
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
            if watcher.preview:
                label = f"preview, never locks · {label}"
            self.preview_item.state = watcher.preview
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
                try:
                    enrollment = identity.load()
                except (OSError, ValueError) as error:
                    self.enrollment_item.title = "Enrollment unreadable. Start Over to redo it."
                    shared.status(f"enrollment error: {error}")
                    return
                known = sum(enrollment.profiles.values())
                own = enrollment.leave_one_out()
                weakest = f"{own.min():.2f}" if len(own) else "-"
                self.enrollment_item.title = (
                    f"knows {known} views ({enrollment.recognizer}) · weakest view scores {weakest}"
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
            try:
                enrollment = identity.load()
                threshold = max(self.cfg.threshold, enrollment.threshold or
                                config.default_threshold(enrollment.recognizer))
            except (OSError, ValueError):
                return "Enrollment unavailable. Start Over to redo it."
            return f"counts as you at match {threshold:.2f} or better"

        # --- actions -------------------------------------------------------

        def lock_now(self, _) -> None:
            if watcher.preview or watcher.requested_preview:
                shared.status("would lock now · preview is on")
                return
            try:
                macos.lock(self.cfg.lock_method)
            except (OSError, RuntimeError) as error:
                shared.status(f"could not lock: {error}")

        def toggle_preview(self, _) -> None:
            if self.learning:
                return
            watcher.set_preview(not watcher.requested_preview)
            self.preview_item.state = watcher.preview

        def check_now(self, _) -> None:
            if self.learning or control.is_paused():
                return
            shared.status("checking now")
            watcher.restart(self.cfg)

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
            self.learning = "getting ready"
            threading.Thread(target=self._teach_worker,
                             args=(hint, samples, poses, replace_all), daemon=True).start()

        def _teach_worker(self, hint: str, samples: int, poses: tuple[str, ...],
                          replace_all: bool) -> None:
            """Hold the camera alone: stop the watcher, capture, then start it again."""
            try:
                if not watcher.stop():
                    raise RuntimeError("camera is still closing; retry the lesson")
                for left in range(int(LEARN_COUNTDOWN), 0, -1):
                    self.learning = f"{hint} · starting in {left}"
                    if self._quitting.wait(1.0):
                        return
                current = identity.Enrollment({}) if replace_all else identity.load()
                # A lesson extends the views it already has, so it must use their recognizer;
                # Start Over is where the current model comes in.
                recognizer = (config.DEFAULT_RECOGNIZER if replace_all or not len(current)
                              else current.recognizer)
                captured = enroll.capture(
                    self.cfg, samples, lambda text: setattr(self, "learning", text),
                    timeout=LEARN_WINDOW if poses is enroll.LEARN_POSES else 90.0,
                    poses=poses, minimum=3 if not replace_all else enroll.MIN_USEFUL_SAMPLES,
                    recognizer=recognizer, should_stop=self._quitting.is_set,
                    reference=current if len(current) and not replace_all else None,
                )
                if self._quitting.is_set():
                    return
                updated, calibration = enroll.prepare(current, captured, replace_all=replace_all,
                                                       threshold=self.cfg.threshold)
                updated.save()
                self.cfg = config.with_overrides(self.cfg, threshold=calibration.threshold)
                config.write(self.cfg)
                self.learning = (f"learned {len(captured)} views · "
                                 f"strangers top out at {calibration.stranger_max:.2f}, "
                                 f"you count from {calibration.threshold:.2f}")
            except (SystemExit, Exception) as error:  # a failed lesson must not kill the app
                self.learning = f"could not learn that: {error}"
            finally:
                self._quitting.wait(2.0)
                self.learning = ""
                if not self._quitting.is_set():
                    try:
                        watcher.restart(self.cfg)
                    except RuntimeError as error:
                        shared.status(str(error))

        def quit(self, _) -> None:
            self._quitting.set()
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
