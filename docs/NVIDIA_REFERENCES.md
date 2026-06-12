---
title: NVIDIA References
layout: default
description: "Annotated bibliography of all NVIDIA, Axelera, Stereolabs, and community canonical sources used to derive magic values in this build."
nav_order: 40
---

# NVIDIA Reference Index

This document is the annotated bibliography for the jetson-rt-stack
build: the canonical NVIDIA, Axelera, Stereolabs, and community pages
from which every magic value in the pipeline is derived. Use it to
trace any `CONFIG_*`, patch, flash flag, or tuning value back to its
upstream source.

This repo intentionally carries no scraped reference material. A prior
revision shipped roughly 16 MB of scraped HTML
(`docs/nvidia_comprehensive/`, `docs/nvidia_r36.4/`, `docs/refs/`,
`docs/external/`) plus 8 MB of build and flash log artifacts. All of it
was removed: the source pages live online at the canonical URLs below,
and the values we actually consume are already captured in our own
docs. Every `CONFIG_*`, patch, and RT tuning value is recorded in
[KERNEL_OPTIMIZATIONS.md](KERNEL_OPTIMIZATIONS.md),
[KERNEL_PATCHES.md](KERNEL_PATCHES.md), and
[RT_KERNEL_OPTIMIZATION.md](RT_KERNEL_OPTIMIZATION.md).

## L4T R36.4.3 / JetPack 6.2, primary references

These are the canonical pages our build pipeline references:

| Page | URL |
|---|---|
| Jetson Linux R36.4.3 download hub (BSP, rootfs, toolchain, public sources) | https://developer.nvidia.com/embedded/jetson-linux-r3643 |
| Release notes (PDF) | https://docs.nvidia.com/jetson/archives/r36.4.3/ReleaseNotes/Jetson_Linux_Release_Notes_r36.4.3.pdf |
| Jetson Linux Developer Guide R36.4.3 (top) | https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/index.html |
| Quick Start | https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/IN/QuickStart.html |
| Flashing Support (the canonical reference for `l4t_initrd_flash.sh` flags + XMLs) | https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/SD/FlashingSupport.html |
| Kernel Customization (Bring Your Own Kernel) | https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/SD/Kernel/KernelCustomization.html |
| Boot Architecture (Orin boot flow, partition layout) | https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/AR/BootArchitecture.html |
| Module Adaptation (Orin NX/Nano series, board target names) | https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/HR/JetsonModuleAdaptationAndBringUp/JetsonOrinNxNanoSeries.html |
| Clocks (devfreq paths, BPMP debug clk tree, EMC) | https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/SD/Clocks.html |
| Backup & Restore (golden image clone) | https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/SD/FlashingSupport/BackupAndRestore.html |
| DBT (Device-Tree-Based Tooling) | https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/SD/Kernel/DBT.html |
| Power Management & nvpmodel | https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/SD/PlatformPowerAndPerformance/PlatformPowerAndPerformance.html |
| Jetson Orin NX module datasheet | https://developer.nvidia.com/downloads/jetson-orin-nx-module-series-data-sheet |
| CUDA GPU compute capability table (Orin NX = sm_87) | https://developer.nvidia.com/cuda/gpus |

## What we use each page for

- **Quick Start + Flashing Support**: source for the
  [04_flash_nvme.sh](../scripts/04_flash_nvme.sh) command structure
  (`l4t_initrd_flash.sh --external-device --network usb0 ...`).
- **Kernel Customization (BYOK)**: source for the cross-compile
  pattern and `LOCALVERSION`. The Bootlin toolchain URL we ship is
  taken from this page.
- **Boot Architecture**: source for the `MB1 -> MB2 -> CBoot -> UEFI
  -> Linux` chain documented in [COMMUNITY_POST.md](COMMUNITY_POST.md)
  Part 4.
- **Module Adaptation (Orin NX/Nano series)**: settles the
  `TARGET_BOARD` choice. Orin NX 16GB on a P3509-class carrier uses
  `jetson-orin-nano-devkit`, an alias of `p3509-a02+p3767-0000.conf`.
  The `-super` board target is the Orin Nano power table only and must
  not be used here. See [VERIFICATION_REPORT.md](VERIFICATION_REPORT.md)
  section 1.1 and `TARGET_BOARD` in [versions.env](../versions.env).
- **Clocks**: settles the GPU devfreq path. R36.x exposes the GPU at
  `/sys/class/devfreq/17000000.gpu/`, not the R35-era `.ga10b`. See
  [jetson_rt_tune.sh](../scripts/jetson_rt_tune.sh).
- **Backup & Restore**: the canonical workflow our golden-image clone
  ([clone_golden.sh](../scripts/clone_golden.sh) and
  [flash_golden.sh](../scripts/flash_golden.sh)) is built on. See
  [GOLDEN_IMAGE.md](GOLDEN_IMAGE.md).
- **Module datasheet**: pin counts, power envelope, JetPack matrix.

## Vendor / community references

The on-device consumers of these vendor stacks are documented in
[DRIVERS.md](DRIVERS.md) (ZED X driver and daemons),
[ZEDX_METIS_CPP.md](ZEDX_METIS_CPP.md) (C++ samples on the ZED SDK and
`libaxruntime`), and [BENCHMARKS.md](BENCHMARKS.md) (measured throughput).

