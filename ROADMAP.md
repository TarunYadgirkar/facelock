# Roadmap

What to build next, in order. Ranked from a fact-checked research pass on 2026-09-04 (102 agents,
3-vote adversarial verification per claim) over comparable tools (Windows Dynamic Lock, BLEUnlock,
windows-face-unlock, EyesOff, ProxSentry), anti-spoofing models, and ArcFace robustness papers.
Items FaceLock already has are noted so they are not rebuilt.

## Already in place (verified against the same evidence)

- **Strikes + cancelable grace** — `confirm_checks` consecutive misses, rechecks closing in, a
  return cancels the lock. windows-face-unlock and BLEUnlock land on the same design.
- **Sparse sampling, camera released between checks** — the one earlier macOS attempt at a webcam
  presence lock (ProxSentry) ran continuously and its author called it "basically useless" for
  battery and the always-on camera light. Keep the ~30 s poll.
- **Per-enrollment threshold calibration** against an impostor bank. Current 0.42 sits inside
  InsightFace's stated 0.30–0.45 cosine band for FMR 1e-4 to 1e-5.

## 1. Photo-replay liveness gate (MiniFASNet)

A printed photo or a phone showing your face currently counts as you. Silent-Face-Anti-Spoofing's
MiniFASNetV2 is 0.43 M params / 0.08 GFLOPs (a third of MobileFaceNet), ships as ONNX, and runs
with cv2/numpy only. windows-face-unlock already pairs it with the exact YuNet + ArcFace stack.

- Run it on the aligned crop only when the ArcFace score passes; a spoof verdict counts as a miss
  and logs `spoof_suspected`.
- Expect flat-photo defense only. Video replay and masks are **not** evidenced; do not claim them.
- Vendor accuracy (97.8 % TPR at 1e-5 FPR) is self-reported. Measure it on this webcam before
  trusting it: `facelock test --spoof` against a phone photo.

## 2. Lighting-aware decisions

Lighting hurts ArcFace more than glasses or makeup (99.5 % → 93.2 % under sensor noise; both-dark
impostor pairs raise FMR; bright/dark mismatch between enrollment and probe raises FNMR).

- Record mean luminance and a blur/noise proxy per frame. Below a floor: require one extra strike
  rather than accepting a marginal score, and show "dark" in the menu line.
- Add lessons "Teach: evening light" and "Teach: daylight" so the enrollment spans conditions.
- Gate on face size: skip embedding when inter-pupillary distance is under ~48 px (too far / too
  small to be reliable); count it as "no face", not "stranger".

## 3. Second-face (shoulder-surfer) mode

The detector already returns a face count. EyesOff sells exactly this on top of YuNet.

- Setting: "Warn when someone else is in frame while I am here" with a configurable extra-face
  count. Responses, graded and user-chosen: banner → dim display → hide notifications (Focus) →
  lock. Ship count-based first; gaze classification is noisy (~71 % in EyesOff's own numbers).
- Any auto-blur/obscure must be an opt-in toggle. Eye-Shield's study found it works (surfers read
  ~19–25 % of content) but users reported eye strain and wanted manual activation.

## 4. Event hooks for Shortcuts / Focus

Mirror BLEUnlock: run `~/Library/Application Scripts/facelock/event <name>` for `owner_absent`,
`locked`, `owner_returned`, `unknown_face`, `spoof_suspected`, `intruded`. `intruded` = the screen
was unlocked within ~10 s of a check that did not see you (needs "require password immediately").
This lets Shortcuts drive Focus modes, mute Slack, or ping a phone without FaceLock hard-coding any.

## 5. Bluetooth as a second signal (design open)

Paired iPhone / Apple Watch RSSI is the other cheap presence signal (BLEUnlock's whole product).
Unresolved: which signal may veto a lock. Phone-on-desk while you walk away is the hole, so the
face must stay the lock trigger; BLE should only *shorten* the grace when the phone is also gone,
never extend it. Measure before building.

## 6. Adaptive cadence and power measurement

Nobody has published the energy cost of a periodic camera wake + detector + embedding on Apple
Silicon. Measure it (`powermetrics`), then lengthen the interval while you have been stably present
for N minutes and tighten it after any miss.

## Known weak spots to document, not fix

Masks, large pose, and low resolution degrade open-source ArcFace (masked FNMR at FMR 1e-5 was
71.8 % for MS1MV2 ArcFace in the WebFace260M track). A masked or turned-away owner reads as absent;
the strikes/grace design is the mitigation. No third-party-accessible IR/TrueDepth or attention
signal surfaced for macOS; RGB webcam plus Bluetooth is the ceiling.

## Sources

- https://github.com/caochitam/windows-face-unlock
- https://github.com/ts1/BLEUnlock
- https://github.com/minivision-ai/Silent-Face-Anti-Spoofing/blob/master/README_EN.md
- https://github.com/yakhyo/face-anti-spoofing
- https://www.insightface.ai/guides/choose-face-recognition-model-and-evaluate
- https://arxiv.org/pdf/2412.02479 (OODFace), https://arxiv.org/pdf/2206.01881 (brightness vs FMR/FNMR)
- https://tidbits.com/2026/05/19/appbits-eyesoff-alerts-you-to-shoulder-surfing/
- https://www.bjaytang.com/projects/post_008/ (Eye-Shield, USENIX Security '23)
- https://github.com/peteburtis/ProxSentry
- https://www.pcworld.com/article/3210834/this-windows-security-trick-auto-locks-your-pc-when-you-leave.html
