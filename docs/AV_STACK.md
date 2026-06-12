---
title: AV Stack
layout: default
description: "The ROS 2 mission layer: ROS 2 Humble + Isaac ROS + Nav2 install, cuVSLAM visual SLAM, nvblox 3D occupancy, the Metis detect node, and the systemd mission graph on the Jetson Orin NX 16GB."
nav_order: 25
---

# AV Application Stack: ROS 2 + Isaac ROS + cuVSLAM + nvblox + Nav2

## Purpose

This page is the reference for the whole ROS 2 / mission layer (Layer 2): the Phase 5 install (ROS 2 Humble + Isaac ROS + Nav2 + MAVROS), the systemd mission graph and its config, the Metis detect node, DDS tuning, and per-subsystem health checks. The layer is optional: the baseline image (Phases 1 to 4) boots and runs without it. Install Phase 5 once you have the ZED X driver source and want the full vision and planning pipeline. Phase 5 is installed and verified live on the reference device (2026-06-11): OpenCV-CUDA, ROS 2 + Isaac ROS + Nav2 + MAVROS, the mission service, and Metis inference at 49.2 FPS (see § Voyager inference below).

The pipeline runs: camera, then object detection (Metis NPU) and depth (GPU) and visual SLAM (cuVSLAM), then occupancy (nvblox), then planning (Nav2). The `jetson-av-mission.service` unit orchestrates it. **First live run 2026-06-11**: camera (zed-ros2-wrapper v5.3.1 at /opt/zed_ros_ws), detect (`/opt/jetson-av/detect_metis.py` → `/detections`), cuVSLAM (initialized on GPU via `/opt/jetson-av/zedx_vslam.launch.py` remappings), and Nav2 all active under systemd; mavros idles until a flight controller is attached; the nvblox example launch is an open item.

The baseline this layer builds on is verified live on the reference device (2026-06-10): the PREEMPT_RT kernel is active (`/sys/kernel/realtime` reads `1`), the Metis NPU enumerates on PCIe at `0004:01:00.0` and binds to the `metis` driver, the NVMe root is mounted at `/`, and the board runs in MAXN_SUPER mode with 8 cores online. The ZED X capture path is verified live end-to-end (2026-06-11): pyzed opens the camera (HD1200@30) and captures 29.5 FPS stereo with CUDA depth maps. See [Drivers]({{ '/DRIVERS' | relative_url }}) §1.5 for the SPSC/daemon pieces this requires. CUDA userspace (nvidia-jetpack) is installed and verified (14/14 `verify_opengl_cuda.sh` checks).

## Components

| Layer | Component | Compute | Pinned to |
|---|---|---|---|
| Camera | ZED X via `zed_wrapper` | ISP + NVMM buffers | cores 2-3 |
| Object detection | Custom node calling `axelera.runtime` | Metis NPU | core 1 |
| Depth | ZED SDK stereo | GPU (CUDA) | cores 2-3 (shared with camera) |
| Visual SLAM | `isaac_ros_visual_slam` (cuVSLAM) | GPU + CPU | cores 4-5 |
| 3D mapping | `isaac_ros_nvblox` | GPU | core 6 (shared with Nav2; the wrapper needs two cores) |
| Planning | `nav2_bringup` (Hybrid A* + DWB) | CPU | core 6 |
| Black-box | `jetson-blackbox.service` | CPU + NVENC | core 0 |
| Brownout guard | `jetson-brownout-guard.service` | CPU (low) | core 0 |

CPU pinning is enforced in [launch_av_mission.sh](../scripts/launch_av_mission.sh): each node spawns under `systemd-run --unit=jetson-av-<label> --slice=jetson-av.slice --property="AllowedCPUs=<cores>"`. Cores 1 to 5 are the kernel's isolated set (see [KERNEL_OPTIMIZATIONS.md](KERNEL_OPTIMIZATIONS.md), section 1). Core 0 is the housekeeping core and carries the black-box and brownout-guard services.

## Installation

[install_av_phase5.sh](../scripts/install_av_phase5.sh) is the single entry point. The first-boot service runs it when staged at `/home/j/phase5/` and the device has a network. On devices flashed before 2026-06-11 the staged copies carry the lib-sourcing bug ([Troubleshooting]({{ '/TROUBLESHOOTING' | relative_url }}) P-1). Run it from a repo checkout instead:

