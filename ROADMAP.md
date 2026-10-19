# Roadmap

What to do next, in order. The first three need a real camera and a real owner; nothing else should ship before them.

## 1. Measure the camera on hardware

The target is a median of 0.6 s or less of camera on-time per present check (1.2 s p95), against 2.04 s in the Python version. The engine stops at the first frame that shows you, but camera open, first frame and exposure settle have only been measured on the stored-image camera. Run Settings > Diagnostics > Measure Camera Timing, then check the weekly median in Settings > Privacy after a few days of use. Camera time is the battery lever: CPU energy is already a few joules an hour.

## 2. Tune the provisional limits from a week of the log

S = 0.25, the quality gate (eyes 28 px apart, 25° roll, 0.35 yaw, luma 40, half the enrollment's sharpness) and the enrollment pose rules come from LFW stand-ins, not from a person at a webcam. Read `~/Library/Logs/FaceLock/checks.jsonl` after a week: how often owner checks come back unclear and why, how many countdowns you cancelled (the false-lock rate), and how close your scores sit to T.

## 3. Decide on the still-face check

It ships in Observe mode. Count its flags in the log while you work normally; switch the default to On only if you are never flagged.

## 4. A recognizer you can redistribute

The InsightFace r50 weights are for non-commercial research only. A private DMG is fine; a public release that bundles them redistributes them. Bake off a permissively licensed recognizer with `facelock-bench accuracy` before any public DMG.

## 5. Photo and screen replays (experimental)

- A planar-motion test: when the head moves, a print fits one homography and a face shows parallax between the nose and the face outline.
- MiniFASNet (Apache-2.0, 80x80 input) on Core ML behind an experiment flag, enabled only after measuring its catch rate and your false alarms on a spoof set recorded locally (prints, a phone, a laptop screen). That set is never committed.

Neither tells a video of you from you. The README must keep saying so.

## 6. Event hooks for Shortcuts

Run `~/Library/Application Scripts/com.tarunyadgirkar.facelock/event <name>` on `away`, `locked`, `back`, `someone_else` and `still_face`, so Shortcuts can change Focus or mute a chat app without FaceLock knowing about either.

## 7. Bluetooth as a second signal (design open)

A paired iPhone or Watch going out of range is the other cheap presence signal. A phone left on the desk is the hole, so the face stays the lock trigger; Bluetooth may only shorten the grace when the phone has gone too, never extend it.

## Known limits to document, not fix

Masks, large head turns and low resolution degrade ArcFace; a masked or turned-away owner reads as absent, and the rechecks and countdown are the mitigation. Siblings and twins can score like the owner. macOS offers no IR or depth camera to third-party apps, so an RGB webcam is the ceiling.
