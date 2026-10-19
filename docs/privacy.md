# Privacy

Nothing leaves your Mac, and no camera frame is ever saved. Frames live in memory for the few milliseconds a check takes.

FaceLock uses the network once: during setup, after you accept InsightFace's licence, it downloads `buffalo_l.zip` from InsightFace's GitHub release to get the face model. That request carries nothing about you, and FaceLock makes no other network request.

## What is stored

| File | Contents | Protection |
|---|---|---|
| `~/Library/Application Support/FaceLock/enrollment.v2` | Your face templates (512 numbers each, float16), which pose and session each came from, its capture time and sharpness, and the thresholds T, F and S with their history | AES-GCM with a 256-bit key in your login keychain, which FaceLock reads without a prompt while you are logged in; file mode 0600; excluded from Time Machine |
| `~/Library/Logs/FaceLock/checks.jsonl` | One line per check: camera on-time, frame count and size, face count, best score, quality flags, verdict, and what cancelled a countdown | File mode 0600; rotated at 5 MB; no record kept longer than 30 days (pruned at launch and daily) |

The login keychain is the file-based keychain macOS keeps for each user. macOS does not honour "this device only" for items in it, so the key can travel with your keychain, for example through Migration Assistant to a new Mac. The enrollment file itself is excluded from Time Machine, but Migration Assistant may still copy it. Delete All FaceLock Data before you hand the Mac on.

FaceLock never replaces an existing key. If the keychain refuses the key for a moment (a locked keychain, a dismissed prompt), the menu says FaceLock can't read its key yet and it tries again at your next unlock, instead of asking you to set up again.

Templates are numbers, not pictures, but they still identify you, which is why they are encrypted. The log holds no images and no templates. Settings > Privacy shows a weekly summary of it, can show it in Finder, and can move it to the Trash. "Delete All FaceLock Data" moves both files to the Trash and removes the keychain key.

A run with `--demo-camera` keeps its enrollment and log in a temporary folder with the key in memory, and never touches these files, the keychain, your settings or the login item. A run with `--dry-run` writes its log to a temporary folder too, so its pretend locks never count. A run with `--data-dir <folder>` keeps its files in that folder with a keychain key of its own, so Delete All FaceLock Data there never touches the real key. A development (DEBUG) build keeps everything in `~/Library/Application Support/FaceLock-Debug/` and `~/Library/Logs/FaceLock-Debug/`, with its key in a file there, and never reads or rewrites the real enrollment.

## What the repository never holds

`scripts/check-no-biometrics.sh` runs in the tests, and as a pre-commit hook in any clone where `scripts/install-hooks.sh` has been run once (the hook is opt-in per clone). It fails on any tracked embedding, model, enrollment, key or check log (`.npz`, `.npy`, `.f16`, `.f32`, `.bin`, `.pt`, `.pth`, `.safetensors`, `.onnx`, `.mlmodel`, `.mlpackage`, `.mlmodelc`, `enrollment.v2`, `dev.key`, `checks*.jsonl`), with one exception, `Tests/Fixtures/grace_hopper_r50.f16` (ONNX Runtime's embedding of the public-domain fixture photo), and on any image outside `Resources/Assets.xcassets`, `Resources/AppIcon.icns`, `Tests/Fixtures/grace_hopper.jpg` and `assets/generated/ui-*.png`. Screenshots come only from `scripts/screenshots.sh`, which runs the app on the stored-image camera with that public-domain photo and renders each screen from its own views. It uses no screen capture and no real camera, so your camera can never appear in one.

`facelock-bench owner-report` reads your enrollment in memory and prints counts, thresholds and score percentiles only. It never shows a keychain prompt (it fails instead), refuses to write inside the repository, and its output is never committed.

The Python version's files (`~/.local/share/facelock/enrollment.npz`, `~/.config/facelock/config.toml`, the old login item and launcher) are detected on first launch. Setup lists them, each has its own button, and every removal goes to the Trash. The old face data is offered only after the new setup has saved yours. It is unencrypted, and it stays readable in the Trash until you empty it; setup says so and also offers to delete it permanently after you confirm. The same goes for Delete Log and Delete All FaceLock Data: the files sit in the Trash until you empty it.
