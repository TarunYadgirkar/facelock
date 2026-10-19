# Benchmarks

Everything here comes from `scripts/bench.sh`, which runs `facelock-bench` and writes aggregates only to `bench/results/<date>-<chip>.json`. The harness never reads owner images or the real camera; it uses LFW funneled and a public-domain photo of Grace Hopper. Every step's load average (1, 5 and 15 minutes) is recorded before and after it and stored with its result, because every timing and energy figure below moves with load.

Results below: `bench/results/2026-10-18-apple-m5-pro.json`, Apple M5 Pro, macOS 27.0.1, with other jobs running (1-minute load average 2.4 to 5.6 during the run) and heavy memory pressure (swap 17.4 of 18.4 GB in use at the end).

## Reproduce

```sh
python -I tools/convert_models.py        # builds models/*.mlpackage and .mlmodelc from the pinned upstream files
bench/lfw.sh                              # LFW funneled, figshare 5976015, sha256 b47c8422...100a
scripts/build-app.sh                      # build/FaceLock.app, for the app runs
scripts/bench.sh                          # about 45 minutes; IDLE_SECONDS, LOCKED_SECONDS and APP_SECONDS shorten it
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

| Measure | Result | Load average (1 min) | Target |
|---|---|---|---|
| Per frame, camera path on a 640x480 frame (vImageScale, detect, align, quality, embed, score) | 1.89 ms mean, 1.96 ms p95 | 4.3 to 4.4 | 2.5 ms p95 |
| CPU per frame, camera path | 1.05 ms, 4.1 mJ | 4.3 to 4.4 | |
| Per frame on LFW (detect, align, quality, embed) | 1.62 ms mean, 1.74 ms p95 | 4.3 to 4.4 | |
| CPU per frame on LFW, net of JPEG decode and framing | 0.90 ms, 2.3 mJ | 4.3 to 4.4 | |
| Look after 30 s idle (3 frames) | 13.5 ms CPU and 38.7 mJ median (13 to 19 ms, 25 to 61 mJ) | 3.4 to 4.4 | 10 ms, 15 mJ |
| Launch to first decision, camera excluded | 65 to 163 ms (the first run loads the models cold); peak footprint 15.5 MB | 3.4 | 0.3 s, 60 MB |

The camera-path figure is the one the app runs, and the one the 2.5 ms target applies to. It holds on a lightly loaded machine; the audit before this release measured 4.8 to 5.6 ms mean on the same path at load averages of 5 to 11. The LFW figures are kept for comparison with the decision spec's N2 probe.

Stage times on the camera path: YuNet including the scale 0.34 ms, warp 0.26 ms, crop luma and sharpness 0.06 ms, r50 1.23 ms. Both models run on the Neural Engine with `.cpuAndNeuralEngine`: YuNet 132 of 132 ops, r50 133 of 136 ops (98% of the estimated cost).

The first frame after idling pays for waking the Neural Engine (32 ms of wall time median in the look-after-idle runs, against 2.1 ms for later frames). A present check stops after its first frame, so a check is one such frame.

## Idle

`facelock-bench idle` runs the real watcher (`WatchController`, `CheckRunner`) in dry run on the stored-image camera, Balanced cadence, after a 20 s warmup. `scripts/bench.sh` runs the present state twice.

| State | CPU | CPU energy | Footprint | Load average (1 min) | Target |
|---|---|---|---|---|---|
| Present, 600 s, 20 checks, run 1 | 0.039% of a core | 4.0 J/hour | 12 MB (peak 17 MB) | 3.4 to 5.6 | 0.05%, 4 J/hour, 60 MB |
| Present, 600 s, 20 checks, run 2 | 0.024% of a core | 2.2 J/hour | 12 MB | 5.6 to 2.4 | 0.05%, 4 J/hour |
| Screen locked, 300 s | 0.0004% of a core | 0.04 J/hour | 12 MB | 2.4 to 4.8 | 0.01%, 0.5 J/hour |

Both present runs meet the CPU target; the first sits right at the energy target. The audit before this release measured 0.060% at load 5 to 8, so the 0.05% target holds only on a lightly loaded machine: the cost of each check (about 15 to 19 ms of CPU on a busy machine) is what sets the percentage. The Python version used 0.98% of a core and 40.8 J/hour present, 0.65% and 16.1 J/hour locked, at 248 to 262 MB. While the screen is locked no timer runs at all.

The stored-image camera delivers settled frames at once (camera on 0.07 s per check here), so these camera on-times are not hardware numbers. Camera open, first frame and exposure settle need the app's camera permission and are measured from Settings > Diagnostics > Measure Camera Timing.

## The app

`facelock-bench app` measures the shipping `FaceLock.app` (`scripts/build-app.sh`, Developer ID signed) from outside: it launches it on the demo camera (`--demo-camera Tests/Fixtures/grace_hopper.jpg --demo-enrolled --data-dir <temp>`, never the real camera, never a lock), waits 40 s, samples `proc_pid_rusage` every 0.5 s for 300 s, and lines the samples up with the app's own check log. Half-second intervals that overlap a check (camera start to 1 s after its log line) are that check's; the rest give the cost of waiting between checks, and a check's cost is the total minus that rate. `scripts/bench.sh` runs it twice and gates acceptance on it.

| Measure | Run 1 | Run 2 | Earlier run, no paging | Target |
|---|---|---|---|---|
| CPU | 0.052% of a core | 0.045% | 0.032% | 0.05% |
| CPU energy | 4.8 J/hour | 4.1 J/hour | 2.7 J/hour | 4 J/hour |
| Between checks | 0.011% | 0.012% | 0.010% | |
| Per present check (1 frame) | 13.6 ms CPU, 37.9 mJ | 11.0 ms, 31.4 mJ | 7.2 ms, 18.9 mJ | 10 ms, 15 mJ |
| Of which FaceLock's own code (user time) | 1.7 ms | 1.7 ms | 1.4 ms | |
| Memory footprint (phys_footprint), median | 31 MB | 31 MB | 30 MB | 60 MB |
| Resident size, median and max | 19 MB, 93 MB | 16 MB, 48 MB | 31 MB, 90 MB | |
| Page-ins during the run | 700 | 625 | 4 | |
| Load average (1 min) | 4.8 to 3.8 | 3.8 | 5.4 to 2.8 | |

Runs 1 and 2 are in `bench/results/2026-10-18-apple-m5-pro.json`; the run without paging is the "after" run in `bench/results/2026-10-18-app-menubar-redraw.json`. Under memory pressure macOS takes the app's idle pages away between checks, and each check faults them back in: almost all of the per-check cost is then kernel time. The resident size moves with that pressure, which is why the footprint is the figure to compare. The per-check targets are not met, and the idle target is met only without heavy paging.

### Where a check's CPU went

Time Profiler (`xcrun xctrace record --template 'Time Profiler' --attach <pid>`, 146 s, 5 present checks on the demo camera) put the app's own CPU at about 25 ms a check before this release: about 9 ms redrawing the menu bar status item (`NSStatusItem _updateReplicants`), about 4 ms of Core Animation commits, about 4.6 ms in the pipeline (Core ML and the Neural Engine request included), and the rest in dispatch and timers. The status item was redrawn on every watcher state change, twice a check, although the icon looked the same. FaceLock now redraws it only when the icon's shape changes, and a check that finds you within half a second never shows the Checking icon. With the same build otherwise, the cost of a check fell from 18.7 ms and 52.6 mJ to 7.2 ms and 18.9 mJ, and the app from 0.068% to 0.032% of a core (`bench/results/2026-10-18-app-menubar-redraw.json`, load averages 4.4 to 5.7 and 5.4 to 2.8).

The app bundle was 88 MB in 0.5: the binary 3.9 MB, ArcFaceR50 83 MB and YuNet 0.4 MB. Since 2.0 it is 5.1 MB: the r50 weights are downloaded from InsightFace on first run and rebuilt into the same Core ML model (see "Recognizer runtime" below).

## Recognizer runtime

From 2.0 the r50 weights are not in the app: each user downloads InsightFace's `buffalo_l.zip`, and FaceLock runs `w600k_r50.onnx` from it with no Python. Four ways to run it were measured on 2026-10-19 (Apple M5 Pro, macOS 27.0.1, load average 5.8 falling to 1.6), embedding alone on 200 aligned crops from the camera path (the fixture photo plus 199 LFW people), each in its own process. `bench/results/2026-10-19-recognizer-runtime.json` has every figure and the method.

| Runtime | Lowest cosine vs 0.5 | Embed, mean / p95 | CPU per embed | CPU energy per embed | One embed after 20 s idle | Memory added | App size |
|---|---|---|---|---|---|---|---|
| Core ML, bundled model (0.5) | 0.999999 | 1.26 / 1.29 ms | 0.40 ms | 0.63 mJ | 24 ms, 4.0 ms CPU | 16 MB | 88 MB |
| **Core ML, model rebuilt from the ONNX file (2.0)** | **0.999999** | **1.25 / 1.30 ms** | **0.31 ms** | **0.65 mJ** | **31 ms, 4.8 ms CPU** | **21 MB** | **5.1 MB** |
| ONNX Runtime 1.24.2, Core ML provider | 0.99964 | 15.8 / 15.9 ms | 18.4 ms | 107 mJ | 29 ms, 33 ms CPU | 323 MB | about 36 MB |
| ONNX Runtime 1.24.2, CPU | 0.99964 | 16.5 / 19.0 ms | 115 ms | 507 mJ | 75 ms, 421 ms CPU | 706 MB | about 36 MB |
| MPSGraph on the GPU, fp16 | 0.99963 | 2.50 / 2.60 ms | 0.65 ms | 3.35 mJ | 31 ms, 13 ms CPU | 155 MB | 5 MB |
| MPSGraph on the GPU, fp32 | 0.99964 | 3.30 / 3.38 ms | 0.61 ms | 3.10 mJ | 175 ms, 29 ms CPU | 240 MB | 5 MB |

"Lowest cosine vs 0.5" compares each runtime's embedding with the 0.5 model's on the same crop; the 0.5 model against itself gives 0.999999 because the Neural Engine is not bit-exact from run to run. Memory added is phys_footprint after 500 embeds minus before loading.

FaceLock 2.0 uses the second row. The app ships the r50 model's compiled Core ML graph without `weights/weight.bin`, plus `ArcFaceR50.layout.json`, which maps each of the 237 blobs in `weight.bin` to the ONNX initializer it came from and the cast coremltools applied. On first run FaceLock reads those initializers from the downloaded file, writes `weight.bin` (0.6 s, 234 ms of CPU, 127 MB peak) and accepts it only if its SHA-256 matches the one pinned at conversion. The rebuilt model is byte for byte the 0.5 model, so the calibrated thresholds and every accuracy figure above still hold. On the camera path `facelock-bench latency` measured 1.87 ms mean and 0.84 ms of CPU a frame for it, against 1.95 ms and 0.89 ms for the bundled model in the same session, and `cold` 63.3 ms against 62.6 ms. The first load after the rebuild takes 0.8 s instead of 0.1 s while Core ML compiles the model for the Neural Engine at its new path; later loads are cached.

ONNX Runtime is 12 to 13 times slower per embed here, uses 46 to 290 times the CPU and adds a 31 MB library: its Core ML provider put 128 of the 130 nodes in two Core ML partitions and the rest on the CPU. MPSGraph runs on the GPU, about twice as slow with five times the energy per embed and 155 MB or more of extra memory, and its embeddings differ from 0.5's by up to 0.0004 in cosine, which would need the threshold checked again.

## Implementation notes from the measurements

- **Detector input.** YuNet takes a 320x240 BGR image input; Core ML reads the BGRA pixel buffer directly. It replaced a float32 MLMultiArray input: detections are bit-identical on 60 LFW images and on all 5,140 (same accuracy to the fourth decimal), every op stays on the Neural Engine, YuNet takes 0.27 ms instead of 0.30 ms, and the CPU no longer converts 307,200 bytes to floats per frame.
- **Warp source.** vImageAffineWarp's output depends on the extent of the source buffer, not only on the pixels near the face: warping from a face-sized region of the frame moved the LFW stranger max by up to 0.004. The crop is warped from the whole frame, as N2 measured.
- **Reference crop.** vImage resamples with a Lanczos-type kernel. Against a Lanczos3 reference at the same landmarks the crop differs by 0.9 levels on average; against OpenCV's bilinear `warpAffine` it differs by 2.6 on the detailed fixture photo.
