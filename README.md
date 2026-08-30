# FaceLock

Locks this Mac when **my** face stops showing up in front of the webcam.

It does not stare at you. Every **30 seconds** it wakes the camera for a fraction of a second and
takes one look. If you are there, it goes back to sleep. If you are not, the rechecks close in —
**10s**, then **5s** — and the third miss locks the screen, about **45 seconds** after you left at
worst. Missing once is cheap; missing twice means you are gone, so it stops waiting around.
A face that is in frame but *isn't yours* gets its own fast cadence.
Locking shows the lock screen only — everything keeps running behind it.

Face detection is OpenCV **YuNet**, identity is the **SFace** embedding compared by cosine
similarity against locally enrolled samples. Everything runs offline on the CPU, no frame is ever
written to disk, and between checks the camera is fully released — green light off.

## Setup

```sh
./setup.sh                         # venv + install + tests
.venv/bin/facelock enroll          # capture 25 samples (models auto-download on first use)
.venv/bin/facelock test            # live scores + a suggested threshold
.venv/bin/facelock install-app     # FaceLock.app in ~/Applications
```

Grant camera access when macOS asks — **System Settings → Privacy & Security → Camera** — and
restart the terminal if the first capture fails.

## The app

`FaceLock.app` lives in the menu bar (no Dock icon) and everything is done from there —
the terminal commands below are the same features for anyone who prefers them.

- the bar icon tells the state: eye = you're here, crossed eye = missing and on the
  clock, warning = someone else in frame, pause = paused, student = learning your face
  ([Phosphor](https://phosphoricons.com) icons, MIT)
- **Lock Now**, **Pause** (15 min / 1 hour / until resumed), **Resume** (grayed unless paused);
  while paused the first menu line counts down: `paused - 12m left`
- **Training ▸** teaches it a pose without re-enrolling: pick the lesson, get into the pose
  during the countdown, and it captures ~15 more views and appends them. The running watcher
  picks up the new samples immediately — no restart. **Start Over** redoes the full enrollment.
- **Settings ▸** cadence preset (each line states how long you can be gone before it locks),
  whether locking also turns the display off, the warning sound and banner, and **Start at Login**.
  Changes are written to `config.toml` and restart the watcher in place.

**Relaunching after Quit**: Spotlight (⌘-space) → *FaceLock*, or open `~/Applications/FaceLock.app`.
Tick **Start at Login** and it comes back by itself after a reboot.

## Commands

| Command | What it does |
|---|---|
| `enroll [--profile NAME] [--add]` | capture reference samples; separate profiles for glasses, evening light, etc. |
| `forget NAME` | drop a profile |
| `test [--seconds N]` | live match scores, then percentile stats and a threshold suggestion |
| `watch [--dry-run] [-v]` | the watcher, in a terminal |
| `menubar` | the watcher with the menu bar UI (what the app runs) |
| `install-app` / `uninstall-app` | put FaceLock.app in `~/Applications` / remove it and the login agent |
| `pause [15m\|45s\|2h\|forever]` / `resume` | suspend any running watcher from another terminal |
| `status` | watcher pid, pause state, enrollment quality, settings, recent log lines |
| `stop` | signal a running watcher to exit |
| `config [--write]` | show effective settings, or write a commented `config.toml` |
| `install-agent [--headless]` / `uninstall-agent` | login autostart by hand (the app's checkbox does this for you) |

## Behaviour

- **Present** — one check every `interval` (30 s). Each check is a 3-frame burst; the best frame
  wins, so one blurry frame never counts against you.
- **Missing** — the first recheck waits `recheck_interval` (10 s) and each one after it waits
  `recheck_decay` (0.5) of the last, down to a 2 s floor. `confirm_checks` (3) consecutive
  checks without you lock the screen, warning before the final one.
- **Stranger** — a face that isn't yours is rechecked after `stranger_interval` (5 s), so someone
  sitting down at your machine locks it in seconds.
- **Locked or paused** — the camera stays released and nothing polls. Watching resumes on unlock.
- **Camera trouble** — an unreadable frame counts as a miss (fail secure), with exponential
  backoff on reopening rather than a lock loop.
- Locking calls `SACLockScreenImmediate` (the real lock screen); set
  `lock_method = "sleep"` for `pmset displaysleepnow` instead.

## Cost

Inference is ~8 ms per check on an M5 Pro. At one check per 30 s the average CPU cost is
effectively zero, and the camera is powered for well under 1% of the time. Memory is ~230 MB
resident (OpenCV + the two models).

## Configuration

`facelock config --write` drops every default into `~/.config/facelock/config.toml`:

| Key | Default | Meaning |
|---|---|---|
| `interval` | `30.0` | seconds between checks while you are present |
| `recheck_interval` | `10.0` | wait before the first recheck once you are missing |
| `recheck_decay` | `0.5` | each further recheck waits this much of the last (2 s floor) |
| `stranger_interval` | `5.0` | recheck spacing when an unknown face is in frame |
| `confirm_checks` | `3` | consecutive missed checks before locking |
| `frames_per_check` | `3` | frames per burst; the best match wins |
| `threshold` | `0.363` | cosine similarity required to count as you |
| `detect_width` | `320` | detection downscale; raise it if faces are missed at a distance |
| `lock_method` | `"suspend"` | `suspend` or `sleep` |
| `sound` / `notify` | `true` | warning cue and banner |

State lives outside the repo: enrollment in `~/.local/share/facelock/enrollment.npz` (mode 600),
log and pause file in `~/.local/state/facelock/`, models in `models/` (auto-downloaded).

## Limits

- A photo of you on a phone screen will pass. No liveness check — this is a convenience lock,
  not authentication.
- Worst-case walk-away exposure is `interval` plus the shrinking rechecks — ~45 s on the Balanced
  preset, ~21 s on Strict. Settings ▸ states the number for each preset; the old always-on
  behaviour is roughly `interval = 1, recheck_interval = 1, confirm_checks = 3`.
- Poor or backlit lighting drops match scores. Enroll a second profile with `--add` under the
  conditions that fail rather than lowering the threshold globally.

## Tests

```sh
.venv/bin/python -m pytest
```

The decision logic (`facelock/watcher.py`) is a pure state machine over check counts, so warning,
locking, stranger handling and camera-failure behaviour are all covered without a camera.