```bash
cd ~/Documents/jetson-rt-stack && sudo bash scripts/install_av_phase5.sh
```

Each step runs a pre-check and a post-check:

1. Build and install OpenCV-CUDA: see [CUDA_LIBS.md](CUDA_LIBS.md). Cached for reuse across flashes.
2. Verify the CUDA/OpenGL stack: runs [verify_opengl_cuda.sh](../scripts/verify_opengl_cuda.sh). This step is warn-only, so a missing piece does not block downstream installs.
3. Install ROS 2 Humble, Isaac ROS, Nav2, and MAVROS: adds the `packages.ros.org` repository AND NVIDIA's Isaac apt repo (`isaac.download.nvidia.com/isaac-ros/release-3 jammy release-3.0`), then installs `ros-humble-ros-base` plus `isaac-ros-nitros`, `isaac-ros-image-pipeline`, `isaac-ros-visual-slam`, `isaac-ros-nvblox`, `isaac-ros-detectnet` (`isaac-ros-object-detection` does not exist in 3.x), `navigation2`, and `nav2_bringup`. Note: Isaac ROS 4.x requires ROS 2 Jazzy on Ubuntu 24.04; Humble pairs with the Isaac ROS 3.x line. **Apt coverage confirmed sufficient on 2026-06-11** (FIELD_CONFIRM 3.4), no source build needed.
4. Install `jetson-av-mission.service`: copies `launch_av_mission.sh` to `/usr/local/bin/`, writes `/etc/jetson-av/mission.conf` (if absent), and registers the systemd unit. The service is enabled but not started: the operator reviews the config first.

After install, `/etc/profile.d/jetson-av-stack.sh` sources `/opt/ros/humble/setup.bash`, the Isaac ROS workspace (if source-built), and the AV Python virtual environment at `/opt/av-env` in every new shell. Note: `/opt/av-env` is provisioned by the first-boot service only when the device has internet. An offline first boot defers it; the service re-runs each boot and completes provisioning once a network is available. Until then, `make verify`'s venv-import step fails.

## Mission config

`/etc/jetson-av/mission.conf` toggles each subsystem (`1` enables, `0` disables):

```sh
ENABLE_CAMERA=1
ENABLE_INFERENCE=1
ENABLE_SLAM=1
ENABLE_NVBLOX=1
ENABLE_NAV2=1
ENABLE_MAVROS=1
FCU_URL=/dev/ttyTHS1:921600
```

`ENABLE_MAVROS` and `FCU_URL` belong to the UAV layer (Phase 7); leave them set if you have no flight controller and the node will warn and skip.

Useful patterns:

- Bench testing: `ENABLE_NAV2=0` runs the vision and inference pipeline only, with no planning output.
- Camera-only smoke test: `ENABLE_INFERENCE=0 ENABLE_SLAM=0 ENABLE_NVBLOX=0` confirms whether the camera publishes at all.
- Headless rehearsal: `ENABLE_CAMERA=0` lets you replay a bag into the rest of the pipeline. Modify `launch_av_mission.sh` to spawn a `ros2 bag play` node in place of the camera.

## Running the mission

```bash
# Dry run: print what would launch, without launching it.
sudo /usr/local/bin/launch_av_mission.sh --dry-run

# Real launch:
sudo systemctl start jetson-av-mission.service

# Status:
systemctl status 'jetson-av-*'

# Logs:
journalctl -u jetson-av-mission.service -f

# Stop (the slice holds every spawned node unit):
sudo systemctl stop jetson-av.slice
sudo systemctl stop jetson-av-mission.service
```

`launch_av_mission.sh` writes a per-launch log to `/var/log/jetson-av/mission-<timestamp>.log`, so you can diff successive launches.

Copy-paste commands for the live full-graph run, with the verified 2026-06-11 results (camera, detect, cuVSLAM, and Nav2 active; standalone detect at 8-11 Hz), are in [Samples & Tests]({{ '/SAMPLES' | relative_url }}) §4.

## Voyager inference: verified procedure (2026-06-11)

