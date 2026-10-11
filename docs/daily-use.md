# Daily use

Open FaceLock from Applications or Spotlight. Its menu now includes:

- **Preview mode (never locks)**: exercise recognition and see when FaceLock would lock. Automatic locking and Lock Now are disabled once preview is active. The status line begins with `preview, never locks`. When switching, the current check finishes before preview becomes active. This setting lasts for the current app session; relaunch uses normal mode unless launched with `menubar --dry-run`.
- **Check Now**: start a fresh presence check instead of waiting for the normal interval. This starts a new absence sequence. It does nothing while paused or training, and never resumes a pause.
- **Help & Diagnostics → Health Check**: inspect configuration, enrollment, required model files, comparison bank, pause state, watcher PID, app launcher, and login-agent file. A living PID alone does not prove protection is working.
- **Camera Privacy Settings**: open the macOS camera permission pane.
- **Open Log**: open the current log in Console.

For a safe recognition trial, enable Preview, wait for the `preview, never locks` status, then Resume if paused. Look at the screen normally, look down, change lighting, and use Check Now to see whether the existing enrollment covers your usual positions. Use Training lessons for missed poses. Turn Preview off when ready for normal locking. Training uses the existing owner gate; no face images are saved.

## Terminal diagnostics

```sh
facelock doctor
facelock doctor --json
facelock menubar --dry-run
```

Doctor is read-only: it never opens the camera, downloads models, changes settings, or locks. It exits with 1 when a check fails and 0 when none fail. `unverified` checks still need attention or a live test. Model presence checks do not prove ONNX inference works; camera permission, recognition accuracy, and actual screen locking remain live checks.

A paused watcher does not protect the screen. Resume from the menu or `facelock resume` when ready. If no watcher is running, open the app before resuming.

## Reliability changes

Camera error counts now reset after pause or screen lock. A failed lock retries after a five-second backoff and a fresh absence check; recognizing the owner or pausing cancels the retry. Status says `lock requested` rather than claiming success before macOS confirms the lock.

Pause files are replaced atomically so polling cannot read a partially written pause. Stop rejects unsafe PID values and refuses to signal a process that cannot be identified as a FaceLock watcher.

Recognition thresholds remain unchanged. These changes do not add photo-replay resistance or prove recognition accuracy across other people and lighting conditions.
