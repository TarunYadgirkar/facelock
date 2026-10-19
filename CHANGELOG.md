# Changelog

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