Live-verified on the reference device: **YOLOv5s-v7-coco at 49.2 FPS
end-to-end** on a 1080p video (13.7% CPU: the Metis does the work) and up to
**53.3 FPS on the live ZED X feed** via
[`scripts/demo_zedx_metis.py`](../scripts/demo_zedx_metis.py): measured
29.6 FPS at HD1200@30 (camera-limited), 37.3 at HD1200@60 (python copy chain),
53.3 at SVGA@120. A pure C++ port
([`examples/zedx_metis_cpp/`](../examples/zedx_metis_cpp/)) that talks to
`libaxruntime` directly (no app framework, host-side decode+NMS) reaches
**56.4 FPS at HD1200@60 and 74.7 at SVGA@120** headless with yolov5s, and
**57.4 / 95.7 FPS** with yolov8s (`--model yolov8s-coco`, anchor-free DFL
decode), at ~25% GPU, all of it ZED rectification. Full commands +
baselines: [Samples & Tests]({{ '/SAMPLES' | relative_url }}); the C++
architecture, the sensor-fusion sample (depth + skeletons + IMU,
`--depth-every` cadence, NVENC `--record`), and the flag reference:
[ZED X + Metis C++]({{ '/ZEDX_METIS_CPP' | relative_url }}); the
reproducible measured dataset:
[Benchmarks]({{ '/BENCHMARKS' | relative_url }}). What it took, beyond the
Voyager pip wheels:

1. **App-framework deps**: `axelera.app` lives in the voyager-sdk checkout,
   not the wheels. Install `requirements.application.txt` into `/opt/av-env`
   **minus `opencv-python`** (it shadows the CUDA cv2 build,
   [TROUBLESHOOTING P-6](TROUBLESHOOTING.md)) **and `pyopencl`** (no OpenCL
   runtime on Jetson; harmless warning). System deps:
   `libgirepository1.0-dev libcairo2-dev gobject-introspection
   gir1.2-gstreamer-1.0 gir1.2-gst-plugins-base-1.0 gstreamer1.0-tools
   gstreamer1.0-plugins-good gstreamer1.0-plugins-bad`.
2. **GStreamer operators** are a source build: `make operators` in the
   voyager-sdk checkout with `AXELERA_RUNTIME_DIR` pointing at the venv's
   `site-packages/axelera`. Extra apt deps found by trial on L4T R36.4.3:
   `ninja-build opencl-headers ocl-icd-opencl-dev libsimde-dev`.
3. **Decode workaround**: file/RTSP sources fail with `not-negotiated`:
   NVIDIA's `nvv4l2decoder` outputs NVMM-memory caps the Axelera elements
   can't consume. Run with `GST_PLUGIN_FEATURE_RANK=nvv4l2decoder:NONE` to
   force software decode. (Camera-generator sources, like the ZED X demo,
   are unaffected.)
4. **First run compiles the model** (~17 min for yolov5s, cached under the
   voyager checkout). The app API (`create_inference_stream`) defaults to
   `aipu_cores=1`, which is a *different* artifact than `inference.py`'s
   4-core default. Pass `aipu_cores=4` or you trigger a full recompile.

```bash
cd ~/voyager-sdk
# sample video
GST_PLUGIN_FEATURE_RANK=nvv4l2decoder:NONE PYTHONPATH=$PWD DISPLAY=:0 \
  /opt/av-env/bin/python inference.py yolov5s-v7-coco media/h264/traffic1_1080p.mp4
# live ZED X → Metis
DISPLAY=:0 PYTHONPATH=$PWD sg zed -c \
  "/opt/av-env/bin/python ~/Documents/jetson-rt-stack/scripts/demo_zedx_metis.py"
```

## Inference pipeline (the byte path)

```
ZED X (2x 1920x1200@60) ──MIPI──> Tegra ISP
                          │   debayer, white balance (NVMM buffer)
                          ▼
                  /dev/dma_heap/linux,cma  ←── shared zero-copy buffer
                          │
              ┌───────────┴────────────┐
              ▼                        ▼
       ZED SDK stereo                custom python node
       (GPU CUDA)                    (axelera.runtime)
              │                        │
       depth + odom                  YOLO bbox + class
              │                        │
              ▼                        ▼
    isaac_ros_visual_slam         /detections topic
       (cores 4-5, GPU)                │
              │                        │
       /vslam/odometry,                │
       /vslam/pose                     │
              │                        │
              └────┬───────────────────┘
                   ▼
         isaac_ros_nvblox  (3D voxel occupancy)
                   │
                   ▼
                 nav2  (Hybrid A* + DWB local planner)
                   │
                   ▼
                /cmd_vel
```

