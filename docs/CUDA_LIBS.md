---
title: CUDA Libraries
layout: default
description: "OpenCV-CUDA build from source, OpenGL/EGL/GLES, TensorRT, and VPI setup against L4T CUDA 12.6 on Jetson Orin NX 16GB."
nav_order: 26
---

# CUDA Userspace: OpenCV, OpenGL, EGL, TensorRT, VPI

Stock JetPack ships these libraries without their CUDA and NVIDIA backends
enabled. This document covers the gap, the fix, and the verification for the
Jetson Orin NX 16GB on L4T R36.4.3 / JetPack 6.2; it is aimed at whoever
maintains the image's GPU userspace. The stack is verified on the reference
device (14/14 `verify_opengl_cuda.sh` checks).

Related: [AV_STACK.md](AV_STACK.md) (Phase 5 contents),
[SAMPLES.md](SAMPLES.md) (run commands), [ZEDX_METIS_CPP.md](ZEDX_METIS_CPP.md)
(C++ samples that exercise this stack live: CUDA preprocessing plus NVENC
recording via `--record`), [BENCHMARKS.md](BENCHMARKS.md) (measured rates),
[TROUBLESHOOTING.md](TROUBLESHOOTING.md) P-2 through P-6.

## The problem

| Library | Stock state | Symptom |
|---|---|---|
| `python3-opencv` (apt) | No CUDA, no cuDNN, no GStreamer | `cv2.cuda.getCudaEnabledDeviceCount() == 0`; DNN runs on CPU |
| `libGL.so` / `libEGL.so` | Mesa software path | OpenGL renderer is `llvmpipe`, no GPU offload |
| TensorRT | Installed but unused | Models compile but never get exercised |
| VPI 3.x | Installed but unused | PVA and ISP backends never selected |
| cuDNN | Installed but version not pinned | OpenCV linked against the wrong cuDNN soname, import fails |

Without the fix, vision code that should run on the Ampere GPU falls back to the
A78AE CPU at 10 to 30 times the latency, which is unacceptable for real-time
perception.

## What this build provides

| Detail | Value |
|---|---|
| OpenCV version | **4.10.0** (pinned via `OPENCV_VERSION` env) |
| CUDA version | 12.6 (L4T R36.4.3 system CUDA; do not pip-install a different version) |
| cuDNN | libcudnn9, cuDNN 9.3 (L4T R36.4.3 / JetPack 6.2; verify: `dpkg -l \| grep libcudnn9-cuda-12`) |
| CUDA arch | `CUDA_ARCH_BIN=8.7` (sm_87, Orin NX / Nano Ampere GPU) |
| PTX | none (`CUDA_ARCH_PTX=""`): faster startup, target-locked binary |
| Build location | on-device; [build_opencv_cuda.sh](../scripts/build_opencv_cuda.sh) runs on the Jetson |
| Build time | ~45 to 60 min on Orin NX (on-device, `JOBS=$(nproc)`) |
| Cache | `.deb` written to `/opt/opencv-cache/`; units 2 to N install in seconds |

The CUDA arch flag `8.7` is verified for Orin NX / Nano (GA10B, Ampere): see
[VERIFICATION_REPORT.md](VERIFICATION_REPORT.md) section 1.6. Use `8.6` for AGX
Orin (GA10x) and `7.2` for Xavier NX (Volta).

## The fix: three scripts

### [build_opencv_cuda.sh](../scripts/build_opencv_cuda.sh)

Builds OpenCV from source with the correct CMake flags and installs to
`/usr/local`. The result is cached as a `.deb` at `/opt/opencv-cache/`, so
re-flashing N units does not rebuild OpenCV N times: units 2 to N install from
the cache.

CMake flags that matter:

```
-D WITH_CUDA=ON
-D WITH_CUDNN=ON
-D OPENCV_DNN_CUDA=ON
-D ENABLE_FAST_MATH=ON
-D CUDA_FAST_MATH=ON
-D WITH_CUBLAS=ON
-D CUDA_ARCH_BIN=8.7         # Orin = sm_87
-D CUDA_ARCH_PTX=""          # no PTX (faster startup, target-locked binary)
-D WITH_GSTREAMER=ON
-D WITH_NVCUVID=ON           # GPU video decode
-D WITH_FFMPEG=ON
-D WITH_OPENGL=ON
-D BUILD_opencv_python3=ON
-D PYTHON3_EXECUTABLE=/opt/av-env/bin/python    # installs into the AV venv
-D OPENCV_GENERATE_PKGCONFIG=ON
-D OPENCV_ENABLE_NONFREE=ON
```

