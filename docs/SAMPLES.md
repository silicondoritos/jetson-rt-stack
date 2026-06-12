---
title: Samples & Tests
layout: default
description: "How to run every verification gauntlet, camera sample, and inference demo on the device, with expected outputs and measured baselines."
nav_order: 27
---

# Samples & Tests

This page is the operator's checklist: copy-paste run commands with expected
output for every verification gauntlet, camera sample, and inference demo.
The C++ samples' architecture and tuning flags are in
[ZED X + Metis C++]({{ '/ZEDX_METIS_CPP' | relative_url }}); the reproducible
FPS/GPU/power dataset is in [Benchmarks]({{ '/BENCHMARKS' | relative_url }}).

Every command below was verified live on the reference Orin NX (2026-06-11).
Prerequisites: the full stack per [Runbook]({{ '/RUNBOOK' | relative_url }})
R18 (nvidia-jetpack → Phase 5 → `install_zedx_daemons.sh` → Voyager app
setup). Camera samples need the user in the `zed` group. Re-login after
`install_zedx_daemons.sh`, or prefix with `sg zed -c '...'` as shown.

## 1. Verification gauntlets

```bash
cd ~/Documents/jetson-rt-stack

# RT kernel + isolation + vermagic + power + cyclictest
sudo bash scripts/verify_tuning.sh
# expected: all PASS; cyclictest avg ~3 µs. Max <100 µs requires a headless
# run. An interactive desktop session adds ~150 µs IPI spikes (known).

# CUDA / OpenGL / GLES / TensorRT / VPI / cuDNN / OpenCV-CUDA
sudo bash scripts/verify_opengl_cuda.sh
# expected: 14/14 PASS, "renderer: NVIDIA Tegra Orin (nvgpu)"

# Mission graph resolution (no hardware needed)
sudo /usr/local/bin/launch_av_mission.sh --dry-run
# expected: spawn lines for camera/detect/slam/nvblox/nav2/mavros, "dry-run complete"
```

## 2. ZED X camera samples ([examples/](../examples/))

```bash
cd ~/Documents/jetson-rt-stack

# Open + identify + one frame (~5 s)
sg zed -c '/opt/av-env/bin/python examples/zedx_grab.py'
# expected: open: SUCCESS · model: ZED X · FRAME CAPTURED: 1920 x 1200

# CUDA depth map (~10 s)
sg zed -c '/opt/av-env/bin/python examples/zedx_depth.py'
# expected: DEPTH MAP OK: 1920 x 1200 | center px: <distance in mm>

# Live stereo window, left | right, 60 s
DISPLAY=:0 sg zed -c '/opt/av-env/bin/python examples/zedx_stereo_view.py'
# expected: ~29.5 FPS at HD1200@30; snapshot saved to ~/Desktop
```

If `open:` fails with `CAMERA MOTION SENSORS NOT DETECTED`, run
`sudo bash scripts/install_zedx_daemons.sh` and see
[Troubleshooting]({{ '/TROUBLESHOOTING' | relative_url }}) H-6. If frames
look soft, see H-5 (the `libnvisppg.so` ISP fix).

## 3. Metis inference samples

```bash
cd ~/voyager-sdk    # the Voyager SDK checkout (app framework lives here)

# Sample video → NPU, displayed (first run compiles the model, ~17 min, cached)
/opt/av-env/bin/axdownloadmedia h264/traffic1_1080p.mp4 --output media   # once
GST_PLUGIN_FEATURE_RANK=nvv4l2decoder:NONE PYTHONPATH=$PWD DISPLAY=:0 \
  /opt/av-env/bin/python inference.py yolov5s-v7-coco media/h264/traffic1_1080p.mp4
# expected: live detection window; summary ~49 FPS end-to-end, <15% CPU

# LIVE ZED X → Metis (the full camera→NPU pipeline)
DISPLAY=:0 PYTHONPATH=$PWD sg zed -c \
  "/opt/av-env/bin/python ~/Documents/jetson-rt-stack/scripts/demo_zedx_metis.py"
# expected: live detections on the camera feed; FPS depends on camera mode:
```

Measured end-to-end baselines for `demo_zedx_metis.py` (edit
`camera_resolution` / `camera_fps` in the script):

| Camera mode | End-to-end FPS | Limiter |
|---|---|---|
| HD1200@30 | 29.6 | camera frame rate |
| HD1200@60 (default) | 37.3 | python copy chain (pyzed→numpy→BGR) |
| SVGA@120 | **53.3** | NPU pipeline |

