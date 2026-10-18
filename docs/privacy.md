# Privacy

Nothing leaves your Mac, and no camera frame is ever saved. Frames live in memory for the few milliseconds a check takes.

## What is stored

| File | Contents | Protection |
|---|---|---|
| `~/Library/Application Support/FaceLock/enrollment.v2` | Your face templates (512 numbers each, float16), which pose and session each came from, its capture time and sharpness, and the thresholds T, F and S with their history | AES-GCM; the key is in your login keychain, this Mac only, readable while you are logged in; file mode 0600 |
| `~/Library/Logs/FaceLock/checks.jsonl` | One line per check: camera on-time, frame count, face count, best score, quality flags, verdict, and what cancelled a countdown | File mode 0600; rotated at 5 MB, rotated files kept 30 days |

Templates are numbers, not pictures, but they still identify you, which is why they are encrypted. The log holds no images and no templates. Settings shows a weekly summary of it, can open it, and can delete it. "Delete all FaceLock data" moves both files to the Trash and removes the keychain key.

## What the repository never holds

`scripts/check-no-biometrics.sh` runs in the tests and as a pre-commit hook (`scripts/install-hooks.sh`). It fails on any tracked embedding or model file (`.npz`, `.npy`, `.f32`, `.onnx`, `.mlmodel`, `.mlpackage`, `.mlmodelc`) and on any image outside `Resources/Assets.xcassets`, `Resources/AppIcon.icns`, `Tests/Fixtures/grace_hopper.jpg` and `docs/img/`. Screenshots are made only with the stored-image camera and a public-domain photo, never with your camera.

`facelock-bench owner-report` reads your enrollment in memory and prints counts, thresholds and score percentiles only. It refuses to write inside the repository, and its output is never committed.

The Python version's files (`~/.local/share/facelock/enrollment.npz`, `~/.config/facelock/config.toml`, the old login item and launcher) are detected on first launch; each removal asks first and goes to the Trash.