Build time is ~45 to 60 min on Orin. The first flash takes the hit; subsequent
flashes pull the `.deb` and install in seconds.

Override knobs (env):

```bash
OPENCV_VERSION=4.10.0    # default
CUDA_ARCH_BIN=8.7        # 8.7 for Orin; 8.6 for AGX Orin; 7.2 for Xavier NX
JOBS=6                   # default $(nproc)
WORK_DIR=/var/tmp/opencv-build
CACHE_DIR=/opt/opencv-cache
```

### [verify_opengl_cuda.sh](../scripts/verify_opengl_cuda.sh)

A read-only verifier that confirms the CUDA, OpenGL, GLES, TensorRT, VPI, cuDNN,
and OpenCV stack is wired up correctly. It runs at first boot and as part of
`make verify`.

Status note (updated 2026-06-10): the OpenCV and Python checks depend on
`/opt/av-env`, which `jetson-first-boot` provisions only when the device has
internet. The reference device has since completed online provisioning, with
two gotchas worth knowing: (1) JetPack userspace (CUDA/cuDNN/TensorRT/VPI) is
**not** part of the flashed image and must be installed on-device with
`sudo apt install nvidia-jetpack` before anything CUDA works
([TROUBLESHOOTING P-3](TROUBLESHOOTING.md)); (2) the Voyager pip step used to
clobber the cu126 torch wheel with a CPU-only PyPI build
([TROUBLESHOOTING P-2](TROUBLESHOOTING.md)), fixed in `jetson_first_boot.sh`.

Checks (all pre/post-gated by the verify framework):

| Check | What it confirms |
|---|---|
| `libEGL_nvidia.so.0` and related libs | NVIDIA EGL/GLES libraries installed |
| `eglinfo` | EGL display reports NVIDIA, not Mesa |
| `glxinfo` renderer | OpenGL renderer is NVIDIA / Tegra / Ampere |
| `nvcc --version` | CUDA toolkit installed |
| `nvidia-smi` or Tegra devfreq | GPU detectable |
| CUDA probe binary | nvcc compiles it, it runs, and it reports `sm_87` |
| `trtexec` | TensorRT runtime present |
| `pkg-config vpi` | VPI installed |
| `libcudnn9` | cuDNN present |
| `cv2.cuda.getCudaEnabledDeviceCount() > 0` | OpenCV-CUDA active |
| `cv2.getBuildInformation()` contains `CUDA` | Build is genuine, not a stock package |

### [install_av_phase5.sh](../scripts/install_av_phase5.sh)

The Phase 5 orchestrator, installed and verified live on the reference device
(2026-06-11; see [AV_STACK.md](AV_STACK.md)). It runs each step with a
pre-check and post-check:

1. [build_opencv_cuda.sh](../scripts/build_opencv_cuda.sh) (or pulls from cache)
2. [verify_opengl_cuda.sh](../scripts/verify_opengl_cuda.sh)
3. [install_av_stack.sh](../scripts/install_av_stack.sh) (ROS 2 Humble, Isaac
   ROS, cuVSLAM, nvblox, Nav2)
4. Installs `jetson-av-mission.service`

See [AV_STACK.md](AV_STACK.md) for the contents of step 3.

## Verify on a flashed device

Steps 3 and 4 require `/opt/av-env`, which the first-boot service provisions
once the device has internet. Provisioning is complete on the reference
device; on a fresh unit whose first boot ran offline, run steps 3 and 4 after
provisioning completes.