The HD1200@60 gap to the NPU's ~49 FPS video rate is the CPU copies in the
frame generator; true NVMM/dmabuf zero-copy into the Axelera GStreamer
elements does not negotiate on this Voyager build (the reason for the
`nvv4l2decoder:NONE` workaround) and remains a design goal, see
[DMABUF zero-copy]({{ '/DMABUF_ZEROCOPY' | relative_url }}).

### C++ sample ([examples/zedx_metis_cpp/](../examples/zedx_metis_cpp/))

Same pipeline without the Voyager app framework: ZED SDK grab, host letterbox
+ int8 quantize, batch-4 model on the Metis via `libaxruntime`, host decode
+ NMS. Supports yolov5s (anchor decode) and yolov8s (anchor-free DFL decode),
auto-detected from the artifact. The detector costs zero GPU: measured ~25%
GR3D during a live run, all of it ZED rectification + compositor. Requires
the model deployed once (`inference.py` above, or `./deploy.py yolov8s-coco
--aipu-cores 4`; for yolov8 run deploy with `PIP_NO_DEPS=1
PIP_TARGET=~/.local/avextras PYTHONPATH=~/.local/avextras` so its ultralytics
dependency installs user-local instead of writing to root-owned /opt/av-env:
unsandboxed pip would also pull opencv-python+numpy2, the P-6 trap).

```bash
cd ~/Documents/jetson-rt-stack/examples/zedx_metis_cpp
cmake -B build && cmake --build build       # ~30 s

# decode smoke test, no camera/display needed
./build/zedx_metis_infer --image ~/voyager-sdk/media/h264/traffic1_1080p.mp4
# expected: ~11 dets (car/truck/person), "4 frames in 0.04s"
# add --model yolov8s-coco for the v8 path (same scene, scores ≤0.65: the
# compiled artifact's conf quantization compresses sigmoid scores)

# live, with display
DISPLAY=:0 sg zed -c './build/zedx_metis_infer --model yolov8s-coco'
# expected: detection window, ~47 FPS yolov8s / ~35 FPS yolov5s (HD1200@60)

# throughput, headless
sg zed -c './build/zedx_metis_infer --model yolov8s-coco --headless --seconds 15'
```

