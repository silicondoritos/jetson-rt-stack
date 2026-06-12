---
title: Drivers
layout: default
description: "Vendor driver integrations: ZED X in-tree, ZED SDK userspace, Axelera Metis in-tree, Voyager SDK pip wheels. Acquisition instructions for NDA-gated trees."
nav_order: 17
---

# Drivers

How the two vendor stacks are integrated into this build: ZED X (camera + ZED Link Mono GMSL2 deserializer + ZED SDK) and Axelera Metis M.2 PCIe (+ Voyager SDK). Read this when wiring either device into the image, or when a module refuses to load. Both paths are live-verified on the reference device (2026-06-11).

**On this page**: [Vendor tree acquisition](#vendor-tree-acquisition) | [1. ZED X camera + deserializer](#1-stereolabs-zed-x-camera--deserializer) | [2. ZED SDK](#2-zed-sdk-userspace) | [3. Axelera Metis](#3-axelera-metis-voyager-sdk) | [4. Compatibility matrix](#4-compatibility-matrix-must-agree-across-all-three) | [5. Troubleshooting](#5-troubleshooting)

See also: [Third-party dependencies]({{ '/THIRD_PARTY' | relative_url }}) · [Configuration]({{ '/CONFIGURATION' | relative_url }}) · [Kernel patches]({{ '/KERNEL_PATCHES' | relative_url }}) · [Vermagic]({{ '/VERMAGIC_STRATEGY' | relative_url }}) · [Verification report]({{ '/VERIFICATION_REPORT' | relative_url }})

---

## Vendor tree acquisition

None of the following are included in this repository. They are proprietary, NDA-gated, or require a vendor relationship. Place them adjacent to the repo at the paths shown; the build system reads them from there.

The canonical inventory of **every** third-party input (these four trees plus the NVIDIA tarballs, toolchain, pip indexes, apt repos, and model downloads) is [Third-party dependencies]({{ '/THIRD_PARTY' | relative_url }}). This section keeps the short version for the four kernel-adjacent trees; the rest of this page is integration detail.

| Tree | Path | What it is | How to get it |
|---|---|---|---|
| `axelera-driver/` | `$REPO_ROOT/axelera-driver/` | Axelera Metis PCIe kernel driver source | Axelera customer portal, account required (no NDA) |
| `voyager-sdk/` | `$REPO_ROOT/voyager-sdk/` | Axelera Voyager SDK + `axl-jetson.patch` | Same Axelera portal account, no NDA |
| `zedx-driver/` | `$REPO_ROOT/zedx-driver/` | Stereolabs ZED X + ZED Link kernel driver source | Stereolabs business / NDA relationship, contact [support.stereolabs.com](https://support.stereolabs.com) |
| `zed-sdk/` | `$REPO_ROOT/zed-sdk/` | ZED SDK installer (`.run`) | Public download, [stereolabs.com/developers/release](https://www.stereolabs.com/developers/release) |

All four directories are in `.gitignore`. The build proceeds without any that are absent: features are skipped per the active configuration:

```bash
make menuconfig   # set CAMERA_NONE to skip ZED X; disable AXELERA_METIS to skip Metis
make defconfig    # use committed defaults
make doctor       # confirms which trees are present, PASS/WARN/FAIL per feature
```

**Pre-compiled `.ko` modules will not load** on this build's custom PREEMPT_RT kernel due to vermagic mismatch. The vendor source must be compiled in-tree against this kernel's own toolchain, headers, and Module.symvers. That is what this build system does automatically when the vendor tree is placed at the correct path.

**ZED X build status (2026-06-11)**: the `stereolabs` modules build in-tree and the DT overlay is staged (the earlier `0006` compilation-Makefile patch failure is resolved; see [Troubleshooting]({{ '/TROUBLESHOOTING' | relative_url }}) B-5 for history). **End-to-end capture is verified live** on the reference device: stereo at 29.5 FPS + CUDA depth via pyzed; see §1.5 for the SPSC/daemon pieces this requires. Layer 1 (Metis, `CONFIG_CAMERA_NONE=y`) is verified on device and unaffected.

---

## 1. Stereolabs ZED X (camera + deserializer)

The ZED X is a 2x 1920x1200 (2.3 MP) global-shutter stereo camera at up to 60 fps.
The "4K@30 / ~6 Gb/s" figure sometimes quoted is the ZED Link Mono capture card's
throughput ceiling, not the camera's native output. The signal path is:

```
ZED X sensor (2x AR0234, 1920x1200 global shutter)
  └── GMSL2 over coax
       └── ZED Link Mono adapter (MAX9296A deserializer)
            └── MIPI CSI-2 ribbon
                 └── Jetson VI / ISP
```

### 1.1 Build path

Promoted to **in-tree** under `drivers/media/i2c/zedx/` by Phase 1
(`scripts/01_extract_and_patch.sh`). The vendor source under `source/stereolabs/`
remains canonical via a symlink (`zedx-src`); the in-tree shim's Kconfig +
Kbuild glue makes the kernel's own `make modules` build it with the same
toolchain as the kernel image.

| Component | Kconfig flag | Notes |
|---|---|---|
| Top-level driver | `CONFIG_VIDEO_ZEDX=m` | sl_zedx.ko |
| AR0234 sensor | `CONFIG_VIDEO_ZEDX_AR0234=m` | onsemi |
| IMX678 sensor | `CONFIG_VIDEO_ZEDX_IMX678=m` | Sony |
| MAX9296 deserializer | `CONFIG_SL_DESER_MAX9296=m` | **required** for ZED Link Mono |
| MAX96712 deserializer | `CONFIG_SL_DESER_MAX96712` (off) | wrong chip, silently corrupts frames |
| BMI088 IMU + SPSC | `CONFIG_SL_IMU_BMI088=m` | bmi088.ko + bmi_spsc.ko; **required** for SDK ≥5.x camera open (see §1.5) |

Vermagic match is guaranteed by construction. See
[`VERMAGIC_STRATEGY.md`](VERMAGIC_STRATEGY.md) for why this matters.

### 1.2 The MAX9296 vs MAX96712 silent-corruption trap

**ZED Link Mono uses the MAX9296.** Selecting MAX96712 (a different chip)
compiles cleanly, the module loads cleanly, frames flow at 30 fps with no
errors in dmesg, but the frame contents are subtly wrong. Stereo depth
produces garbage. SLAM drifts. Inference behaves erratically.

We enforce the correct choice in two places:

1. **Defconfig**: `CONFIG_SL_DESER_MAX9296=m`,
   `# CONFIG_SL_DESER_MAX96712 is not set`.
2. **Compiler flag in `source/stereolabs/drivers/Makefile`**:
   `-DCONFIG_SL_DESER_MAX96712 → -DCONFIG_SL_DESER_MAX9296` via `sed`
   in Phase 1.

Both must be in place; the Makefile flag overrides the Kconfig if they
disagree.

### 1.3 Device-tree overlay

`tegra234-p3768-camera-zedlink-mono-sl-overlay.dtbo` is compiled in Phase 2
by an explicit `cpp -DBUILDOVERLAY ... | dtc -@ -f` sequence: NVIDIA's
`kernel-devicetree` system silently skips `dtbo-y` targets, so the standard
kernel build won't produce it. See [`KERNEL_PATCHES.md`](KERNEL_PATCHES.md) §8.

The overlay is registered in `extlinux.conf` by Phase 3:

```
APPEND ${cbootargs} ...
OVERLAYS /boot/tegra234-p3768-camera-zedlink-mono-sl-overlay.dtbo
```

### 1.4 ISP calibrations

`zedx-driver/ISP/*.isp` files are baked into `/var/nvidia/nvcam/settings/`
by Phase 3. NVIDIA's `nvcam` daemon loads them at boot to tune the ISP
pipeline (exposure, white-balance, lens shading) for the specific sensor
in use (AR0234 or IMX678).

Symptoms of missing/wrong `.isp`: frames are usable but visually off
(washed-out, wrong color balance, dark corners). Check `dmesg | grep nvcam`
and `ls /var/nvidia/nvcam/settings/`.

**Separate from the `.isp` tuning files**: stock L4T R36.4.x ships a
`libnvisppg.so` (ISP post-processing library) that renders the ZED X **soft /
not crisp** even with correct tuning files. Stereolabs ships a patched build
at `zedx-driver/nvidia_364_fix/<L4T version>/libnvisppg.so` (the same fix
their support distributes inside the zedbox `.deb`). Verified live
2026-06-11: image is sharp after the swap.
[`install_zedx_daemons.sh`](../scripts/install_zedx_daemons.sh) installs it
with `dpkg-divert` (stock kept at `libnvisppg.so.stock`, survives
`nvidia-l4t-camera` apt upgrades) into
`/usr/lib/aarch64-linux-gnu/nvidia/` (`tegra/` is a symlink to it), then
restarts `nvargus-daemon`. See [TROUBLESHOOTING H-5](TROUBLESHOOTING.md).

### 1.5 Verification on target

Status (updated 2026-06-10, late): **end-to-end capture VERIFIED LIVE** on
the reference device: `pyzed` opens the ZED X (HD1200@30,
FW 2001), grabs 1920x1200 frames, and computes CUDA depth maps on the custom
PREEMPT_RT kernel. Getting there required three pieces that ship in the
**zedx-driver vendor tree, not the SDK installer**, now automated by
[`scripts/install_zedx_daemons.sh`](../scripts/install_zedx_daemons.sh):

1. **BMI088 IMU + SPSC modules** (`bmi088.ko`, `bmi_spsc.ko`) built against
   the vermagic-aligned headers. Without them the SDK fails with
   "No camera-to-SPSC mappings found / CAMERA MOTION SENSORS NOT DETECTED".
2. **Vendor daemons** `ZEDX_Driver` (module loader), `ZEDX_Daemon`, and
   `IMU_Daemon` (privileged SPSC broker), built from `Daemon/` with cmake +
   Qt5 and run as systemd services.
3. **Path trap**: ZEDX_Driver insmods from
   `/usr/lib/modules/$(uname -r)/kernel/drivers/stereolabs/`. Modules under
   `updates/` are silently skipped, so the IMU vanishes on every loader
   restart unless the .ko files are installed at the loader path.

A udev rule (`99-zed-spsc.rules`) grants the `zed` group access to
`/dev/spsc_bmi*`. **Image-build integration (implemented 2026-06-11)**: the
zedx plugin now (a) enables `CONFIG_SL_IMU_BMI088=m` so bmi088/bmi_spsc build
in-tree with the kernel, (b) mirrors every stereolabs `.ko` to the
ZEDX_Driver loader path at bake, (c) stages the daemon sources + ISP fix +
udev rule + `install_zedx_daemons.sh` at `/opt/zedx-daemons/`, and (d) first
boot runs the installer automatically. Drop prebuilt daemon binaries in
`$REPO_ROOT/zedx-daemon-cache/` (gitignored) to skip the on-device cmake/Qt
build entirely, same pattern as `/opt/opencv-cache`. Live results after the
full fix: stereo SIDE_BY_SIDE at **29.5 FPS sustained** (HD1200@30), CUDA
depth maps working. Higher camera modes and the camera-to-NPU pipelines
built on this path are measured in [SAMPLES.md](SAMPLES.md) and
[BENCHMARKS.md](BENCHMARKS.md). Verify with:

```bash
# Kernel module loaded with vermagic match (only if you have driver source)
lsmod | grep sl_zedx
modinfo sl_zedx | grep vermagic   # must contain $(uname -r)

# v4l2 enumeration
v4l2-ctl --list-devices

# Camera registered
ls /dev/video*

# Live capture (5 s)
sudo gst-launch-1.0 -v nvarguscamerasrc num-buffers=150 ! \
    'video/x-raw(memory:NVMM),width=1920,height=1080,framerate=30/1' ! \
    fakesink

# ISP calibrations present
ls /var/nvidia/nvcam/settings/*.isp
```

---

## 2. ZED SDK (userspace)

> **ROS 2 wrapper**: the mission camera node comes from the Stereolabs
> [zed-ros2-wrapper](https://github.com/stereolabs/zed-ros2-wrapper)
> (tag **v5.3.1** pairs with SDK 5.3.1 on Humble), colcon-built at
> `/opt/zed_ros_ws` by
> [`install_zed_ros2_wrapper.sh`](../scripts/install_zed_ros2_wrapper.sh)
> (Phase 5 step 3b). Mind the >=5.1 topic rename:
> [Troubleshooting]({{ '/TROUBLESHOOTING' | relative_url }}) H-8.


The ZED SDK is userspace, but its installer also ships a DKMS-built kernel
module (`sl_zedx.ko`). On a custom RT kernel that module is a vermagic landmine
unless we intervene.

### 2.1 Layout on the rootfs

```
/opt/zed-sdk/
├── ZED_SDK_Tegra_*.run       ← Stereolabs installer (place here pre-bake)
└── install_zed_sdk.sh        ← Our wrapper, runs at first-boot
/opt/kernel-headers/
└── linux-headers-5.15.x-tegra_*.deb   ← vermagic-aligned headers
```

### 2.2 How the install works

`scripts/install_zed_sdk.sh` (run by `jetson_first_boot.sh`) does this in
order:

1. **Verify our `sl_zedx.ko` is present and vermagic-aligned.** If
   `CONFIG_VIDEO_ZEDX=m` was honored by `make modules`, the module lives
   at `/lib/modules/$(uname -r)/kernel/drivers/media/i2c/zedx/...`. If
   not, abort: we'd otherwise let the SDK silently install a stale copy.
2. **CUDA version check.** ZED SDK 5.3 requires CUDA 12.6, which is
   what L4T R36.4.3 ships. A CUDA mismatch segfaults on the first `pyzed` import.
3. **Run the `.run` installer in `silent runtime_only skip_python
   skip_cuda skip_tools skip_od_module skip_hub nvpmodel=0`** mode (verified flags, `skip_drivers` does not exist; see [Verification Report]({{ '/VERIFICATION_REPORT' | relative_url }}) §2.3). Userspace libs only; DKMS path skipped.
4. **Install `pyzed`** into `/opt/av-env` (our venv) by running
   `/usr/local/zed/get_python_api.py` with the venv's Python interpreter.
5. **Smoke test** with `python -c "import pyzed.sl"`.

Provisioning status (2026-06-11): `/opt/av-env` is provisioned on the
reference device and these steps have run end to end: pyzed installs into the
venv and opens the ZED X live (29.5 FPS stereo + CUDA depth). On a fresh unit,
`jetson_first_boot.sh` provisions `/opt/av-env` once the device has internet;
the service re-runs each boot until provisioning completes.

If a future SDK version adds a DKMS rebuild path, our shipped
`linux-headers-*.deb` at `/opt/kernel-headers/` provides headers under
`/usr/src/linux-headers-$(uname -r)/`, so DKMS can build a vermagic-correct
module. The result shadows ours under `/lib/modules/extra/`: harmless but
redundant.

### 2.3 Pre-flight checklist before bake

1. Download `ZED_SDK_Tegra_*.run` for the matching JetPack version
   (5.3 for JetPack 6.2). Place in `<repo>/zed-sdk/`.
2. Confirm `make build` produced a `linux-headers-*.deb` under
   `latest_jetson/Linux_for_Tegra/staging/kernel-headers/`.
3. Run `make bake` and confirm:
   ```
   [*] Baking linux-headers .deb (vermagic-aligned)...
      -> linux-headers-...deb baked into /opt/kernel-headers/
   [*] Baking ZED SDK installer + wrapper...
      -> ZED_SDK_Tegra_..._5.3.run staged at /opt/zed-sdk/
   ```

### 2.4 Post-flash verification

```bash
# Headers installed
ls /usr/src/linux-headers-$(uname -r)/Makefile

# ZED SDK userspace in place
test -f /usr/local/zed/include/sl/Camera.hpp && echo OK

# pyzed importable from venv
# (passes on the reference device; on a fresh unit it fails until first-boot provisioning completes online, see 2.2)
/opt/av-env/bin/python -c "import pyzed.sl as sl; print(sl.__file__)"
```

### 2.5 SDK samples (not shipped by the installer)

Since SDK 4.x the `.run` installer no longer bundles samples. They live in
[stereolabs/zed-sdk](https://github.com/stereolabs/zed-sdk) (and our
`runtime_only` install skips extras anyway). On the verified device the repo
is cloned at `~/zed-sdk` (tag `5.3.0`, matches SDK 5.3.1) and all 40 samples
plus 12 tutorials build from the top-level `CMakeLists.txt` (2026-06-11).

One dependency gap: the GL viewers need `GL/freeglut.h` from `freeglut3-dev`,
which the image lacks (only the `freeglut3` runtime is installed). Either
`apt install freeglut3-dev`, or without root: `apt-get download freeglut3-dev`,
`dpkg -x` it somewhere local, fix the dangling `libglut.so` symlink to point
at the system `libglut.so.3.9.0`, and pass `GLUT_INCLUDE_DIR`/`GLUT_glut_LIBRARY`
to CMake. Built binaries deploy to `~/zed-sdk/bin/` via `make install`.

**AI model engines**: the `runtime_only` install also skips the ZED AI models;
the SDK downloads + TensorRT-optimizes each on first use (~8-15 min/model on
the Orin NX). All 15 models (3 depth, 6 body, 4 detection, person-head, re-ID)
were pre-built on the reference device 2026-06-11 into
`/usr/local/zed/resources/` (~/zed group-writable, survives reinstalls).
`~/zed-sdk/bin/zed_ai_models [--optimize]` (built from `zed_ai_models.cpp`
alongside it) lists or rebuilds them, a stand-in for the not-installed
ZED Diagnostic tool. One quirk seen live: a model download can report
`FAILURE` yet leave a valid file; a second `--optimize` pass picks it up.

This repo's own ZED-to-Metis C++ samples are separate from the Stereolabs
samples; see [ZEDX_METIS_CPP.md](ZEDX_METIS_CPP.md) for their design and
[BENCHMARKS.md](BENCHMARKS.md) for measured throughput.

---

## 3. Axelera Metis (Voyager SDK)

The Voyager SDK ships two independent components: a kernel module
(`metis.ko`) and Python tooling (`axelera-rt`, `axelera-devkit`). This build
keeps them separate to neutralize the vermagic trap.

Verified on device (2026-06-10): Metis enumerates on PCIe at `0004:01:00.0`
(vendor:device `1f9d:1100`) and binds to the `metis` driver, with `metis.ko`
loaded.

### 3.1 Kernel-side: Metis is in-tree

Promoted to **in-tree** under `drivers/misc/axelera/` by Phase 1. The
vendor source remains canonical at `source/axelera/axelera-driver/`; the
in-tree directory is a thin Kconfig + Kbuild shim that symlinks back to
it. Defconfig flag: `CONFIG_AXELERA_METIS=m`.

Result: `metis.ko` is built by the kernel's own `make modules`, with the
exact same vermagic, GCC, and `Module.symvers` CRCs as the kernel image.
No DKMS, no surprise mismatches.

See [`KERNEL_PATCHES.md`](KERNEL_PATCHES.md) §6 and
[`VERMAGIC_STRATEGY.md`](VERMAGIC_STRATEGY.md).

### 3.2 The PCIe patience patch

The Axelera Metis is invisible to `lspci` on cold boot with NVIDIA's
default PCIe link-training timeout (10 retries). Phase 1 raises it:

```c
// drivers/pci/controller/dwc/pcie-designware.h
#define LINK_WAIT_MAX_RETRIES   200
```

The [axelera plugin](../plugins/axelera) applies `voyager-sdk/axl-jetson.patch`
(which raises the value from 10 to 50), then `sed`-forces `LINK_WAIT_MAX_RETRIES`
to 200 regardless of the patch's value. Without this patch, the Metis M.2
slot reports nothing.

See [`KERNEL_PATCHES.md`](KERNEL_PATCHES.md) §1.

### 3.3 Userspace: pip wheels, not install.sh --driver

Voyager SDK 1.6 changed the install method. The legacy `install.sh --driver
--runtime --common` is no longer required because:

1. The driver path is dead: the kernel already has `metis.ko` baked in.
2. The runtime + tooling are now distributed as pip wheels at
   `https://software.axelera.ai/artifactory/axelera-pypi/`.

`scripts/jetson_first_boot.sh` installs them into `/opt/av-env`:

```bash
pip install axelera-rt axelera-devkit \
    --extra-index-url https://software.axelera.ai/artifactory/api/pypi/axelera-pypi/simple
```

Hard requirement: `numpy<2.0.0` (Voyager rejects numpy 2.x).

This install step requires internet at first boot. On the reference device the
wheels are installed and verified live (2026-06-11): Voyager 1.6.1,
`axdevice --set-power-limit` confirmed, YOLOv5s-v7-coco at 49.2 FPS end-to-end
(see [AV stack]({{ '/AV_STACK' | relative_url }}) § Voyager inference). The
C++ samples drive the ZED X into the Metis through `libaxruntime` directly;
see [ZED X + Metis C++]({{ '/ZEDX_METIS_CPP' | relative_url }}) and
[Benchmarks]({{ '/BENCHMARKS' | relative_url }}) for measured live-camera
rates. On a fresh unit the first-boot service re-runs each boot and completes
provisioning once a network is available.

### 3.4 Environment glue

`AXELERA_GST_EXPLICIT_PARSE=1` was historically appended to
`/opt/av-env/bin/activate`, but FIELD_CONFIRM 3.3 (2026-06-11) found **zero
references** to it in the Voyager 1.6.1 source or wheels. It is stale and
the export was removed from `jetson_first_boot.sh`. The decode workaround
Jetson actually needs is `GST_PLUGIN_FEATURE_RANK=nvv4l2decoder:NONE`
(file/RTSP sources only; see [AV stack]({{ '/AV_STACK' | relative_url }})
§ Voyager inference).

### 3.5 udev rules

`72-axelera.rules` is staged into the rootfs by Phase 1
(`scripts/01_extract_and_patch.sh`). It names the Metis PCIe device node
predictably so the runtime can find it without scanning all of `/dev/pci*`.

### 3.6 Verification on target

```bash
# Kernel module: in-tree, vermagic-aligned
lsmod | grep metis
modinfo metis | grep vermagic   # must contain $(uname -r)

# PCIe link (vendor:device 1f9d:1100, Axelera AI Metis AIPU)
# Verified on device 2026-06-10: enumerates at 0004:01:00.0, bound to the 'metis' driver
lspci | grep -i axelera
sudo lspci -vvv -d 1f9d: | grep LnkSta   # Metis M.2 2280, PCIe Gen3 x4
                                          # expect "Speed 8GT/s, Width x4"

# Voyager runtime in venv
# (verified on the reference device, Voyager 1.6.1; on a fresh unit it fails until first-boot provisioning completes online, see 3.3)
/opt/av-env/bin/python -c "import axelera.runtime; print(axelera.runtime.__version__)"

# DMABUF heap exposed
ls /dev/dma_heap/   # system, linux,cma
```

---

## 4. Compatibility matrix (must agree across all three)

| Component  | This build         | Why locked                             |
|-----------|--------------------|----------------------------------------|
| L4T       | R36.4.3            | JetPack 6.2 baseline                 |
| CUDA      | 12.6               | Locked to L4T; do not pip-install      |
| ZED SDK   | 5.3.x              | Requires CUDA 12.6                     |
| pyzed     | matches SDK 5.3    | Installed via `get_python_api.py`      |
| numpy     | <2.0.0             | Hard requirement of Voyager SDK 1.6    |
| sl_zedx.ko| in-tree, our build | Vermagic-aligned with kernel           |
| metis.ko  | in-tree, our build | Vermagic-aligned with kernel           |

Mixing versions across this matrix breaks runtime in non-obvious ways
(silent frame corruption, segfaults at import, init failures with no log).
Run `make versions` to print the manifest at any time.

---

## 5. Troubleshooting

### `lsmod | grep sl_zedx` empty but module is on disk

Vermagic mismatch. Run `sudo /home/j/verify_tuning.sh`, fix per
[`VERMAGIC_STRATEGY.md`](VERMAGIC_STRATEGY.md).

### `v4l2-ctl --list-devices` shows nothing for ZED X

Overlay didn't apply. Verify `OVERLAYS` line in
`/boot/extlinux/extlinux.conf` and that the `.dtbo` file exists in
`/boot/`.

### Frames present but visually wrong

ISP `.isp` calibration missing or for the wrong sensor. Check
`/var/nvidia/nvcam/settings/`.

### `dmesg` shows MAX96712 errors

Wrong deserializer slipped through. Re-run Phase 1 (verify both the
defconfig flag and the Makefile `-D` flag).

### `lspci` shows nothing for Axelera

PCIe link train failed; the `LINK_WAIT_MAX_RETRIES` patch may not have applied.
Verify `pcie-designware.h` shows `200`, then rebuild and re-flash.

### `lsmod | grep metis` empty but `modinfo` works

modprobe failed. Most often vermagic mismatch. Run
`sudo /home/j/verify_tuning.sh` and look at the Module Vermagic Sanity
section.

### Voyager runtime fails with OOM / dropped inferences

`jetson_rt_tune.sh` shields the Axelera runtime with `oom_score_adj=-1000`,
but only after the process is running. If OOM strikes during launch,
shrink the model or close other processes.

### ZED SDK install fails to build sl_zedx.ko

`linux-headers-*.deb` wasn't installed before the SDK installer ran.
`dpkg -i /opt/kernel-headers/linux-headers-*.deb`, then re-run
`/opt/zed-sdk/install_zed_sdk.sh`. If the .deb is missing entirely,
re-run Phase 2 (`make build`) and re-bake (`make bake`).

For the symptom-first failure-mode table see
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).