```bash
# 1. Headers found?
ls /usr/local/include/opencv4/opencv2/core.hpp

# 2. Library installed and linked?
ldconfig -p | grep libopencv_core
pkg-config --modversion opencv4

# 3. Python import + CUDA?
/opt/av-env/bin/python -c "
import cv2
print('OpenCV version:', cv2.__version__)
print('CUDA devices  :', cv2.cuda.getCudaEnabledDeviceCount())
build = cv2.getBuildInformation()
for line in build.split('\n'):
    if 'CUDA' in line or 'cuDNN' in line or 'GStreamer' in line:
        print(line)
"

# 4. End-to-end DNN on GPU
/opt/av-env/bin/python <<'EOF'
import cv2, numpy as np
net = cv2.dnn.readNet("/path/to/yolo.onnx")
net.setPreferableBackend(cv2.dnn.DNN_BACKEND_CUDA)
net.setPreferableTarget(cv2.dnn.DNN_TARGET_CUDA_FP16)
img = np.zeros((640, 640, 3), dtype=np.uint8)
blob = cv2.dnn.blobFromImage(img, 1/255.0, (640, 640), swapRB=True, crop=False)
net.setInput(blob)
_ = net.forward()
print("OK: DNN_CUDA forward succeeded")
EOF

# 5. OpenGL / EGL
glxinfo | grep -E 'OpenGL renderer|OpenGL version'
eglinfo | grep -E 'EGL vendor|EGL version'
```

## Troubleshooting

### `cv2.cuda.getCudaEnabledDeviceCount() == 0` after `import cv2`

Either OpenCV was rebuilt without `-D WITH_CUDA=ON` or the device's CUDA runtime
is incompatible. Confirm the build configuration:

```bash
/opt/av-env/bin/python -c "import cv2; print(cv2.getBuildInformation())" \
  | grep -A2 'CUDA'
```

If it reports `CUDA: NO`, re-run
[build_opencv_cuda.sh](../scripts/build_opencv_cuda.sh).

### `ImportError: libcudnn.so.9: cannot open shared object file`

cuDNN is missing. Install the L4T-shipped version that matches CUDA 12.6:

```bash
sudo apt install libcudnn9-cuda-12
```

### `glxinfo` reports `llvmpipe` (Mesa) instead of NVIDIA

`nvidia-l4t-3d-core` is missing. Reinstall it:

```bash
sudo apt install --reinstall nvidia-l4t-3d-core
```

### `nvcc` not found

The CUDA toolkit is not on `PATH`. JetPack 6.2 installs it under
`/usr/local/cuda-12.6/`. Ensure `/etc/profile.d/cuda.sh` adds it to `PATH`, or
set it manually:

```bash
export PATH=/usr/local/cuda-12.6/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda-12.6/lib64:$LD_LIBRARY_PATH
```

### Build runs out of disk

The default `WORK_DIR=/var/tmp/opencv-build` consumes ~3 GB. Check `df -h /var`
before invoking, or point `WORK_DIR` at a volume with ~3 GB free:

```bash
WORK_DIR=/path/elsewhere bash scripts/build_opencv_cuda.sh
```

### Build runs out of RAM

OpenCV with the CUDA contrib modules needs ~6 GB at peak. Lower parallelism:

```bash
JOBS=2 bash scripts/build_opencv_cuda.sh
```

### GStreamer pipelines using `nvarguscamerasrc` fail to negotiate

ZED X uses `nvarguscamerasrc`, which produces NVMM buffers and needs the camera
overlay loaded. Verify:

```bash
v4l2-ctl --list-devices                  # ZED X must appear
gst-launch-1.0 nvarguscamerasrc num-buffers=1 ! fakesink
```

If the device list is empty, the DTBO did not apply. See
[DRIVERS.md](DRIVERS.md) section 1.3. The ZED X modules are built in-tree, the
overlay is staged by the repo, and end-to-end capture is verified live on the
reference device (29.5 FPS stereo + CUDA depth; [DRIVERS.md](DRIVERS.md)
section 1.5), so an empty device list points at the overlay or daemon setup
on your unit, not the driver stack.

## Future work and known gaps

- **OpenCL on Tegra**: not yet enabled. Some applications prefer OpenCL over
  CUDA for portability. Add `-D WITH_OPENCL=ON` and the Mali OpenCL libraries if
  you need it.
- **VPI sample suite**: VPI ships with samples that serve as smoke tests but
  require a manual run today. Add them to
  [verify_opengl_cuda.sh](../scripts/verify_opengl_cuda.sh) to automate.
- **DeepStream 7.x**: not installed by Phase 5. For multi-stream pipeline
  composition, install it manually: `sudo apt install deepstream-7.0`.
- **TensorRT model compilation**: models live in `/opt/jetson-av/models/`.
  Pre-compile them to `.engine` files at bake time for the fastest cold start.
  This is currently a manual step.