Three model artifacts are deployed: `yolov5s-v7-coco` and `yolov8s-coco` run
batch-4 (one frame per AIPU core); `yolov8l-coco` is large enough that the
compiler fits only one copy, so it runs single-core batch-1 (`--aipu-cores`
replicates the whole model per core for throughput; it does not split one
model's layers across cores, see [the aipu-cores explanation]({{ '/ZEDX_METIS_CPP' | relative_url }}#how---aipu-cores-actually-works-and-why-yolov8l-is-single-core)).
The samples auto-resolve the `4/`, `2/`, or `1/` core build dir, so
`--model yolov8l-coco` just works.

Measured end-to-end baselines (2026-06-11, headless; the reproducible
harness dataset is in [Benchmarks]({{ '/BENCHMARKS' | relative_url }})):

| Camera mode | yolov5s | yolov8s | yolov8l (1-core) | Python (v5) | Limiter |
|---|---|---|---|---|---|
| HD1200@30 | 30.0 | - | - | 29.6 | camera rate |
| HD1200@60 (default) | **56.4** | **57.4** | 37.9 | 37.3 | capture chain / NPU (8l) |
| SVGA@120 | **74.7** | **95.7** | - | 53.3 | NPU pipeline |

yolov8l is the most accurate (~52.9 COCO mAP) but single-core, so the NPU is
the limiter; at HD1200@60 it still saturates the ~38 FPS it can sustain.

### Fusion sample (`zedx_metis_fusion`, same build)

> Full architecture, accelerator map, the twelve enhancements, `--aipu-cores`
> semantics, and the complete tuning/flag reference are in
> [ZED X + Metis C++]({{ '/ZEDX_METIS_CPP' | relative_url }}).

Every accelerator at once, in a **3-stage pipeline** (capture ∥ inference ∥
render) so the stages overlap. Default model is `yolov8l-coco` (the largest
deployed). Decode is the shared `yolo_decode.hpp` (one source for both
samples).

- **Metis NPU**: yolov5/v8 detection.
- **Jetson GPU**: ZED rectification + NEURAL_LIGHT depth; a **CUDA kernel**
  (`preprocess.cu`) does the letterbox + int8 quantize straight from the ZED
  GPU image into a **dma-heap buffer the Metis DMAs from** (no CPU quantize
  loop, no staging copy); the display frame is GPU-downscaled before download;
  all GPU work rides the **ZED CUDA stream**.
- **ZED AI**: skeleton/body tracking (`HUMAN_BODY_FAST`, BODY_18, FP16).
- **IMU**: fused world pose + a bottom-left linear-accel 3-vector gizmo.

CPU fusion per detection: `DEPTH` F32_C1 patch → distance; deproject + pose →
**world-frame XYZ**; an **IoU tracker** gives stable ids + velocity +
time-to-collision; ZED bodies are matched to "person" boxes so the head
keep-out uses real **head keypoints** and the 3D head position comes from
`keypoint[NOSE]` in meters. Zero per-frame allocation (fixed slot ring,
pinned + dma-heap buffers). Optional `--record out.mp4` (NVENC via GStreamer,
software fallback) and `--publish HOST:PORT` (UDP JSON of detections).

```bash
DISPLAY=:0 sg zed -c './build/zedx_metis_fusion'        # default = yolov8l
# expected: per-class colored boxes with id + distance + TTC, per-person
# skeletons + head keep-out, IMU gizmo + pose HUD.
# flags: --model --mode --fps --conf --iou --depth-max --head-frac --kp-conf
#        --depth-every N --no-bodies --record out.mp4 --record-fps N --publish H:P --model-root --labels
```

**Performance / `--depth-every` (keeping all features and going fast).** The
heavy iGPU work is NEURAL_LIGHT depth (computed inside `grab()`) + the body
net (`retrieveBodies`); both gate the frame. `--depth-every N` runs them only
every Nth grab while detection (Metis NPU), display, and pose run every frame:
the IoU tracker carries distance/velocity/TTC forward between depth updates,
so nothing is lost, depth/skeleton just refresh at ~rate/N. Measured HD1200@60,
all features on, live display session (2026-06-11); the headless bench
harness measures this sweep at 35 → 53 fps, see
[Benchmarks]({{ '/BENCHMARKS' | relative_url }}):

| Config | FPS | Bottleneck |
|---|---|---|
| yolov8l, any `--depth-every` | ~39 | Metis single-core inference (depth no longer gates) |
| yolov8s, `--depth-every 1` | 45 | depth every frame |
| yolov8s, `--depth-every 3` (recommended) | **57** | camera (60) |
| yolov8s @ SVGA, display, all features | **~50, stable** | (was 25→17 laggy before) |

Takeaways: **yolov8l is capped ~40 fps by the single-core Metis** (the most
accurate option); for max smooth fps with all features use `--model
yolov8s-coco --depth-every 3`. At SVGA prefer `--fps 60` over 120: the
pipeline can't consume 120, and the excess just builds latency. (A further
~2× depth headroom is possible by moving stereo onto the idle OFA/PVA via VPI;
documented as a Phase-2 option in the source. It trades NEURAL_LIGHT quality
for classical SGM, so it's not the default.)

### Monitoring the Metis (`axmonitor`)

jtop only sees Tegra hardware: the NPU shows up nowhere in it. The
jtop-equivalent for the Metis is Axelera's **`axmonitor`** (1 s refresh, GUI
or curses console): per-core AIPU utilization, core/board temperatures with
throttle-threshold markers, kernels-per-second (≈ FPS for vision pipelines),
device DDR usage + bandwidth, PCIe DMA bandwidth per channel, and which host
processes hold the device. Power telemetry is **only on the 4-Metis PCIe
card**. Our M.2 module has none, so keep using jtop's INA3221 rails for
board-level draw.

**Gotcha**: the pip-installed runtime in `/opt/av-env` does **not** ship
`axmonitor` or its backend `axsystemserver`, see
[Troubleshooting]({{ '/TROUBLESHOOTING' | relative_url }}) H-11. They come
from Axelera's apt repo, which publishes arm64 packages matching our 1.6.1
runtime:

