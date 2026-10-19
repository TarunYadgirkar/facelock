# FaceLock

Locks your Mac when you walk away. It checks for your face with the webcam every 30 seconds, entirely on this Mac.

FaceLock is not a login and cannot tell a video of you from you. It notices a face that stays perfectly still for minutes, such as a propped-up photo, and asks you to turn your head before staying unlocked.

<p>
<img src="assets/generated/ui-menu-watching.png" width="304" alt="The FaceLock menu: a green Protected pill, Watching, You were here 4 s ago, Next check in 26 s, then Check Now, Pause, Teach a New Look, Settings and Quit">
<img src="assets/generated/ui-countdown.png" width="460" alt="The countdown card: a red ring around the number 8, Locking in 8 s, Look at the camera or move the mouse to stay unlocked, and an I'm here button">
</p>

## How it decides

FaceLock lives in the menu bar. At each check it turns the camera on, looks for your face, and turns the camera off at the first frame that shows you. When it can't find you, it looks again twice with the camera off in between, then puts up a countdown with the camera on. Your face stops the countdown. So does a key press, a mouse move or "I'm here", but then FaceLock runs one more full check, and if that check doesn't see you the Mac locks with no second countdown. Someone at your keyboard can delay a lock once and can't cancel it indefinitely.

| Preset | Checks every | Rechecks after a miss | Locks after you leave, at most |
|---|---|---|---|
| Relaxed | 45 s | 15 s, then 7.5 s | 85 s |
| Balanced (default) | 30 s | 10 s, then 5 s | 62 s |
| Strict | 15 s | 6 s | 36 s |

The worst case counts a full interval, every recheck at its longest and a 10 s countdown. On the demo camera, a Balanced run locked about 53 s after the photo left.

A face that is too small, tilted, turned away, cut off, dark or blurry is "unclear", never "stranger", and follows the same cadence as an empty room, so a badly posed owner is never locked faster than an absent one. Only a clear face that scores like nobody you know, in 2 frames of one check, gets the faster recheck. Nothing runs while the screen is locked, the display or the Mac is asleep, the camera is unavailable or FaceLock is paused, and nothing polls.

The menu bar icon carries the state in its shape:

<img src="assets/generated/ui-menu-glyphs.png" width="780" alt="Seven menu bar icons: watching, checking, looking for you with 2 checks left, countdown, someone else, paused, not protecting">

Every rule, with the numbers behind it: [docs/how-it-decides.md](docs/how-it-decides.md).

## Setup

The first launch opens a setup window, and nothing needs a terminal.

1. **Welcome.** What FaceLock does and doesn't do, and what stays on the Mac.
2. **Old version.** Only if the Python FaceLock is installed: quit it, remove its login item and launcher, import its settings. Everything removed goes to the Trash.
3. **Camera.** One permission prompt. If access is off, a button opens the right pane of System Settings.
4. **Your face.** Nine looks, each placed where your head goes, with live checks for distance, light, sharpness and facing the camera. A look fills after six clear views at least 250 ms apart, at your pace.
5. **Result.** Your scores drawn against the strangers in the benchmark, the threshold FaceLock chose, and which looks, if any, come close to strangers.
6. **Someone else**, optional. A second person looks at the camera for 10 s, and if they score close to you, your threshold rises. Only their best score is kept.
7. **Finish.** Start at login, with what macOS actually reports, including when it needs approval in System Settings > General > Login Items.

<img src="assets/generated/ui-setup-face.png" width="880" alt="The Your face step: a mirrored camera preview with viewfinder corners and the hint Turn a little to your left, four green checks for Distance, Light, Sharp and Facing camera, and a 3 by 3 map of rings with Centre done and Left in progress">

<img src="assets/generated/ui-setup-result.png" width="880" alt="The Result step: Your looks pass with room to spare, a histogram of look scores near 0.95 to the right of the threshold line at 0.60, the grey benchmark stranger band up to 0.33, and the floor at 0.44">

The day after setup, the menu offers **Add today's light**: 20 seconds in different light, so your threshold isn't tuned to one afternoon. **Teach a new look** (after a haircut or new glasses) asks for Touch ID or your password first.

## Numbers

From `scripts/bench.sh` on an Apple M5 Pro, with other jobs running ([docs/benchmarks.md](docs/benchmarks.md)):

- **1.6 ms per frame** on the Neural Engine (1.75 ms p95), with 0.75 ms and 1.8 mJ of CPU per frame. The Python version took 8.5 ms and about 107 mJ.
- **About 7 mJ of CPU energy per look** after 30 s of idle (median), against 320 mJ in the Python version.
- **The whole app while watching:** 32 MB resident, against about 250 MB for the Python version. On the demo camera it used 0.09 to 0.12% of a core and 8 to 9 J of CPU energy an hour, measured while this Mac was busy (load average 5 to 10); under the same load the engine alone used 0.08%. The Python version used 0.98% and 40.8 J an hour.
- **Accuracy on LFW stand-ins:** strangers score at most 0.333 (p99 0.223); owner-like probes reach 0.723 or more 95% of the time. The threshold floor is 0.44, where 0.18% of owner probes fail, which is 2 mislabelled images.
- **Camera on per check:** not measured on hardware yet. Settings > Diagnostics > Measure Camera Timing measures it in the app. The Python version kept the camera on for 2.04 s per check.

