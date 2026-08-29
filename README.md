# FaceLock

Locks this Mac when **my** face stops showing up in front of the webcam.

It does not stare at you. Every **30 seconds** it wakes the camera for a fraction of a second and
takes one look. If you are there, it goes back to sleep. If you are not, it warns you (sound +
banner) and looks again **10 seconds** later — still missing, the screen locks. A face that is
in frame but *isn't yours* gets the fast track: rechecked after 2 seconds instead of 10.

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

`FaceLock.app` lives in the menu bar (no Dock icon):

- 👁 you're here 💤 missing, on the clock ⚠️ someone else in frame ⏸ paused
- **Lock Now**, **Pause** (15 min / 1 hour / until resumed), **Resume**
- **Start at Login** — one click, no launchctl

Prefer a terminal? `facelock watch -v` is the same watcher with a live status line, and
`--dry-run` logs instead of locking while you build trust in it.

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
- **Missing** — warn, then recheck every `recheck_interval` (10 s). `confirm_checks` (2)
  consecutive checks without you lock the screen.
- **Stranger** — a face that isn't yours is rechecked after `stranger_interval` (2 s), so someone
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
| `recheck_interval` | `10.0` | seconds between checks once you are missing |
| `stranger_interval` | `2.0` | recheck spacing when an unknown face is in frame |
| `confirm_checks` | `2` | consecutive missed checks before locking |
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
- Worst-case walk-away exposure is `interval + confirm_checks × recheck_interval` (~50 s with
  defaults). Tighten `interval` if that is too long for your threat model; the old always-on
  behaviour is roughly `interval = 1, recheck_interval = 1, confirm_checks = 3`.
- Poor or backlit lighting drops match scores. Enroll a second profile with `--add` under the
  conditions that fail rather than lowering the threshold globally.

## Tests

```sh
.venv/bin/python -m pytest
```

The decision logic (`facelock/watcher.py`) is a pure state machine over check counts, so warning,
locking, stranger handling and camera-failure behaviour are all covered without a camera.