```bash
sudo sh -c "curl -fsSL https://software.axelera.ai/artifactory/api/security/keypair/axelera/public | gpg --dearmor -o /etc/apt/keyrings/axelera.gpg"
sudo sh -c "echo 'deb [signed-by=/etc/apt/keyrings/axelera.gpg] https://software.axelera.ai/artifactory/axelera-apt-source ubuntu22 main' > /etc/apt/sources.list.d/axelera.list"
sudo apt-get update
sudo apt-get install -y axelera-voyager-sdk-base-1.6.1 libqt6svg6
# libqt6svg6 is an undeclared dep of axmonitor (H-11); the metapackage also
# pulls a ~256 MB RISC-V toolchain dep.

sudo systemctl start axsystemserver.service    # metrics backend, TCP *:5555
# "systemctl enable" aborts on the package's broken SysV script (H-11);
# for start-at-boot, create the wants symlink directly:
sudo ln -sf /lib/systemd/system/axsystemserver.service \
    /etc/systemd/system/multi-user.target.wants/axsystemserver.service

AXBIN=/opt/axelera/runtime-1.6.1-1/bin
$AXBIN/axmonitor --ui console            # over SSH; type 'print' at the prompt
$AXBIN/axmonitor --ui console -c print   # one-shot dump, scriptable
$AXBIN/axmonitor                         # GUI on the desktop
# expected: per-AI-core utilization/temperature/clock, kernel counts, DDR
# MB + GB/s, PCIe DMA MB/s per channel, refreshed every 1 s.
```

Verified live 2026-06-11: all metrics flow on this unit (device firmware
1.3.2 with SDK 1.6.1 is fine). Use the full `$AXBIN` path rather than
sourcing `/opt/axelera/sdk/1.6.1/axelera_activate.sh` for this: the activate
script also exports `GST_PLUGIN_PATH`/`PYTHONPATH`/`LD_LIBRARY_PATH`, which
can interfere with the `/opt/av-env` pipeline workarounds above. No-install
snapshots: `axdevice` (clocks + per-core MVM limits) and
`axdevice report console` (full device report).

## 4. Full mission graph (camera → detect → SLAM → Nav2)

Prerequisites: Phase 5 including steps 3b/3c (`install_zed_ros2_wrapper.sh`,
`install_mission_inference.sh`), see RUNBOOK R18 stage 3b.

```bash
# Standalone wrapper + detect pair (verified 2026-06-11):
sudo bash -c '. /etc/profile.d/jetson-av-stack.sh
  ros2 launch zed_wrapper zed_camera.launch.py camera_model:=zedx \
      ros_params_override_path:=/etc/jetson-av/zedx_overrides.yaml &
  sleep 12; /opt/av-env/bin/python /opt/jetson-av/detect_metis.py'
ros2 topic hz /detections                       # ≈ published camera rate
ros2 topic echo /detections --qos-reliability best_effort --once

# The full graph under systemd:
sudo systemctl start jetson-av-mission.service
systemctl list-units 'jetson-av-*'              # camera/detect/slam/nav2 running
ros2 topic list | grep -E 'visual_slam|detections|zed'
sudo systemctl stop jetson-av-mission.service jetson-av.slice
```

Live results (2026-06-11, first full-graph run): camera, detect, cuVSLAM
("cuVSLAM tracker was successfully initialized", GPU), and Nav2 all active;
`/visual_slam/tracking/odometry|vo_pose|slam_path` and `/detections` present.
Standalone detect ran at **8-11 Hz** with the `pub_downscale_factor: 2.0`
override (full-res BGRA over DDS bottlenecks at ~6 Hz, see TROUBLESHOOTING
H-8 for the topic wiring and AV_STACK.md for tuning paths; composing detect
into the wrapper container for NITROS zero-copy IPC is the headroom play).
Expected idle loops without hardware: `jetson-av-mavros` (no FCU until the
Pixhawk arrives) and `jetson-av-nvblox` (`nvblox_examples_bringup` zed
example needs additional Isaac example deps, open item).

## 5. Phase 7 / resilience checks

```bash
systemctl status jetson-blackbox jetson-brownout-guard jetson-av-pcie-aer-monitor
# expected: all three active. The brownout guard logs "Power cap disabled"
# when AXELERA_POWER_LIMIT_W=0 (full power) is set in /etc/jetson-av/power.conf.

df -h /var/log/jetson-av/data       # btrfs data partition (or 200G loop file)
systemctl list-timers | grep btrfs  # weekly scrub timer

# MAVLink watchdog stays disabled until a flight controller is attached:
#   sudo systemctl enable --now jetson-mavlink-watchdog.service
```
