---
title: Quickstart
layout: default
description: "Zero to flashed Jetson Orin NX 16GB in 90 minutes: clone, stage tarballs, make doctor, make all, make flash, make verify."
nav_order: 2
---

# Quickstart

The fastest path from a fresh clone to a flashed, verified Jetson Orin NX 16GB. First build: follow every step. Repeat builds: use [Runbook]({{ '/RUNBOOK' | relative_url }}).

## Choose your path

This build has two independent layers. Decide upfront so you stage the right source trees.

| I want | Path | Time |
|---|---|---|
| **Jetson + Metis + NVMe + Wi-Fi**: inference baseline (Metis M.2 accelerator, NVMe root, Wi-Fi staged), no camera, no ROS | Phases 1-4 only | ~90 min |
| **Full RT vision stack**: adds ZED X, Isaac ROS (cuVSLAM + nvblox + Nav2), resilience hardening | Phases 1-4, then 5 + 7 | ~90 min + ~2-3 h on-device |

**The baseline is complete after `make verify`.** You do not need ZED X driver source, a ZED SDK installer, or ROS to reach a working Metis inference image.

Wi-Fi (RTL8822CE) is staged into the baseline image (in-kernel `rtw88` blacklisted, vendor `rtl8822ce` installed but deliberately excluded from autoload, NetworkManager auto-connect profile installed). Bring it up with `sudo modprobe rtl8822ce` followed by `nmcli device status`; enable autoload with `WIFI_AUTOLOAD=1` at bake to opt in. Never force-load a probing driver at sysinit: a hung probe there blocks boot before sshd.

---

## Prerequisites

- Ubuntu 20.04 or 22.04 host (kernel build is containerized), 8 GB+ RAM (16 GB+ recommended), 40 GB+ free disk (100 GB+ recommended)
- Jetson Orin NX 16GB with NVMe SSD installed
- Axelera Metis M.2 in Key M slot
- USB-C direct to host (no hubs)
- *(Vision stack only)* ZED X + ZED Link Mono

## Step 0, Clone

```bash
git clone https://github.com/silicondoritos/jetson-rt-stack.git
cd jetson-rt-stack
make help       # available targets
make versions   # pinned versions
```

## Step 1, Host packages

```bash
sudo apt update
sudo apt install -y \
    build-essential bc bison flex git rsync zstd make openssl xxd \
    libssl-dev dpkg-dev qemu-user-static device-tree-compiler \
    nfs-kernel-server docker.io curl python3-pip

sudo usermod -aG docker $USER
newgrp docker

pip install kconfiglib    # required for make menuconfig / make defconfig
```

## Step 2, Configure

```bash
make defconfig      # apply committed defaults (full stack: RT + ZED X Mono + Metis + MAXN_SUPER)
# or:
make menuconfig     # interactive TUI to customize options
```

See [Configuration]({{ '/CONFIGURATION' | relative_url }}) for all available options.

## Step 3, Stage source tarballs and vendor trees

Place NVIDIA tarballs in the repo root:

```
jetson-rt-stack/
Jetson_Linux_r36.4.3_aarch64.tbz2
Tegra_Linux_Sample-Root-Filesystem_r36.4.3_aarch64.tbz2
public_sources.tbz2
```

