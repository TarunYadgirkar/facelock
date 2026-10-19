# Changelog

## 0.5.1, 2026-10-18: audit fixes

### Fixed

- A camera that sends no frame (suspended, dead, slow to open or failing at runtime) no longer counts as you being away. Such a check is logged as `camera_failed`, retried with backoff, never leads to a countdown or a lock, and after two in a row the menu says the camera isn't responding while FaceLock rebuilds its camera session.
- The settle cap and the window length count from the camera's first frame, so a slow camera open no longer shortens the look. Frame analysis errors are logged instead of dropped.
- Camera availability comes from the watcher's own camera only. Launching with the lid closed is now seen at once, AirPods and other audio devices no longer override a suspended camera, and an unplugged camera gets a new session when it comes back.
- Frames that aren't 640x480 are asked for at 640x480 and centre-cropped to 4:3 instead of stretched. The frame size is in the log.
- A timed pause ends on time even when the Mac sleeps through its end. "Until I unlock" no longer survives a restart or logout. "Until tomorrow" now means the next 6:00 AM and the menu shows the date.
- Waking the display or the Mac starts a check at once instead of after a full interval.
- After a lock that failed (or a dry run's pretend lock) the menu says "Looking for you", not "Watching".
- A keychain that refuses the key for a moment no longer asks you to set up again, and FaceLock never replaces an existing key. Development builds and `--data-dir` runs keep their own key, so they can never overwrite or delete the real one.
- The check log keeps no record longer than 30 days.
- Two setup screens open at once keep the watcher paused until both close.
- Stay-awake after a lock drops as soon as the Mac switches to battery.
- No crash when no screen is attached.

### Changed

- The countdown says "Look at the camera to stay unlocked. Moving the mouse gives FaceLock one more look.", and shows "Checking for you…" during that look.
- The menu pill says "Watching", not "Protected". The "not protecting" icon's slash no longer looks like the full-screen arrows.
- Setup asks for notifications with the reason, and Settings shows when they are off. Start at login says what to do when macOS refuses (move FaceLock to Applications).
- Clearer words in setup and Settings: the camera lead no longer quotes an unmeasured time, pose names match everywhere, the glasses look says what to do, threshold names are spelled out, the weekly summary lists failed locks, and the old face data is called what it is: unencrypted, and readable in the Trash until you empty it.
- Stop buttons during the timed captures, Escape for Back, Skip and Cancel, VoiceOver announcements during enrollment.
- `scripts/check-no-biometrics.sh` also refuses `.f16`, `.bin`, `.pt`, `.safetensors`, enrollment files, keys and check logs.
- `facelock-bench app` measures the shipping app; `scripts/bench.sh` records the load average with every result and gates the app too.

## 0.5.0, 2026-10-18: the native rebuild

FaceLock is now a Swift menu bar app. Core ML runs both models on the Neural Engine, and nothing needs a terminal.

### New

- Setup in a window: what FaceLock does and does not do, camera access with a link to the right System Settings pane when it is off, nine guided looks with live Distance, Light, Sharp and Facing camera checks, a calibration result drawn against the benchmark strangers, an optional check with a second person, and Start at login.
- A menu bar icon whose shape shows the state: watching, checking, looking for you (with the checks left), counting down, someone else in view, paused, not protecting.
- A countdown before every lock, over full-screen apps and every Space. Your face, a key press, a mouse move or "I'm here" stops it; anything but your face runs one more check, which locks without a second countdown if it doesn't see you.
- Pause for 15 minutes, 1 hour, until you unlock, or until tomorrow. A pause survives a relaunch.
- Teach a new look, behind Touch ID or your password. Add today's light, a second sitting the day after setup.
- Settings: cadence with the real time to lock for each preset, countdown length, slower checks on battery, notifications, sound, the threshold report, recalibration, learned looks, lock when someone else is looking, the still-face check, what is stored, a weekly summary, delete everything, where the models run, and a camera timing measurement.
- First launch finds the Python version and offers to quit it, remove its login item and launcher, import its settings and, after setup, move its face data to the Trash.
- `--demo-camera <photo>` runs the whole app on a stored photo without locking, and `--snapshot <dir>` renders every screen from it. `--dry-run` watches with your camera and logs instead of locking.
- `scripts/build-app.sh` and `scripts/notarize.sh` build a signed app and a notarized DMG.

### Changed

- ArcFace r50 and YuNet on the Neural Engine: 1.6 ms per frame against 8.5 ms, and the whole app watches in about 30 MB instead of about 250 MB.
- The camera turns off as soon as it sees you, instead of after a fixed 3 frames and 0.6 s warmup.
- A face that fails the quality gate is "unclear", never "stranger", and is never locked faster than an empty room.
- Your threshold comes from looks taken in different poses, so near-duplicate frames no longer inflate it. T, F and S live only in the encrypted enrollment, with a history of every change.
- Start at login uses the system login item and shows what macOS reports, including when it needs your approval.
- Notifications come from FaceLock itself.
- Nothing runs while the screen is locked or the Mac sleeps: no timer, no polling.

### Removed

- The Python implementation, kept at the tag `python-0.4.0`. Its enrollment can't serve the new recognizer, so setup runs again.

## 0.4.0

The Python version. See the tag `python-0.4.0`.