DDS uses FastDDS by default (`RMW_IMPLEMENTATION=rmw_fastrtps_cpp`, set in `/etc/profile.d/jetson-av-stack.sh`). The QoS profiles are:

- High-rate camera topics: `best_effort + keep_last + depth=1`
- State topics (vslam pose): `reliable + keep_last + depth=5`
- Maps (nvblox occupancy): `reliable + transient_local`

NIC tuning happens in [jetson_rt_tune.sh](../scripts/jetson_rt_tune.sh) via `tc qdisc replace dev … root fq`. It matters when multiple Jetsons share one DDS domain.

## Models

Voyager deploy artifacts are **relocatable directories**, not single `.ax`
files. [`install_mission_inference.sh`](../scripts/install_mission_inference.sh)
deploys the network (or reuses the cache) and stages it:

```
/opt/jetson-av/models/
└── yolov5s-v7-coco/                  ← one directory per network
    ├── yolov5s-v7-coco.axnet        ← runtime descriptor
    └── yolov5s-v7-coco/
        ├── model_info.json
        ├── quantized/…              ← quantized weights + postprocess graph
        └── 4/                       ← per-core-count compiled variant
```

The detect node resolves it via
`create_inference_stream(network=$DETECT_NETWORK, build_root=$DETECT_BUILD_ROOT,
aipu_cores=4)` (env: `AXELERA_FRAMEWORK`, `AXELERA_BUILD_ROOT`). Compile new
networks once with `deploy.py <name> --aipu-cores 4` (anywhere: artifacts
copy across machines), then re-run `install_mission_inference.sh` and set
`DETECT_NETWORK=<name>` in `/etc/jetson-av/mission.conf`.

## Health checks per subsystem

Add to your monitoring stack or run manually:

```bash
# Camera publishing?
ros2 topic hz /zed/zed_node/rgb/color/rect/image   # wrapper >= 5.1 topic name

# Detector running?
ros2 topic hz /detections                    # should match camera Hz

# SLAM converged?
ros2 topic echo /visual_slam/tracking/vo_pose --once   # non-zero pose

# Map building?
ros2 topic hz /nvblox/static_occupancy

# Planner running?
ros2 service list | grep -i nav2

# Black-box recording?
ls /var/log/jetson-av/flights/$(ls -t /var/log/jetson-av/flights | head -1)/bag/
```

## Troubleshooting

### `ros2 launch` fails with "package not found"

The stack environment was not sourced. Open a fresh shell, or source it directly:

```bash
source /etc/profile.d/jetson-av-stack.sh
ros2 pkg list | grep <package>
```

### Mission service does not start

```bash
journalctl -u jetson-av-mission.service -n 50
sudo /usr/local/bin/launch_av_mission.sh --dry-run    # print what it would do
```

The most common cause is a referenced ROS package that is not installed. The launcher prints a `WARN: ... not installed` line for each missing component and skips it.

### High latency or drops in DDS

[jetson_first_boot.sh](../scripts/jetson_first_boot.sh) tunes the UDP buffers (`net.core.rmem_max` and `net.core.wmem_max` to `2147483647`, roughly 2 GB). Check the live values:

```bash
sudo sysctl net.core.rmem_max
sudo sysctl net.core.wmem_max
```

If they have reverted to defaults, re-run `sudo sysctl -p`.

### Inference latency too high

Verify Metis is the actual target (requires a provisioned `/opt/av-env`, see [Installation](#installation)):

```bash
/opt/av-env/bin/python -c "
import axelera.runtime as ax
dev = ax.Device.connect()
print('device:', dev.info)
print('queue:', dev.queue_depth)
"
```

If `axelera.runtime` falls back to CPU, the `metis` kernel module is not loaded or the udev rule is missing. See [DRIVERS.md](DRIVERS.md), section 3.5 (udev rules) and section 3.6 (verification on target).

### nvblox memory growth

Voxel maps grow without bound. Set a limit in your nvblox launch file (the `max_distance` parameter), or restart the service periodically during long flights.

## Future work

- **Pre-compile mission models at bake time**: currently a manual step.
- **Per-mission config presets**: `mission-bench.conf`, `mission-flight.conf`,
  symlink `/etc/jetson-av/mission.conf` to the active one.
- **DeepStream multi-stream**: for surveying with N cameras feeding one
  pipeline.
