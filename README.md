# FaceLock

Locks your Mac when you walk away. It checks for your face with the webcam every 30 seconds, entirely on this Mac.

FaceLock is not a login and cannot tell a video of you from you. It notices a face that stays perfectly still for minutes, such as a propped-up photo, and asks you to turn your head before staying unlocked.

## Status

This branch is the native rebuild: Swift 6, Core ML on the Neural Engine, AVFoundation and Accelerate. The engine, the capture and system layers, the benchmark harness and the tests are in place. The menu bar app, onboarding and the signed DMG come next. The Python version (0.4) is kept at the tag `python-0.4.0`.

| Module | What it does |
|---|---|
| `FaceLockCore` | The watcher state machine, cadence presets, verdict rules, top-3 scoring, calibration, adaptation safeguards, still-face check, the encrypted enrollment store, telemetry. Pure logic, no AppKit or AVFoundation |
| `FaceLockVision` | YuNet and ArcFace r50 on Core ML, vImage scale and similarity warp, crop luma and sharpness |
| `FaceLockCapture` | The AVCaptureSession wrapper, the exposure-settle gate and frame pacing, and a stored-image camera for dry runs and screenshots |
| `FaceLockSystem` | Screen lock with confirmation, session state, idle time, sleep and wake, login item, notifications, Touch ID, keychain |
| `facelock-bench` | The benchmark harness and a dry-run watcher |

How it decides, step by step: [docs/how-it-decides.md](docs/how-it-decides.md). What it stores: [docs/privacy.md](docs/privacy.md).

## Numbers

From `scripts/bench.sh` on an M5 Pro ([docs/benchmarks.md](docs/benchmarks.md), `bench/results/2026-10-18-apple-m5-pro.json`):

- 1.6 ms per frame on the Neural Engine (1.75 ms p95), with 0.75 ms and 1.8 mJ of CPU per frame. The Python version took 8.5 ms and about 107 mJ.
- Idle while you are there: 0.034% of a core and about 2.5 J of CPU energy an hour, in 12 MB. With the screen locked no timer runs (0.0007% of a core). The Python version used 0.98%, 40.8 J an hour and about 250 MB.
- On LFW stand-ins: strangers score at most 0.333 (p99 0.223); owner-like probes reach 0.723 or more 95% of the time; the threshold floor is 0.44, where 0.18% of owner probes fail, which is 2 mislabelled images.

Webcam strangers and owner scores across sessions are not measured at scale, and camera on-time per check is not measured on hardware yet.

## Build and test

```sh
python -I tools/convert_models.py     # models/YuNet320x240 and models/ArcFaceR50 (needs tools/requirements.lock.txt)
swift test                            # Vision tests skip with a message when models/ is absent
swift run -c release facelock-bench dry-run --leave-after 5 --seconds 80
```

`facelock-bench dry-run` watches a public-domain photo through the real watcher and prints every check; with `--leave-after` the scene empties and the run walks through the rechecks, the countdown and a lock that is only logged.

`scripts/install-hooks.sh` adds a pre-commit hook that refuses embeddings, model files and images outside the allowlist.

## Licences

The code licence is not chosen yet. YuNet is MIT (opencv_zoo). The InsightFace r50 weights are for non-commercial research only; the repository holds no weights, and a public build that bundles them redistributes them.