**NVIDIA tarballs**: [developer.nvidia.com/embedded/jetson-linux-archive](https://developer.nvidia.com/embedded/jetson-linux-archive) → JetPack 6.2 / L4T R36.4.3. BSP, rootfs, and sources live under `r36_release_v4.3/` on the CDN (the Bootlin toolchain stays at `r36_release_v3.0/`). Exact pin: do not substitute 6.0 or 6.1. Filenames are matched case-insensitively (NVIDIA ships `R36.4.3`, the repo pins `r36.4.3`, so no renaming is needed); set `TARBALL_DIR=/path` (or `TARBALL_L4T_PATH` etc.) to stage them anywhere. Exact wget commands and account requirements: [Third-party dependencies]({{ '/THIRD_PARTY' | relative_url }}).

Vendor trees, place in the repo root:

```
jetson-rt-stack/
axelera-driver/      ← Axelera Metis kernel driver (account, Axelera customer portal)
voyager-sdk/         ← Axelera Voyager SDK + axl-jetson.patch (account, same package)
zedx-driver/         ← Stereolabs ZED X kernel driver (NDA, contact Stereolabs support)
zed-sdk/             ← ZED SDK installer (public, stereolabs.com/developers/release)
  └── ZED_SDK_Tegra_*.run
```

**`axelera-driver/` and `voyager-sdk/`** are required for the Metis baseline. **`zedx-driver/` and `zed-sdk/`** are required for the full RT vision stack. To build without camera or ZED SDK: set `CAMERA_NONE=y` in `make menuconfig`. See [Third-party dependencies]({{ '/THIRD_PARTY' | relative_url }}) for acquisition (who to contact, what must be inside each tree) and [Drivers]({{ '/DRIVERS' | relative_url }}) for integration detail.

## Step 4, Preflight

```bash
make doctor
```

Prints PASS/FAIL/WARN for every prerequisite. Read-only, modifies nothing. Fix all FAILs before continuing.

## Step 5, Build container (one-time)

```bash
make docker-build
```

~5 min. Ubuntu 22.04 + Bootlin aarch64 toolchain. Only needed again if the Dockerfile changes.

{: .note }
> **The one-command path.** Everything from here to the end of this page is also a single target: `make ignite` chains preflight, extract, build, bake, the audit gate, the flash (it pauses once and tells you to enter recovery mode), the first-boot wait, and the post-flash validation. `make ignite-no-flash` stops after the audit with a flash-ready image. Seed the login and an optional Wi-Fi profile inline: `SEED_USER=j SEED_WIFI_SSID=net SEED_WIFI_PSK=secret make ignite`. The steps below are that same pipeline broken out, for the first build or when something needs attention. Metis-only build (no camera): set Camera to "none" in `make menuconfig` at Step 2; the staging table drops to the two Axelera trees and `make verify`'s camera checks auto-skip.

## Step 6, Build firmware

```bash
make all    # extract -> build -> bake  (~45-90 min)
```

1. **Extract**: unpacks L4T tarballs, runs plugin hooks (vendor source injection, patches, in-tree shim creation, defconfig additions).
2. **Build**: cross-compiles kernel + modules + `linux-headers-*.deb` inside Docker. Captures vermagic. Hard-fails on module mismatch.
3. **Bake**: stages vendor SDKs, ISP calibrations, udev rules, systemd services, RT boot args, and `power.conf` into rootfs.

## Step 7, Pre-flash audit

```bash
make audit
```

Do not flash if this shows red.

- DTBO missing: re-run Phase 2
- Vermagic mismatch: `make clean && make all`

## Step 8, Recovery mode

1. Power the Jetson off.
2. Short REC and GND on the carrier.
3. Plug USB-C directly into the host (no hub, no extender).
4. Hold ~2 s, release.
5. Verify: `lsusb | grep 0955:7323` must show `NVIDIA Corp. APX`.

## Step 9, Flash

```bash
make flash    # 15-25 min
```

The flasher runs `apply_binaries` (which installs the stock kernel), then restores the custom RT kernel and modules over it, regenerates the initrd, sets MAXN_SUPER as the default nvpmodel profile (mode 0 on this image), and pre-seeds a headless login (`SEED_USER`, default `j`; set `SEED_USER=""` to opt out). Seeding matters: `apply_binaries` re-creates the oem-config first-boot wizard on every flash, and an unseeded image stalls in that wizard before sshd while the USB gadget is up and answering ping, which looks exactly like a hang. The flasher removes the wizard during the seed step and hard-fails if the wizard target survives. A vermagic gate and an initrd gate abort before any device write if the kernel and modules are inconsistent.

When the flash finishes:
1. Power off.
2. Remove the recovery jumper.
3. Power on. The first-boot service runs ~3-5 min, then reboots. It provisions the `/opt/av-env` Python environment (PyTorch, Voyager SDK wheels) only when the device has internet; on an offline boot it defers that step and re-runs on every boot, completing provisioning once a network is available.
4. After reboot, the RT cmdline is active and `jetson-rt-tune.service` locks clocks to MAXN_SUPER (nvpmodel mode 0).

A blank HDMI screen between "Exiting boot services" and the desktop is normal on Orin: `FRAMEBUFFER_CONSOLE` is off and the GOP framebuffer is torn down at ExitBootServices, so `earlycon=efifb` produces no output. Judge boot health in three steps: the USB device-mode gadget enumerates on the host (`lsusb` shows `0955:7020`, the host gains the `192.168.55.1` interface and a `/dev/ttyACM*` console), `ping 192.168.55.1` answers, and finally SSH succeeds. A healthy boot reaches SSH in about 60 seconds. The gadget and ping can be up while the board is still stuck before sshd (for example in the first-boot wizard on an unseeded image), so SSH is the definitive signal.

## Step 10, Verify (baseline complete)

```bash
make verify
```

Checks (via SSH to `192.168.55.1`):

**Baseline, always checked:**
- SSH reachable at `192.168.55.1`
- `uname -r` ends in `-tegra`; `uname -v` shows `SMP PREEMPT_RT` and `cat /sys/kernel/realtime` returns `1`
- Root is on NVMe: `findmnt /` shows `/dev/nvme0n1p1`
- `cat /sys/devices/system/cpu/isolated` is `1-5`
- Metis on PCIe (`1f9d:1100`), module loaded, vermagic match
- CMA pool 256 MB from the device tree `linux,cma` node (`CmaTotal` 262144 kB). Do not pass any `cma=` boot arg: a cmdline `cma=` bypasses the DT pool, and an oversized value such as `cma=2048M` fails to reserve on Orin NX, leaving zero CMA and breaking the GPU (nvgpu cannot allocate its 64 MB contiguous comptag buffer, so CUDA and nvpmodel both fail)
- `nvpmodel -q` is MAXN_SUPER (8 cores online, CPU max ~1.98 GHz)
- cyclictest 10 s on isolated cores 1-5: p99 max < 100 us (full test conditions: [RT tuning]({{ '/RT_KERNEL_OPTIMIZATION' | relative_url }}))
- `axelera.runtime` importable from `/opt/av-env`. This check fails until the first-boot service has provisioned `/opt/av-env`, which requires the device to have internet; the service re-runs each boot and completes provisioning once a network is available (e.g. an Ethernet cable)

`make verify` does not yet probe Wi-Fi or the ZED X overlay. Both are staged by the build but confirmed manually on device:
- Wi-Fi: load the driver manually with `sudo modprobe rtl8822ce`, then check `nmcli device status`. The module and auto-connect profile are installed during bake, but the driver is excluded from autoload.
- ZED X: the device-tree overlay loads at boot; the ZED SDK userspace installs at first boot when the `.run` is staged in `zed-sdk/`, otherwise it is a separate on-device step (see Layer 2 below). End-to-end capture is verified live on the reference device (2026-06-11: 29.5 FPS stereo + CUDA depth after `scripts/install_zedx_daemons.sh`); confirm on your own unit once a GMSL camera is attached.

**RT vision extension, checked when the camera is configured:**
- ZED X driver loaded, vermagic match
- `pyzed.sl` importable from `/opt/av-env`

All baseline checks green means **Layer 1 is complete.** The Jetson is ready for Metis inference.

---

## Next: Layer 2, RT vision extension (optional)

Install after `make verify` passes, over SSH or on the device directly:

```bash
# Phase 5: ROS 2 + Isaac ROS + OpenCV-CUDA  (~2-3 h, first time)
sudo bash /home/j/phase5/install_av_phase5.sh

# Phase 7: hardening, watchdog, brownout guard, PCIe AER monitor  (~15 min)
sudo bash /home/j/phase7/install_uav_phase7.sh
```

Phase 5 is installed and verified live on the reference device (2026-06-11): OpenCV-CUDA, ROS 2 + Isaac ROS + Nav2 + MAVROS, ZED X capture, and Metis inference at 49.2 FPS. RUNBOOK R18 is the exact replication sequence. Phase 7's resilience services (black-box, brownout guard, PCIe AER monitor) are active on the reference device. Still validate on your own hardware after running them.

Phase 5/7 run automatically at first boot when their scripts are staged; set `SKIP_PHASE5=1` before first boot to suppress Phase 5 and run it manually later.

See [AV Stack]({{ '/AV_STACK' | relative_url }}) and [Platform Resilience]({{ '/UAV_RESILIENCE' | relative_url }}) for details.

---

## One-shot

```bash
make ignite-no-flash    # doctor → all → audit  (no hardware needed)
make ignite             # doctor → all → audit → flash → verify
```

`ignite` prompts before flashing and waits 90 s post-flash for first-boot to complete.

## Failures

- Build → [Troubleshooting]({{ '/TROUBLESHOOTING' | relative_url }}) §B
- Flash → [Troubleshooting]({{ '/TROUBLESHOOTING' | relative_url }}) §F
- Vermagic → [Vermagic strategy]({{ '/VERMAGIC_STRATEGY' | relative_url }})
- Support bundle: `make logs` → `support-bundle-YYYYMMDD-HHMMSS.tar.gz`

## The payoff

A finished unit runs real workloads out of the box, all live-verified on the reference device:

- Voyager `inference.py`: YOLOv5s at 49.2 FPS end-to-end on 1080p video.
- C++ samples (`zedx_metis_infer` / `zedx_metis_fusion`): live ZED X into the Metis, detector-only up to 92 FPS at SVGA@120; full sensor fusion (depth + skeletons + IMU pose + tracking) at 46-53 FPS with `--depth-every`, with optional NVENC `--record`.

Run commands and the verification gauntlet: [Samples & Tests]({{ '/SAMPLES' | relative_url }}). Architecture and tuning: [ZED X + Metis C++]({{ '/ZEDX_METIS_CPP' | relative_url }}). Measured throughput, power, and thermals, with a reproducible harness: [Benchmarks]({{ '/BENCHMARKS' | relative_url }}).