Webcam strangers and your own scores across days are not measured at scale. LFW strangers are news photos and score lower than a stranger at your own webcam would.

## Privacy

Nothing leaves the Mac and no camera frame is saved. FaceLock keeps two files:

- `~/Library/Application Support/FaceLock/enrollment.v2`: your face templates (lists of 512 numbers, not pictures) and your thresholds with their history, encrypted with AES-GCM under a key in your login keychain, file mode 0600.
- `~/Library/Logs/FaceLock/checks.jsonl`: one line per check with camera time, scores, quality flags and the verdict. No images and no templates. Rotated at 5 MB, kept 30 days.

Settings > Privacy shows a weekly summary, shows the log in Finder, and has **Delete All FaceLock Data**, which moves both files to the Trash and removes the key. Details: [docs/privacy.md](docs/privacy.md).

## Settings

| Pane | What's there |
|---|---|
| General | How often to check (with the real time to lock for each preset), countdown length (5, 10 or 15 s), slower checks on battery, notifications, sound, start at login |
| Detection | Your threshold report, Recalibrate, Check with Someone Else, Teach a New Look, learned looks and Reset, lock when someone else is looking, the still-face check (Off, Observe, On) |
| Privacy | What is stored and where, the last 7 days (locks, how many you cancelled, camera time), show or delete the log, delete everything |
| Diagnostics | Where each model runs (Neural Engine or CPU), whether the lock call is present (never called there), Measure Camera Timing |

<img src="assets/generated/ui-settings-general.png" width="560" alt="Settings, General: Relaxed, Balanced and Strict with how soon each locks, countdown 5, 10 or 15 s, slower checks on battery, notifications, sound, start at login">

## Limits

- Strangers at your own webcam score higher than the LFW strangers the floor comes from, and nobody has measured by how much. Use Check with Someone Else.
- Siblings and twins can score like you.
- In low light more checks come back unclear, so a countdown is more likely while you are there.
- One camera. With the lid closed and no external camera, FaceLock waits.
- FaceLock locks with a private macOS call (`SACLockScreenImmediate`), which a Developer ID app may use and the App Store does not allow. If the lock fails it puts the display to sleep, which locks only when a password is required immediately after sleep, and tells you.
- Photos and video: see the second paragraph of this page.

## Try it without a camera

```sh
build/FaceLock.app/Contents/MacOS/FaceLock --demo-camera Tests/Fixtures/grace_hopper.jpg --demo-enrolled
```

The demo camera shows a stored photo, never locks, and keeps its files in a temporary folder. The menu gets "Take the Photo Away" to walk through the rechecks and the countdown. `--dry-run` instead watches with your real camera and enrollment and logs the lock instead of locking.

## Build from source

```sh
python -I tools/convert_models.py   # models/*.mlpackage from pinned upstream files (tools/requirements.lock.txt)
swift test                          # Vision tests skip with a message when models/ is absent
scripts/build-app.sh                # build/FaceLock.app, signed with your Developer ID when you have one
scripts/notarize.sh                 # build/FaceLock.dmg, notarized and stapled (see the top of the script)
scripts/screenshots.sh              # the images on this page, from the demo camera only
scripts/install-hooks.sh            # a pre-commit hook that refuses face data, models and stray images
```

Reproduce the numbers with `bench/lfw.sh` and `scripts/bench.sh` ([docs/benchmarks.md](docs/benchmarks.md)). The Python version is kept at the tag `python-0.4.0`.

| Module | What it does |
|---|---|
| `FaceLock` | The menu bar app: setup, the countdown panel, Settings, Teach, migration from the Python version |
| `FaceLockCore` | The watcher state machine, cadence presets, verdict rules, scoring, calibration, learning safeguards, the still-face check, the encrypted store, the log. No AppKit or AVFoundation |
| `FaceLockVision` | YuNet and ArcFace r50 on Core ML, the vImage scale and warp, crop light and sharpness |
| `FaceLockCapture` | The camera session, the exposure-settle gate and frame pacing, the stored-image camera |
| `FaceLockSystem` | The lock with confirmation, session state, idle time, sleep and wake, the login item, notifications, Touch ID, the keychain |
| `facelock-bench` | The benchmark harness |

## Licences

The code licence is not chosen yet. YuNet is MIT (opencv_zoo). The InsightFace r50 weights are for non-commercial research only: the repository holds no weights, but the app and the DMG bundle them, so a personal copy is fine and publishing a DMG redistributes them.
