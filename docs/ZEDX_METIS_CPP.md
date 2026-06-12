---
title: ZED X + Metis C++
layout: default
nav_order: 28
description: "Pure-C++ ZED X to Axelera Metis samples: a lean detector and a full sensor-fusion app (depth, point geometry, IMU, skeletons, tracking) using every accelerator on the Orin NX 16GB."
---

# ZED X + Metis C++ samples

Two self-contained C++ programs in [examples/zedx_metis_cpp/](https://github.com/silicondoritos/jetson-rt-stack/tree/main/examples/zedx_metis_cpp) that drive the ZED X camera into the Axelera Metis NPU **without** the Voyager application framework: they call `libaxruntime` directly. They exist to show the camera→NPU path in plain C++ and to squeeze the Orin NX 16GB's accelerators as hard as the hardware allows.

This page is the design + tuning reference. For copy-paste run commands and the verification gauntlet, see [Samples & Tests]({{ '/SAMPLES' | relative_url }}) §3; for the full measured dataset (FPS, GPU load, power, thermals) and the reproducible harness, see [Benchmarks]({{ '/BENCHMARKS' | relative_url }}).

| Program | What it does | Use it for |
|---|---|---|
| `zedx_metis_infer` | Lean detector: ZED grab → letterbox+quantize → Metis → decode+NMS → draw | Max detection throughput, no depth |
| `zedx_metis_fusion` | Everything at once: detection + stereo depth + point geometry + IMU pose + skeletons + tracking | Perception demo, planner front-end |

Both auto-detect YOLOv5 (anchor) vs YOLOv8 (anchor-free DFL) heads from the runtime tensor layout, and auto-resolve the deployed core-count build directory (`4/`, `2/`, `1/`).

## Quick start

```bash
cd ~/Documents/jetson-rt-stack/examples/zedx_metis_cpp
cmake -B build && cmake --build build          # CUDA + libaxldev; ~1 min

# fusion, all features, runs until Esc:
DISPLAY=:0 sg zed -c './build/zedx_metis_fusion --model yolov8s-coco --depth-every 3'

# lean detector only:
DISPLAY=:0 sg zed -c './build/zedx_metis_infer --model yolov8s-coco'
```

`sg zed -c '...'` is only needed until you re-login (it grants the `zed` group). Models must be deployed once with the Voyager SDK; see [§ Models](#models).

## Architecture

`zedx_metis_fusion` is a **three-stage pipeline**; the stages run on separate threads and overlap, so end-to-end throughput is set by the slowest single stage, not their sum:

```
 STAGE 1  capture (1 thread)            STAGE 2  inference     STAGE 3  render (main)
 ┌──────────────────────────────┐      ┌──────────────┐       ┌───────────────────────────┐
 grab() ─ retrieveImage(GPU)            axr_run_model  ──────► decode (shared yolo_decode)
   │       └ CUDA letterbox+quant ─┐    on the Metis           IoU track + EMA + vel/TTC
   │         (preprocess.cu) ──────┼──► (yolov5/v8)            median depth → distance
   │       └ GPU downscale (disp)  │    PCIe DMA ∥ GPU         deproject + pose → world XYZ
   │       └ copy → dma-heap buf ──┘                           skeleton↔person, head keep-out
   ├ DEPTH (every Nth grab)                                    draw boxes/skeletons/IMU gizmo
   ├ retrieveBodies (every Nth)                                imshow / record / UDP publish
   └ pose + IMU (every grab)
        ring of N slots ───────────────► inferq ─────────────► renderq ──► back to free pool
```

A fixed **ring of slots** (each with its own input buffer, output buffers, display frame, depth slab, and skeleton array) flows through three lock-free-ish queues (`free → infer → render → free`). **Zero per-frame heap allocation**: every buffer is preallocated; pinned host buffers via `cudaHostAlloc`, NPU input via the Axelera dma-heap allocator.

### Which accelerator does what

The whole point is that the heavy work lands on **different** engines so they run concurrently:

| Work | Engine | Notes |
|---|---|---|
| Object detection | **Metis NPU** (PCIe) | yolov5/v8; overlaps GPU via PCIe DMA |
| Letterbox + int8 quantize | **GPU** (CUDA kernel) | straight from the ZED GPU image; no CPU loop |
| Stereo depth (NEURAL_LIGHT) | **GPU** | computed inside `grab()`; the heavy iGPU cost |
| Skeleton / body tracking | **GPU** (ZED AI, FP16) | `HUMAN_BODY_FAST`, BODY_18 |
| Display downscale + rectification | **GPU** | all GPU work on the one ZED CUDA stream |
| Decode + NMS + tracking + fusion | **CPU** | shared `yolo_decode.hpp` |
| Idle / available | **2× NVDLA, PVA, OFA** | not used today; see [§ Phase-2](#phase-2-ofapva-depth-via-vpi) |

## The twelve enhancements

The fusion sample was built up from a basic detector through twelve targeted improvements (all live on the reference device, 2026-06-11):

1. **GPU preprocess → dma-heap input.** A CUDA kernel (`preprocess.cu`) does letterbox + int8 quantize directly from the ZED GPU image into an Axelera dma-heap buffer the Metis DMAs from: no CPU quantize loop, no staging copy. Falls back to a pinned host buffer if the dma-heap is unavailable.
2. **DEPTH F32_C1** instead of the full XYZ point cloud (¼ the bandwidth; distance is all we sample).
3. **GPU-downscaled display frame**: resized on the GPU before the host download, so only the 800×600 window image crosses the bus.
4. **3-stage pipeline** (capture ∥ inference ∥ render) so the Metis, GPU, and CPU overlap.
5. **Skeleton ↔ person-box matching**: a ZED body is matched to a yolo "person" detection so the head keep-out comes from real head keypoints, not a fixed top-fraction guess.
6. **3D head position** from `keypoint[NOSE]` in meters.
7. **World-frame detections**: box centre deprojected with the camera intrinsics + depth, then transformed by the IMU-fused pose.
8. **IoU tracker** with EMA box smoothing, stable track ids, velocity, and time-to-collision.
9. **Config CLI flags** + `--model-root` / `--labels` paths.
10. **Output stream**: optional annotated MP4 (NVENC via GStreamer, software fallback) and UDP JSON publish of detections.
11. **Shared `yolo_decode.hpp`**: one decode source for both samples (the earlier duplicate-source bug fix had to be applied twice; now it can't).
12. **cv::cuda on the ZED CUDA stream**: preprocess/resize ride `getCUDAStream()` so they order correctly behind the SDK's own GPU work with no extra sync.

## Models

Deploy once with the Voyager SDK (compiles + quantizes for the Metis). yolov8 models need `ultralytics`, which must be kept out of the root-owned `/opt/av-env`:

```bash
cd ~/voyager-sdk
# yolov5s (4-core): the original
./inference.py yolov5s-v7-coco media/h264/traffic1_1080p.mp4
# yolov8s (4-core) / yolov8l (falls back to 1-core):
PIP_NO_DEPS=1 PIP_TARGET=~/.local/avextras PYTHONPATH=~/.local/avextras \
  /opt/av-env/bin/python deploy.py yolov8s-coco --aipu-cores 4
```

### How `--aipu-cores` actually works (and why yolov8l is single-core)

`--aipu-cores N` is **data/batch parallelism**, not model/layer splitting: the compiler builds the model to run on N of the Metis's 4 AIPU cores, and the runtime feeds N frames per dispatch (the batch dimension is literally `N` in the input shape). It does **not** split one model's layers across cores.

- **yolov5s / yolov8s** are small enough to fit 4 co-resident copies → batch-4, `4/` build dir.
- **yolov8l**'s constants are ~7× larger; 4 copies don't fit the on-chip budget, so the compiler falls back to **1 core, batch-1** (`1/` build dir). The whole network still runs at full accuracy, just one frame at a time, ~25 ms/inference.

Grounded against the Axelera Voyager docs (`compiler_configs.md`, `deploy.md`) and the on-disk manifests. See [AV Stack]({{ '/AV_STACK' | relative_url }}) for the inference procedure.

## Performance & tuning

> Full measured dataset (FPS, GPU load, power, thermals) with charts and the
> reproducible harness is on the [Benchmarks]({{ '/BENCHMARKS' | relative_url }}) page.

Headline numbers from the live tuning session on the reference Orin NX 16GB (display attached unless noted; HD1200@60, all fusion features on, 2026-06-11). Expect a few fps of run-to-run variance; the headless harness dataset on the [Benchmarks]({{ '/BENCHMARKS' | relative_url }}) page is the canonical, reproducible reference.

| Config | FPS | Bottleneck |
|---|---|---|
| `zedx_metis_infer`, yolov8s, SVGA@120, headless | **86** | NPU pipeline (no depth) |
| fusion, yolov8s, `--depth-every 1` | 45 | depth every frame |
| fusion, yolov8s, `--depth-every 3` (recommended) | **57** | camera (60 fps) |
| fusion, yolov8s @ SVGA, live display | **~50, stable** | (was 25→17 and laggy before tuning) |
| fusion, yolov8l, any `--depth-every` | ~40 | **Metis single-core inference** |

### `--depth-every N`: keep all features and still go fast

The only heavy iGPU consumers are NEURAL_LIGHT depth (computed *inside* `grab()`) and the body net (`retrieveBodies`); both otherwise gate every frame at ~28 fps. `--depth-every N` runs them on **every Nth grab** while detection (Metis), display, and pose run **every** frame. The last depth slab and skeletons carry forward, and the IoU tracker smooths distance/velocity/TTC between updates, so **no capability is lost**: depth and skeletons just refresh at ~rate/N (default N=3 → ~19 Hz). In the live display tuning session this took yolov8s fusion from 45 fps (`--depth-every 1`) to 57 fps (`--depth-every 3`) and removed the SVGA lag. The headless bench harness (short ~14 s windows in the recorded dataset) measures the same lever at 35 → 53 fps across `--depth-every` 1 → 6; depth cost is scene-dependent, so the sessions differ by a few fps while showing the same trend. See [Benchmarks]({{ '/BENCHMARKS' | relative_url }}#decoupling-depth-cadence---depth-every).

### Picking a configuration

- **All features, fastest & smooth** → `--model yolov8s-coco --depth-every 3` (~57 fps HD1200@60).
- **Most accurate** → default yolov8l, ~40 fps (capped by the single-core Metis inference, not depth; `--depth-every` is moot there).
- **Raw detection rate, no depth** → `zedx_metis_infer --model yolov8s-coco` (~86 fps SVGA@120).
- **At SVGA prefer `--fps 60`, not 120.** The full pipeline can't consume 120 fps; the surplus only builds capture latency (the lag and "duplicate/corrupted frame" warnings). Match the camera rate to what the pipeline drains.

There is **no config that is both "largest model" and ">40 fps"**: yolov8l's single-core inference is the wall. yolov8s gives 57 fps with every feature live.

## Flag reference (`zedx_metis_fusion`)

| Flag | Default | Meaning |
|---|---|---|
| `--model NAME` | `yolov8l-coco` | network name (resolves `<root>/NAME/NAME/{4,2,1}/model.json`) |
| `--mode HD1200\|HD1080\|SVGA` | HD1200 | camera resolution |
| `--fps N` | 60 | camera capture rate (SVGA supports 120) |
| `--seconds N` | 0 | 0 = run until Esc; N caps the run |
| `--depth-every N` | 3 | run depth + skeleton every Nth grab |
| `--conf F` / `--iou F` | 0.25 / 0.45 | detection confidence / NMS IoU |
| `--depth-max M` | 20 | max depth distance (m) |
| `--head-frac F` | 0.22 | head-zone fraction when no skeleton match |
| `--kp-conf F` | 30 | per-keypoint confidence gate |
| `--no-bodies` | off | disable skeleton tracking |
| `--record FILE.mp4` | off | annotated H.264 MP4 via hardware **NVENC** (GStreamer); software mp4v fallback |
| `--record-fps N` | 0 (auto 30) | fps tag for the recording; set to the run's sustained rate for realtime playback |
| `--publish HOST:PORT` | off | UDP JSON of detections |
| `--model-root DIR` / `--labels PATH` | voyager-sdk paths | portability overrides |
| `--headless` | off | no window (throughput / servers) |

`zedx_metis_infer` shares the mode/fps/seconds/model/headless flags and adds `--image <jpg|png|mp4>` for a no-camera decode smoke test.

### UDP publish schema

One datagram per rendered frame:

```json
{"t": 12.34, "obj": [
  {"id": 7, "cls": 0, "score": 0.94, "dist": 1.83,
   "world": [0.21, -0.04, 1.79], "vel": -0.12}
]}
```

`cls` is the COCO class index, `dist` metres (NaN if no depth), `world` the IMU-fused world-frame XYZ in metres, `vel` the closing speed (m/s, negative = approaching).

## Operational notes

- **Camera/NPU contention.** The full ROS mission (`jetson-av-mission.service`) holds the camera (via `zed_wrapper`) and the Metis (via `detect_metis.py`). These samples need exclusive access, so stop the mission first: `sudo systemctl stop jetson-av-mission.service jetson-av.slice`. The mission is **disabled from auto-start** on the reference device; start it manually when you want it.
- **Always quit with Esc** (or Ctrl-C when `--headless`). Because the app now runs until Esc, a forgotten run keeps holding the camera in the background.
- **Camera wedged?** An abrupt kill (SIGKILL) of a process mid-grab can leave the GMSL camera in a bad state (`CAMERA STREAM FAILED TO START`). Recover with `sudo systemctl restart zed_x_daemon` and wait ~15 s.

## Phase-2: OFA/PVA depth via VPI

The 2× NVDLA, PVA, and OFA sit idle today. The largest remaining lever is moving stereo depth off the GPU and onto the **OFA + PVA + VIC** via NVIDIA VPI's stereo-disparity estimator (open the camera with `DEPTH_MODE::NONE`, feed rectified LEFT/RIGHT grayscale, convert disparity → depth with `fx·baseline/disparity`). That frees the iGPU's biggest consumer and would roughly double depth headroom. It is **not** the default because classical SGM disparity is noisier than NEURAL_LIGHT on textureless/reflective/thin surfaces: a quality trade-off to validate against the keep-out/TTC use case before adopting. Scoped but unbuilt.

## Source map

| File | Role |
|---|---|
| `zedx_metis_infer.cpp` | lean detector |
| `zedx_metis_fusion.cpp` | full 3-stage fusion pipeline |
| `yolo_decode.hpp` | shared v5/v8 host decode (`yolo::Decoder`, RawDet, NMS, palette) |
| `preprocess.cu` / `.cuh` | CUDA letterbox + int8 quantize kernel |
| `CMakeLists.txt` | CUDA-enabled build; links axruntime, ZED, OpenCV-CUDA, libaxldev |