Stereolabs ZED X / ZED Link Mono / ZED SDK:
- Drivers (`.deb` downloads, kernel module included): https://www.stereolabs.com/developers/drivers
- ZED Link install guide: https://www.stereolabs.com/docs/embedded/zed-link/install-the-drivers
- ZED SDK release / download: https://www.stereolabs.com/developers/release
- ZED SDK Jetson install (silent flags): https://www.stereolabs.com/docs/development/zed-sdk/jetson
- Python API (`get_python_api.py`): https://www.stereolabs.com/docs/development/python/install
- Python API repo: https://github.com/stereolabs/zed-python-api
- Stereolabs GitHub org: https://github.com/orgs/stereolabs/repositories

Axelera Voyager SDK / Metis M.2:
- Voyager SDK GitHub: https://github.com/axelera-ai-hub/voyager-sdk
- Voyager 1.6 release announcement (pip wheels): https://community.axelera.ai/product-updates/voyager-sdk-new-pipeline-builder-and-more-1313
- Metis M.2 product page: https://axelera.ai/ai-accelerators/metis-m2-ai-acceleration-card
- Metis M.2 datasheet (PDF): https://axelera.ai/hubfs/Axelera_February2025/pdfs/axelera-ai-m2-ai-edge-accelerator-module.pdf
- Community thread that confirmed the Metis PCI vendor ID `1f9d`
  (our earlier `1d60` was wrong). Match on the vendor ID `1f9d:`
  alone: rev-02 boards enumerate as `1f9d:1100`, rev-01 boards as
  `1f9d:11aa`. See `verify_tuning.sh` for the detection logic:
  https://community.axelera.ai/metis-pcie-7/axelera-metis-pcie-ai-accelerator-not-recognized-by-lspci-145
- Bring up Metis on Jetson Orin (Axelera Help Center):
  https://support.axelera.ai (search "Bring up Metis M.2 Jetson Orin")

ROS 2 Humble / Isaac ROS / Nav2:
- Isaac ROS getting started: https://nvidia-isaac-ros.github.io/getting_started/index.html
- isaac_ros_common: https://github.com/NVIDIA-ISAAC-ROS/isaac_ros_common
- Nav2 (humble branch): https://github.com/ros-navigation/navigation2/tree/humble/nav2_bringup
- rosbag2 mcap storage: https://docs.ros.org/en/humble/p/rosbag2_storage_mcap/
- FastDDS discovery (default UDP port range 7400-7500/udp): https://fast-dds.docs.eprosima.com/en/latest/fastdds/discovery/simple.html

Linux kernel (5.15, what L4T R36.4.3 ships):
- Tagged tree (Kconfig sources for every CONFIG_*): https://github.com/torvalds/linux/tree/v5.15
- kernel.org cgit (same tree): https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/tree/?h=linux-5.15.y
- PREEMPT_RT documentation: https://wiki.linuxfoundation.org/realtime/start

## How to re-fetch these pages offline

For offline copies (for example, shipping a flash station to a
network-restricted lab), run `wget` or `curl` against the URLs above.
The old `scripts/scrape_nvidia_*.py` crawlers did this in bulk and have
been removed for two reasons: the bulk output goes stale the moment
NVIDIA updates a page, and each scrape produced 506+ files for the
handful of pages we actually use.

A focused alternative (~10 lines):

```bash
mkdir -p offline_refs
for url in \
    "https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/IN/QuickStart.html" \
    "https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/SD/FlashingSupport.html" \
    "https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/SD/Kernel/KernelCustomization.html" \
    "https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/SD/FlashingSupport/BackupAndRestore.html" \
    "https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/HR/JetsonModuleAdaptationAndBringUp/JetsonOrinNxNanoSeries.html" \
; do
    wget -q -P offline_refs --convert-links --adjust-extension "$url"
done
```

## Where to find the canonical defconfig

The build mutates the L4T-stock defconfig in place at
`latest_jetson/Linux_for_Tegra/source/kernel/kernel-jammy-src/arch/arm64/configs/defconfig`,
injected by [01_extract_and_patch.sh](../scripts/01_extract_and_patch.sh).
A prior revision also carried separate copies of `defconfig.txt` and
`tegra_defconfig.txt` under `docs/refs/`. Those are removed: they were
stale snapshots of the same file that ships in the L4T tarball.

To inspect the stock baseline before our patches:

```bash
make extract   # extracts the L4T tarball into latest_jetson/
less latest_jetson/Linux_for_Tegra/source/kernel/kernel-jammy-src/arch/arm64/configs/defconfig
```

Phase 1 does not currently keep a `.orig` copy. To diff the stock
baseline against the patched config, add `cp defconfig defconfig.orig`
to the script before its `cat >>` append, re-run `make extract`, then:

```bash
DEFCONFIG_DIR=latest_jetson/Linux_for_Tegra/source/kernel/kernel-jammy-src/arch/arm64/configs
diff -u "$DEFCONFIG_DIR/defconfig.orig" "$DEFCONFIG_DIR/defconfig"
```
