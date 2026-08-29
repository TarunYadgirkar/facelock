# facelock

Locks this Mac when **my** face has not been in front of the webcam for more than three seconds.

Face detection is OpenCV **YuNet**, identity is the **SFace** 128-d embedding compared by cosine
similarity against locally enrolled samples. Everything runs offline on the CPU, no frame is ever
written to disk, and the camera is released whenever the watcher is not actively looking.

## Setup

```sh
./setup.sh
```

Creates a `python3.11` venv, installs the package, downloads the two ONNX models, runs the tests.

Then grant your terminal camera access — **System Settings → Privacy & Security → Camera** — and
restart the terminal. The first capture triggers the prompt.

## Use

```sh
.venv/bin/facelock enroll          # capture 25 samples, prompted through five head poses
.venv/bin/facelock test            # live scores + a suggested threshold
.venv/bin/facelock watch -v        # arm it
```

| Command | What it does |
|---|---|
| `enroll [--profile NAME] [--add]` | capture reference samples; separate profiles for glasses, evening light, etc. |
| `forget NAME` | drop a profile |
| `test [--seconds N]` | live match scores, then percentile stats and a threshold suggestion |
| `watch [--dry-run] [-v]` | the real thing; `--dry-run` logs instead of locking |
| `menubar` | same watcher with a status glyph and a pause menu in the menu bar |
| `pause [15m\|45s\|2h\|forever]` / `resume` | suspend a running watcher from another terminal |
| `status` | watcher pid, pause state, enrollment quality, settings, recent log lines |
| `stop` | signal a running watcher to exit |
| `config [--write]` | show effective settings, or write a commented `config.toml` |
| `install-agent` / `uninstall-agent` | start at login via launchd |

## Behaviour

- **Away** — no face of mine for `timeout` (3s) → lock. A sound and a banner fire one second
  before, so you can lean back into frame.
- **Stranger** — a face is visible and it is not mine → the shorter `unknown_face_timeout` (1s)
  applies. Someone leaning into your seat locks it faster than an empty chair.
- **Locked or paused** — the camera is released and polling stops, so the green light goes off.
  Watching resumes automatically on unlock.
- **Camera trouble** — an unreadable frame counts as absence (fail secure), with exponential
  backoff on reopening rather than a lock loop.
- Locking uses `CGSession -suspend` (the fast-user-switch login window); set
  `lock_method = "sleep"` for `pmset displaysleepnow` instead.

## Cost

Measured on an M5 Pro:

| | |
|---|---|
| Resident memory | ~230 MB (37 MB SFace model + OpenCV runtime) |
| Detection | 2.3 ms/frame (runs at 320px, alignment stays full res) |
| Embedding | 5.7 ms per detected face |
| CPU while present | ~3% of one core at the default 0.25 s poll |
| CPU while away | ~2% of one core at the 0.12 s alert poll |

Battery impact is dominated by keeping the camera powered, not by inference. `pause`, the menu bar
control, and the automatic release while locked all exist to keep that off when you do not need it.

## Configuration

`facelock config --write` drops every default into `~/.config/facelock/config.toml`. Useful keys:

| Key | Default | Meaning |
|---|---|---|
| `timeout` | `3.0` | seconds away before locking |
| `unknown_face_timeout` | `1.0` | seconds before locking when someone else is in frame |
| `warn_before` | `1.0` | seconds of warning before the lock |
| `threshold` | `0.363` | cosine similarity required to count as me (SFace reference point) |
| `interval` / `alert_interval` | `0.25` / `0.12` | poll periods when present / when on the clock |
| `detect_width` | `320` | detection downscale; raise it if faces are missed at a distance |
| `lock_method` | `"suspend"` | `suspend` or `sleep` |
| `sound` / `notify` | `true` | warning cue and banner |

State lives outside the repo: enrollment in `~/.local/share/facelock/enrollment.npz` (mode 600),
log and pause file in `~/.local/state/facelock/`.

## Limits

- A photo or video of you on a phone screen will pass. There is no liveness check — this is a
  convenience lock, not authentication.
- The login agent inherits camera permission from the python binary it runs; if it never sees your
  face, run `facelock watch` once in a terminal and approve the prompt.
- Poor or backlit lighting drops match scores. Enroll a second profile with `--add` under the
  conditions that fail rather than lowering the threshold globally.

## Tests

```sh
.venv/bin/python -m pytest
```

The decision logic (`facelock/watcher.py`) is a pure state machine driven by an injected clock, so
timeout, warning, stranger and post-lock behaviour are all covered without a camera.
