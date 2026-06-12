---
title: Compatibility
layout: default
nav_order: 6
description: "The pinned version matrix for jetson-rt-stack and what each component is validated against."
---

# Compatibility matrix
{: .no_toc }

Every version in this stack is pinned in [`versions.env`](https://github.com/silicondoritos/jetson-rt-stack/blob/main/versions.env). [`scripts/check_version_consistency.sh`](../scripts/check_version_consistency.sh) (run by `make doctor` and CI) proves the docs and scripts never drift from it. This page is the human-readable view of that pin set, plus the rationale for the platform choice.

1. TOC
{:toc}

---

## Live verification status

Confirmed live over SSH on the running board (2026-06-10):

- PREEMPT_RT kernel: `uname -v` shows `SMP PREEMPT_RT`; `/sys/kernel/realtime` reads `1`.
- Metis NPU: enumerated on PCIe at `0004:01:00.0`, bound to the `metis` driver.
- NVMe root: ADATA XPG GAMMIX S55 2 TB, rootfs mounted at `/` on `/dev/nvme0n1p1`.
- Power: `MAXN_SUPER` mode active, CPU max ~1.98 GHz, 8 cores online.

Confirmed live in the 2026-06-11 bring-up session:

- ZED X camera: end-to-end capture verified: pyzed opens the camera (HD1200@30), 29.5 FPS stereo sustained, CUDA depth maps. Requires the SPSC/daemon pieces from `scripts/install_zedx_daemons.sh` on top of the SDK installer ([Drivers]({{ '/DRIVERS' | relative_url }}) §1.5).
- CUDA userspace: nvidia-jetpack 6.2.1 (CUDA 12.6, cuDNN 9.3, TensorRT 10.3, VPI 3.2), installed on-device via apt; the flashed image ships none of it (TROUBLESHOOTING P-3).
- Voyager/Metis inference: YOLOv5s at 49.2 FPS end-to-end on 1080p video, 29.6 FPS camera-limited on the live ZED X feed ([AV Stack]({{ '/AV_STACK' | relative_url }}) § Voyager inference).
- C++ samples (`zedx_metis_infer` / `zedx_metis_fusion`): live-camera detection up to 92 FPS at SVGA@120, full fusion at 46-53 FPS with `--depth-every`; measured tables and the reproducible harness in [Benchmarks]({{ '/BENCHMARKS' | relative_url }}).
- ROS 2 Humble + Isaac ROS 3.2 (apt) + Nav2 + MAVROS; mission dry-run spawns all 6 nodes.

## Baseline

| Component | Pinned | Validated platform | Source |
|---|---|---|---|
| L4T (Jetson Linux) | **R36.4.3** | Orin NX 16GB (P3767-0000) | [jetson-linux-r3643](https://developer.nvidia.com/embedded/jetson-linux-r3643) |
| JetPack | **6.2** | maps to L4T 36.4.3 | [JetPack 6.2](https://developer.nvidia.com/embedded/jetpack-sdk-62) |
| Kernel | 5.15-tegra | PREEMPT_RT applied via `generic_rt_build.sh` | NVIDIA Kernel Customization |
| Toolchain | Bootlin `aarch64--glibc--stable-2022.08-1` (GCC 11.3.0) | reference cross-compiler | [JetsonLinuxToolchain](https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/AT/JetsonLinuxToolchain.html) |
| CUDA | 12.6 (12.6.10) | ships with JetPack 6.2 | JetPack 6.2 release notes |
| cuDNN / TensorRT | 9.3 / 10.3 | ships with JetPack 6.2 | JetPack 6.2 release notes |

## Accelerator and camera

| Component | Pinned | Notes | Source |
|---|---|---|---|
| Axelera Metis M.2 | PCI `1f9d:1100` (rev-02); `1f9d:11aa` (rev-01) | PCIe Gen3 x4, M.2 2280 M-key. Verified: enumerates at `0004:01:00.0`, bound to the `metis` driver. | upstream `pci.ids` |
| Voyager SDK | 1.6 | pip wheels, `numpy<2.0.0`; out-of-tree driver promoted in-tree here | software.axelera.ai Artifactory |
| ZED X | 2x 1920x1200 global shutter @ 60 fps | AR0234 sensors, GMSL2 over coax | Stereolabs ZED X datasheet |
| ZED Link Mono | MAX9296A deserializer | single-link GMSL2 to MIPI CSI-2 (Duo uses MAX96712) | Stereolabs ZED Link |
| ZED SDK | 5.3 | Covers L4T 36.4 and 36.5, CUDA 12.6. The kernel build stages the ZED X device-tree overlay; the SDK userspace is a separate on-device install. Capture is live-verified on the reference device (2026-06-11: 29.5 FPS stereo + CUDA depth, see above); the SDK alone is not enough: run `scripts/install_zedx_daemons.sh` ([Drivers]({{ '/DRIVERS' | relative_url }}) §1.5). | [ZED Releases](https://www.stereolabs.com/developers/release) |

## Python and autonomy stack

These rows are version pins. The `/opt/av-env` environment (PyTorch, Voyager SDK wheels) is provisioned by the first-boot service once the device has internet; the service re-runs each boot until provisioning completes, and `make verify`'s venv-import step fails until it does. On the reference device the full stack is provisioned and live-verified at these pins (2026-06-11), including CUDA userspace, Voyager inference, and the ROS 2 / Isaac ROS / Nav2 / MAVROS layer; see the verification status above.

| Component | Pinned | Notes | Source |
|---|---|---|---|
| PyTorch / torchvision | 2.8.0 / 0.23.0 | Jetson wheels, `jp6/cu126` index | pypi.jetson-ai-lab.io |
| NumPy | `< 2.0.0` | wheels built against NumPy 1.x | PyTorch NumPy-2 transition |
| ROS 2 | Humble | the JetPack-6 / Isaac ROS 3.x distro | docs.ros.org |
| Isaac ROS | 3.2 (Update 1) | **JetPack 6.2 is the validated platform** (see below) | [Isaac ROS releases](https://nvidia-isaac-ros.github.io/releases/index.html) |
| Nav2 | Humble | `SmacPlannerHybrid` (Hybrid-A*) | docs.nav2.org |
| MAVROS | 2.x | ROS 2 to Pixhawk over MAVLink, `/dev/ttyTHS1` @ 921600 | PX4 companion-computer docs |

## Telemetry and peripherals

| Component | Pinned | Notes |
|---|---|---|
| Wi-Fi/BT | RTL8822CE | Vendor `rtl8822ce` driver and a NetworkManager profile are staged; the in-kernel `rtw88` is blacklisted. The vendor module is deliberately not autoloaded at boot (a hung probe at sysinit blocks all logins); set `WIFI_AUTOLOAD=1` at bake to opt in. |
| Satellite (primary modem) | Iridium 9704 | IMT / JSPR JSON over FTDI USB-serial |
| Satellite (legacy) | Iridium 9602/9603 | SBD AT commands over CDC-ACM @ 19200, `IRIDIUM_MODEL` selects |

---

## Why JetPack 6.2 / L4T R36.4.3, not 6.2.2 / R36.5

{: .important }
> No Isaac ROS release was ever validated on JetPack 6.2.2 / L4T R36.5.

JetPack-6 Isaac ROS support tops out at L4T 36.4.x. Isaac ROS 3.2 "Update 1" (January 2025) added JetPack 6.2 on ROS 2 Humble. Isaac ROS 4.x then moved to JetPack 7 / Jazzy and dropped JetPack 6. JetPack 6.2.2 / L4T R36.5 shipped into that gap with no validated Isaac ROS release.

JetPack 6.2 maps to L4T **36.4.3** (kernel 5.15, CUDA 12.6.10) and still carries the `MAXN_SUPER` power profile (the uncapped super mode, above the fixed 40 W mode 4), so the 157 TOPS ceiling is unaffected by the choice. Layer 1 (Metis, NVMe) runs equally on R36.5; only Layer 2 autonomy benefits from the validated 36.4.3 pin.

To run Layer 1 on R36.5 instead, change `L4T_VERSION`, `JETPACK_VERSION`, `L4T_CDN_RELEASE`, and the two `TARBALL_*` names in `versions.env`, then run `make doctor` (the consistency linter will flag any reference you missed).

## NVIDIA CDN layout

The CDN release directory is not derivable from the L4T number. Full acquisition guide with download commands: [Third-party dependencies]({{ '/THIRD_PARTY' | relative_url }}).

| Asset | Path |
|---|---|
| BSP / rootfs / sources | `r36_release_v4.3/release/` and `/sources/` |
| Bootlin toolchain | `r36_release_v3.0/toolchain/` (release-independent mirror; `v4.3/toolchain/` 404s) |
| Documentation archive | `docs.nvidia.com/jetson/archives/r36.4.3/` |

All four pins live in `versions.env` (`L4T_CDN_RELEASE`, `L4T_TOOLCHAIN_CDN`) and are enforced by the consistency linter.

## Forward path

Isaac ROS 4.x (Jazzy, JetPack 7, L4T R38) is a separate track. See the [JetPack 7 roadmap]({{ '/ROADMAP_JP7' | relative_url }}).
