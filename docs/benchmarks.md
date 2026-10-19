# Benchmarks

Everything here comes from `scripts/bench.sh`, which runs `facelock-bench` and writes aggregates only to `bench/results/<date>-<chip>.json`. The harness never reads owner images; it uses LFW funneled and a public-domain photo of Grace Hopper. Results below: `bench/results/2026-10-18-apple-m5-pro.json`, Apple M5 Pro, macOS 27.0.1, with other jobs running (load average 3 to 15).

## Reproduce

```sh
python -I tools/convert_models.py        # builds models/*.mlpackage and .mlmodelc from the pinned upstream files
bench/lfw.sh                              # LFW funneled, figshare 5976015, sha256 b47c8422...100a
scripts/bench.sh                          # about 20 minutes; IDLE_SECONDS and LOCKED_SECONDS shorten it
```

`tools/requirements.lock.txt` pins the conversion environment (Python 3.12, torch 2.7.0, coremltools 9.0, onnx2torch 1.5.15, onnx 1.23.2). `tools/models.lock.json` pins the upstream files by sha256.

## Accuracy on LFW stand-ins

`facelock-bench accuracy` rebuilds the 0.4 impostor-bank list in Swift (numpy's PCG64 and shuffle, bit for bit) and checks it against sha256 `d6c2e2b8...9462`; `bench/make_manifest.py` does the same with numpy. The list has 4,000 strangers (the first image of each sampled LFW identity) and 1,140 images of 5 stand-in owners (George W. Bush, Colin Powell, Tony Blair, Donald Rumsfeld, Gerhard Schroeder). Each owner is enrolled with all of their images and scored leave-one-out; every stranger is scored against each owner it is not. Score = mean of the 3 closest templates.

The harness places each 250x250 LFW image at 240x240 inside the 320x240 detector input on grey, where a face sits in a 640x480 camera frame after the 2x downscale, and warps the crop from the original pixels. Every image is embedded, as in the decision's N2 run; the quality gate would call 32 owner and 106 stranger images unclear (mostly turned heads).

| Pipeline | Stranger max | Stranger p99 | Stranger p99.9 | Owner p5 | Owner p1 | d' | EER |
|---|---|---|---|---|---|---|---|
| This build: YuNet + r50, Core ML | 0.3330 | 0.2227 | 0.2798 | 0.7234 | 0.6880 | 13.59 | 0.175% |
| N2 probe (decision spec) | 0.3330 | 0.2227 | 0.2798 | 0.7234 | 0.6880 | 13.59 | 0.175% |
| Python 0.4: YuNet + mbf, ONNX Runtime | 0.3753 | 0.2493 | | 0.6519 | | 11.04 | 0.175% |

- Floor F = ceil(0.3330 + 0.10) = **0.44**, the committed value.
- FRR at F is 0.18%, and stays there at every threshold from 0.30 to 0.60. That floor is 2 mislabelled LFW images every pipeline fails.
- Adaptation replay: each owner enrolled with their first 54 images, the rest replayed 2 h apart with learning on (47 to 120 learned looks each). The worst stranger against an adapted gallery scored 0.3330, under the limit F - 0.05 = 0.39, and no stranger passed the owner rule.

Not measured: webcam strangers (LFW strangers score lower than strangers on your own webcam would), and owner scores across sessions on real hardware. No owner images exist, so T for a real owner, S = 0.25 and the quality-gate limits are provisional.

## Speed and energy

CPU energy is `ri_energy_nj` from `proc_pid_rusage`; Neural Engine, GPU, camera and ISP energy are not visible to an unprivileged process.

| Measure | Result | Target |
|---|---|---|
| Per frame on LFW (detect, align, quality, embed) | 1.59 ms mean, 1.75 ms p95 | 2.5 ms p95 |
| Per frame, camera path on a 640x480 frame | 1.85 ms mean, 1.90 ms p95 | 2.5 ms p95 |
| CPU per frame, net of image preparation | 0.75 ms, 1.80 mJ | |
| Look after 30 s idle (3 frames) | 7 to 18 ms CPU; median 6.7 mJ (one outlier at 58 mJ under load) | 10 ms, 15 mJ |
| Launch to first decision, camera excluded | 59 to 94 ms; peak footprint 16 MB | 0.3 s, 60 MB |

Stage times on LFW: YuNet 0.24 ms, warp 0.10 ms, crop luma and sharpness 0.05 ms, r50 1.20 ms. Both models run on the Neural Engine with `.cpuAndNeuralEngine`: YuNet 132 of 132 ops, r50 133 of 136 ops (98% of the estimated cost).

The first frame after idling pays for waking the Neural Engine (3 to 46 ms of YuNet wall time in these runs). A present check stops after its first frame, so a check is one such frame.

## Idle

`facelock-bench idle` runs the real watcher (`WatchController`, `CheckRunner`) in dry run on the stored-image camera, Balanced cadence, after a 20 s warmup.

| State | CPU | CPU energy | Footprint | Target |
|---|---|---|---|---|
| Present, 600 s, 20 checks | 0.034% of a core | 2.5 J/hour (0.5 in an earlier run) | 12 MB (peak 18 MB) | 0.05%, 4 J/hour, 60 MB |
| Screen locked, 300 s | 0.0007% of a core | 0.05 J/hour | 12 MB | 0.01%, 0.5 J/hour |

The Python version used 0.98% of a core and 40.8 J/hour present, 0.65% and 16.1 J/hour locked, at 248 to 262 MB. While the screen is locked no timer runs at all.

The stored-image camera delivers settled frames at once, so these camera on-times are not hardware numbers. Camera open, first frame and exposure settle need the app's camera permission and are measured from Diagnostics > Measure camera timing.

## The app

The release `FaceLock.app` (`scripts/build-app.sh`, Developer ID signed) watching the demo camera with `--demo-camera Tests/Fixtures/grace_hopper.jpg --demo-enrolled`, Balanced, sampled with `proc_pid_rusage` from 40 s to 340 s after launch. The machine was busy: load average 5 to 10, swap 15.1 of 16.4 GB in use.

| Measure | Result | Target |
|---|---|---|
| Resident footprint while watching | 32 MB (peak 100 MB while the demo enrollment loads a second pipeline) | 60 MB |
| CPU, two 300 s runs, 10 checks each | 0.091% and 0.119% of a core | 0.05% |
| CPU energy | 8.0 and 8.8 J/hour | 4 J/hour |
| Between checks | about 0.02% of a core | |
| Per present check | 27 to 40 ms of CPU | 10 ms |
| App bundle | 88 MB: binary 3.6 MB, ArcFaceR50 83 MB, YuNet 0.4 MB | |

Under the same load, `facelock-bench idle --seconds 100` (the engine alone) used 0.082% of a core, 3.1 J/hour and 14 to 37 ms per check, so most of the miss is the cost of a check on a loaded machine (waking the Neural Engine), and the app adds about 0.02% for the menu bar. The engine met both targets in the quieter run above. Re-measure the app on an idle Mac before quoting it against the targets.

## Implementation notes from the measurements

- **Detector input.** YuNet takes a 320x240 BGR image input; Core ML reads the BGRA pixel buffer directly. It replaced a float32 MLMultiArray input: detections are bit-identical on 60 LFW images and on all 5,140 (same accuracy to the fourth decimal), every op stays on the Neural Engine, YuNet takes 0.27 ms instead of 0.30 ms, and the CPU no longer converts 307,200 bytes to floats per frame.
- **Warp source.** vImageAffineWarp's output depends on the extent of the source buffer, not only on the pixels near the face: warping from a face-sized region of the frame moved the LFW stranger max by up to 0.004. The crop is warped from the whole frame, as N2 measured.
- **Reference crop.** vImage resamples with a Lanczos-type kernel. Against a Lanczos3 reference at the same landmarks the crop differs by 0.9 levels on average; against OpenCV's bilinear `warpAffine` it differs by 2.6 on the detailed fixture photo.
