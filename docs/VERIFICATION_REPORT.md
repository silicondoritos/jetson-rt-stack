---
title: Verification Report
layout: default
description: "Audit report (May 2026, closeouts through June 2026): every magic value, URL, CONFIG flag, and hardware ID traced back to its vendor canonical source, with live on-device confirmation."
nav_order: 7
---

# Verification Report, May 2026

This is the audit trail behind the stack's pinned values: every build system claim cross-checked against vendor/upstream sources, then confirmed live on the reference device where hardware allows. Each record is VERIFIED, WRONG (+ fix), or UNCLEAR (+ field-confirm action). Read it when you need to know why a pin in [versions.env](../versions.env) holds its value. Per-unit closeout of the open items lives in [FIELD_CONFIRM_RESULTS.md](FIELD_CONFIRM_RESULTS.md); the symptom-first companion is [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

Method: authoritative URLs (kernel.org, NVIDIA developer docs, Stereolabs, Axelera community, Rock7, MAVLink, MAVROS, ROS, mavlink-router, FastDDS) compared against every magic value, URL, `CONFIG_*`, command flag, and protocol assumption.

## Summary

| Category | Verified | Wrong → fixed | Unclear → field-confirm |
|---|---|---|---|
| L4T R36.4.3 / NVIDIA toolchain | 4 | 3 | 2 |
| Drivers / vendor SDKs | 5 | 6 | 2 |
| Kernel CONFIG_* names (5.15) | 50+ | 2 | 0 |
| Telemetry / MAVLink / MAVROS | 8 | 4 | 2 |
| **Total** | **65+** | **15** | **6** |

15 corrections committed across 8 scripts and 4 docs.

Sections: [1](#section-1-l4t-r3643--nvidia-toolchain) NVIDIA toolchain ·
[2](#section-2-drivers--vendor-sdks) drivers and vendor SDKs ·
[3](#section-3-kernel-config_-names-linux-515--l4t-r3643) kernel CONFIG names ·
[4](#section-4-telemetry--mavlink--mavros--iridium) telemetry ·
[5](#section-5-may-2026-re-audit-upstream-version-check) May 2026 re-audit ·
[6](#section-6-june-2026-re-pin-and-grounded-corrections) June 2026 re-pin ·
[7](#section-7-phase-8-closeout-may-2026) Phase 8 closeout.

---

## On-device verification (live, confirmed over SSH, 2026-06-10)

The following claims are confirmed on the running board, not just configured. Each command and its observed result is reproducible over SSH.

| Claim | Confirm command | Observed |
|---|---|---|
| PREEMPT_RT kernel active | `uname -v` and `cat /sys/kernel/realtime` | `uname -v` reports `SMP PREEMPT_RT` (5.15.148-tegra); `/sys/kernel/realtime` reads `1` |
| Metis NPU on PCIe, bound to driver | `lspci -d 1f9d:` and `lspci -k -s 0004:01:00.0` | enumerated at `0004:01:00.0` (`1f9d:1100`), `metis.ko` loaded |
| NVMe root | `findmnt /` and `lsblk` | rootfs mounted at `/` on `/dev/nvme0n1p1` (ADATA XPG GAMMIX S55 2 TB) |
| MAXN_SUPER power mode | `nvpmodel -q` and `nproc` | MAXN_SUPER active (mode ID 0 on this image), 8 cores online, CPU max ~1.98 GHz, EMC locked at max |
| GPU kernel-side healthy | `grep CmaTotal /proc/meminfo`, `ls /sys/class/devfreq/`, `ls /dev/nvgpu/igpu0`, nvgpu lines in `dmesg` | `CmaTotal: 262144 kB` (device-tree `linux,cma` pool, no `cma=` boot arg), GPU devfreq present, GPU at 918 MHz, `/dev/nvgpu/igpu0` nodes present, zero nvgpu errors across the boot log |
| Boot to sshd | USB gadget (`0955:7020`) up, ping `192.168.55.1`, then ssh | sshd reachable in about 60 seconds; blank HDMI during boot is normal on Orin |
| GUI desktop session | `loginctl` | desktop session on `:0` with gdm3 autologin (user `j`) |

Items not covered by the live matrix above, verified live 2026-06-11:

- ZED X camera: VERIFIED LIVE (2026-06-11). pyzed opens the camera (HD1200@30) and sustains 29.5 FPS stereo with CUDA depth maps after `scripts/install_zedx_daemons.sh` installs the BMI088/SPSC modules, vendor daemons, and patched libnvisppg.so. See [DRIVERS.md](DRIVERS.md) §1.5.
- CUDA userspace: VERIFIED (2026-06-11). `/opt/av-env` is provisioned (PyTorch cu126, Voyager SDK 1.6.1 wheels), `verify_opengl_cuda.sh` passes 14/14, and live Metis inference runs at 49.2 FPS end-to-end on 1080p video (29.6 FPS camera-limited on the live ZED X feed). `make verify`'s venv-import step passes.
- Sustained throughput beyond these spot checks (the C++ samples, fusion with the `--depth-every` cadence, GPU load, power, thermals) is measured with the reproducible harness in [BENCHMARKS.md](BENCHMARKS.md); the C++ pipeline itself is documented in [ZEDX_METIS_CPP.md](ZEDX_METIS_CPP.md).

---

## Section 1, L4T R36.4.3 / NVIDIA toolchain

### 1.1 ❌ WRONG → FIXED · Board target name

**Claim**: `TARGET_BOARD=jetson-orin-nano-devkit-super`.
**Reality**: `jetson-orin-nano-devkit-super` is the flash config for the
Orin **Nano Super** module (SKU P3767-0004): a physically different module.
Using it on an Orin NX 16GB (P3767-0000) installs the wrong power table and
misconfigures the SoC. The correct flash target for Orin NX 16GB on the
P3768 devkit carrier is `jetson-orin-nano-devkit` (a symlink to
`p3768-0000-p3767-0000-a0.conf` in the extracted L4T tree; P3509-A02
carriers use the separate `p3509-a02-p3767-0000.conf`).
**Fix**: `versions.env` updated; `00_doctor.sh` validates against the
extracted L4T tree.

**Important distinction, NX Super Mode is separate from the `-super` board
target.** The Orin NX 16GB gained a `MAXN_SUPER` nvpmodel profile
(uncapped power budget, up to 157 TOPS; the fixed 40 W budget is the
separate mode 4) in JetPack 6.2 (L4T R36.4.x+). This is activated at runtime via
`nvpmodel -m 0`, not via the flash config. Live-verified mode table on this
image (the flash installs the SUPER nvpmodel conf as the default table):
0=MAXN_SUPER, 1=10W, 2=15W, 3=25W, 4=40W. The flash target remains
`jetson-orin-nano-devkit` for all Orin NX modules regardless of whether
Super Mode is used.

**Source**:
- [R36.4.3 Jetson Module Adaptation](https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/HR/JetsonModuleAdaptationAndBringUp/JetsonOrinNxNanoSeries.html)
- [OE4T discussion #1304, `-super` only for Nano](https://github.com/orgs/OE4T/discussions/1304)
- [NVIDIA platform power and performance, nvpmodel profiles for R36.x](https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/SD/PlatformPowerAndPerformance/PlatformPowerAndPerformance.html)

### 1.2 ❌ WRONG → FIXED · Bootlin toolchain URL

**Claim**: `https://developer.nvidia.com/.../r36_release_v5.0/toolchain/aarch64--glibc--stable-2022.08-1.tar.bz2`.
**Reality**: The R36.4.3 page links the toolchain under `r36_release_v3.0/toolchain/`. The `v5.0` URL 404s.
**Fix**: `Dockerfile` URL corrected.
**Source**: [Jetson Linux R36.4.3](https://developer.nvidia.com/embedded/jetson-linux-r3643)

### 1.3 ❌ WRONG → FIXED · GPU devfreq path

**Claim**: GPU is at `/sys/class/devfreq/17000000.ga10b`.
**Reality**: R36.4.3 exposes the GPU at `/sys/class/devfreq/17000000.gpu/`. The `.ga10b` suffix is R35-era. We now try `.gpu` first and fall back to `.ga10b` for backwards compat.
**Fix**: `jetson_rt_tune.sh` updated to probe `.gpu` → `.ga10b` → platform-direct path.
**Source**: [R36.4.3 Clocks](https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/SD/Clocks.html)

### 1.4 ✅ VERIFIED · Flash command structure

`l4t_initrd_flash.sh --external-device nvme0n1p1 -c flash_l4t_t234_nvme.xml -p "-c flash_t234_qspi.xml" --showlogs --network usb0 <board> internal` is the canonical R36.4.3 NVMe pattern. Both XMLs ship in R36.4.3.
**Source**: [R36.4.3 Flashing Support](https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/SD/FlashingSupport.html)

### 1.5 ✅ VERIFIED · Bootlin toolchain version

`aarch64--glibc--stable-2022.08-1` (gcc 11.3) is the recommended toolchain for L4T R36.4.3.

### 1.6 ✅ VERIFIED · CUDA SM 8.7 for Orin NX

Orin NX is GA10B / Ampere, compute capability 8.7. `CUDA_ARCH_BIN=8.7` in `build_opencv_cuda.sh` is correct.
**Source**: [CUDA GPUs](https://developer.nvidia.com/cuda/gpus)

### 1.7 ✅ VERIFIED · EMC clock path

`/sys/kernel/debug/bpmp/debug/clk/emc/` with `rate`, `min_rate`, `max_rate`, `mrq_rate_locked`: correct for R36.4.3.

### 1.8 ✅ VERIFIED · P3509-class carrier board target

P3509-class carriers use the stock NVIDIA `jetson-orin-nano-devkit` target with `flash_t234_qspi.xml`.

### 1.9 ❓ UNCLEAR · `LINK_WAIT_MAX_RETRIES` default

Path `drivers/pci/controller/dwc/pcie-designware.h` is correct. Mainline upstream sets it to 10. NVIDIA's L4T tree may patch this differently. **Field check**: `grep LINK_WAIT_MAX_RETRIES Linux_for_Tegra/source/kernel/kernel-jammy-src/drivers/pci/controller/dwc/pcie-designware.h` after Phase 1 extract; confirm pre-patch value before our `sed` fires.

### 1.10 ❓ UNCLEAR · Carrier HV rail and 40 W Super Mode capability

**Situation**: Orin NX 16GB MAXN_SUPER (the uncapped super profile, up to 157 TOPS; the fixed 40 W budget is the separate mode 4) is available in JetPack 6.2 / L4T R36.4.x+. Activated via `nvpmodel -m 0` on this image (live-verified table: 0=MAXN_SUPER, 1=10W, 2=15W, 3=25W, 4=40W). MAXN_SUPER is confirmed active on the bench (2026-06-10); sustained 40 W under flight load remains the open field-confirm item.
**Gap**: NVIDIA's power documentation states NX Super Mode requires the carrier to expose the HV DC-in rail and be rated for sustained 40 W + thermal dissipation. Verify this against your carrier's power spec and schematic before enabling MAXN_SUPER. Using it on an under-rated carrier risks brownout or thermal shutdown in flight.
**Field check before enabling Super Mode**:
1. Confirm carrier input voltage range and DC-DC converter current rating from the carrier vendor.
2. With `nvpmodel -m 0` (MAXN_SUPER) active and Metis inference running, measure rail voltage and monitor `tegrastats` for throttling (`@` suffix) and junction temps.
3. Keep a thermal margin: if temps exceed 85 °C at idle under MAXN_SUPER, the thermal solution is insufficient.
**Default**: rt-tune defaults to `NVPMODEL_MODE=0` (MAXN_SUPER), overridable in `/etc/jetson-av/power.conf`. To reduce power, set `NVPMODEL_MODE=3` (25 W) or another lower mode from the table above.
**Source**: [NVIDIA platform power and performance](https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/SD/PlatformPowerAndPerformance/PlatformPowerAndPerformance.html)

---

## Section 2, Drivers / vendor SDKs

### 2.1 ❌ WRONG → DOCUMENTED · ZED X kernel driver source repo

**Claim**: `git clone --branch master https://github.com/stereolabs/zed-driver zedx-driver`.
**Reality**: **No public Stereolabs repo exists for the ZED X / ZED Link kernel driver.** Stereolabs distributes signed `.deb` packages (e.g. `stereolabs-zedlink-mono_<ver>-LI-MAX9296-all-L4T36.x_arm64.deb`) and does not publish the source. The .deb's compiled `.ko` is built against the stock NVIDIA L4T kernel, vermagic will not match our PREEMPT_RT build.
**Fix**: `docs/DRIVERS.md` opens with a callout explaining the two paths forward (1) get source via Stereolabs business agreement, (2) skip ZED X for now. The in-tree promotion under `drivers/media/i2c/zedx/` is preserved as the right architecture **once source is available**.
**Source**:
- [Stereolabs GitHub org list, 48 repos, no kernel-driver repo](https://github.com/orgs/stereolabs/repositories)
- [Stereolabs driver downloads page (.deb only)](https://www.stereolabs.com/developers/drivers)

### 2.2 ✅ VERIFIED · ZED Link Mono uses MAX9296

ZED Link Mono = Maxim **MAX9296A** deserializer; ZED Link Duo / Quad use **MAX96712**. Confirmed via Stereolabs `.deb` filenames (`-LI-MAX9296-` vs `-LI-MAX96712-`). Our defconfig + Makefile choice was right.
**Source**: [Stereolabs driver install guide](https://www.stereolabs.com/docs/embedded/zed-link/install-the-drivers)

### 2.3 ❌ WRONG → FIXED · ZED SDK installer flags

**Claim**: `silent skip_drivers skip_python skip_cuda skip_tools`.
**Reality**: `skip_drivers` does NOT exist. Documented silent-mode flags are `silent`, `runtime_only`, `skip_cuda`, `skip_python`, `skip_tools`, `skip_od_module`, `skip_hub`, `nvpmodel=0`.
**Fix**: `install_zed_sdk.sh` invocation changed to `silent runtime_only skip_python skip_cuda skip_tools skip_od_module skip_hub nvpmodel=0`.
**Source**: [ZED SDK Jetson install guide](https://www.stereolabs.com/docs/development/zed-sdk/jetson)

### 2.4 ✅ VERIFIED · ZED SDK 5.3 + L4T R36.4.3 + CUDA 12.6

ZED SDK 5.3.0 (released Apr 29 2026) lists Jetson builds for both **JetPack 6.2 (L4T 36.4)** and JetPack 6.2.2 (L4T 36.5), each on **CUDA 12.6**. The 5.3 pin is therefore valid for the JetPack 6.2 / R36.4.3 baseline, and would also cover R36.5 if the baseline were bumped. `ZED_SDK_VERSION` stays at 5.3.
**Source**: [ZED Releases](https://www.stereolabs.com/developers/release)

### 2.5 ✅ VERIFIED · pyzed via `get_python_api.py`

`/usr/local/zed/get_python_api.py` is still the canonical install path and auto-detects Python/CUDA. There is no PyPI alternative.

### 2.6 ❌ WRONG → FIXED · Voyager SDK pip extra-index URL

**Claim**: `https://software.axelera.ai/artifactory/axelera-pypi/`.
**Reality**: The pip API requires `/api/pypi/<repo>/simple` suffix. Correct URL: `https://software.axelera.ai/artifactory/api/pypi/axelera-pypi/simple`.
**Fix**: `versions.env` and `jetson_first_boot.sh` updated.
**Source**: [Voyager 1.6 release announcement](https://community.axelera.ai/product-updates/voyager-sdk-new-pipeline-builder-and-more-1313)

### 2.7 ❌ WRONG → FIXED · Axelera PCI vendor:device ID

**Claim**: `lspci -d :1d60:`.
**Reality**: Axelera AI vendor ID is `1f9d`, Metis device ID `1100`. **Every `lspci -d :1d60:` query in our code would silently fail to match.**
**Fix**: `axelera_brownout_guard.sh`, `verify_tuning.sh`, `install_uav_phase7.sh`, `docs/UAV_RESILIENCE.md`, `docs/DRIVERS.md`, `README.md` all updated to `1f9d` (or `1f9d:1100`).
**Source**: [Axelera community thread confirming PCI ID](https://community.axelera.ai/metis-pcie-7/axelera-metis-pcie-ai-accelerator-not-recognized-by-lspci-145)

### 2.8 ❌ WRONG → FIXED · Metis form factor + PCIe spec

**Claim**: M.2 2230, PCIe Gen4 x2.
**Reality**: M.2 **2280** M-key, PCIe **Gen3 x4**, ~11.55 W avg / 23.1 W peak.
**Fix**: `README.md` and `docs/DRIVERS.md` updated. The `axelera_brownout_guard.sh` 18 W power cap is still appropriate for the verified 23.1 W peak.
**Source**: [Axelera Metis M.2 datasheet](https://axelera.ai/hubfs/Axelera_February2025/pdfs/axelera-ai-m2-ai-edge-accelerator-module.pdf)

### 2.9 ❓ UNCLEAR · `axdevice --set-power-limit` flag spelling

`axdevice` is the documented Voyager CLI; setting a power limit IS a documented capability. **Confirmed 2026-06-11 (FIELD_CONFIRM 3.2)**: `axdevice --help` on the installed 1.6.1 runtime lists `--set-power-limit LIMIT` verbatim. `axelera_brownout_guard.sh` is correct as written.

### 2.10 ✅ RESOLVED · `AXELERA_GST_EXPLICIT_PARSE=1` was stale, removed

**Closed 2026-06-11 (FIELD_CONFIRM 3.3)**: `grep -rn` over the full Voyager
1.6.1 checkout and installed wheels returns zero references. The variable
does nothing. The export was removed from `jetson_first_boot.sh`. Inference
verified working without it; the decode workaround Jetson actually needs is
`GST_PLUGIN_FEATURE_RANK=nvv4l2decoder:NONE` (AV_STACK.md).

### 2.11 ✅ VERIFIED · Voyager SDK 1.6 ships pip wheels

`axelera-rt` and `axelera-devkit` packages are the current Voyager 1.6 install path; legacy `install.sh --driver` is deprecated.

---

## Section 3, Kernel CONFIG_* names (Linux 5.15 / L4T R36.4.3)

Verified against `torvalds/linux` at tag `v5.15` via `raw.githubusercontent.com`. **All ~50 flags in our defconfig block were confirmed to exist with the exact names we use** EXCEPT:

### 3.1 ❌ WRONG → FIXED · `CONFIG_TPM_HW_RANDOM` → `CONFIG_HW_RANDOM_TPM`

**Reality**: The symbol is `HW_RANDOM_TPM` (in `drivers/char/hw_random/Kconfig`), not `TPM_HW_RANDOM`. Kconfig silently ignores the wrong name, we got no random source from the TPM with the previous defconfig.
**Fix**: `01_extract_and_patch.sh` defconfig block.

### 3.2 ❌ WRONG → DROPPED · `CONFIG_DEVKMEM`

**Reality**: Removed from upstream Linux in 5.13 (commit `f2ad42f6db20`). Symbol does not exist in 5.15. Our `# CONFIG_DEVKMEM is not set` was a no-op.
**Fix**: Comment retained but annotated; symbol no longer referenced as if it were live.

### 3.3 ✅ VERIFIED · `CONFIG_USB_ACM`

Our addition was correct as a kernel symbol (lives in `drivers/usb/class/Kconfig`, module `cdc-acm`). However, see §4.4 for the misconception about what hardware actually needs it.

### 3.4 ✅ VERIFIED · `CONFIG_CPU_ISOLATION`

Real bool symbol in `init/Kconfig` (default `y`); independent of `NO_HZ_FULL`. Our usage was right.

### 3.5 ⚠️ FUTURE WARNING · `CONFIG_MEMCG_SWAP`

Removed in 6.1 (knob became boot/sysctl). Fine for 5.15 / L4T R36.4.3; flag for any future kernel rebase.

**All other 50+ flags verified correct**: `PREEMPT_RT`, `NO_HZ_FULL`, `HZ_1000`, `RCU_NOCB_CPU`, `IRQ_FORCED_THREADING`, `HIGH_RES_TIMERS`, `RCU_BOOST`, `PREEMPT_DYNAMIC`, `NUMA_BALANCING`, `SCHED_AUTOGROUP`, `LATENCYTOP`, `DMABUF_HEAPS{,_CMA,_SYSTEM}`, `DMABUF_SYSFS_STATS`, `SYNC_FILE`, `SW_SYNC`, `CMA_SIZE_MBYTES`, `TRANSPARENT_HUGEPAGE{,_MADVISE}`, `USERFAULTFD`, `PAGE_REPORTING`, `CGROUPS`, `CGROUP_SCHED`, `CGROUP_CPUACCT`, `CPUSETS`, `CGROUP_DEVICE`, `CGROUP_FREEZER`, `CGROUP_PIDS`, `CGROUP_BPF`, `MEMCG`, `TCP_CONG_BBR`, `DEFAULT_TCP_CONG`, `NET_FOU`, `BPF_JIT{,_ALWAYS_ON}`, `XDP_SOCKETS`, `NET_RX_BUSY_POLL`, `NET_SCH_FQ{,_CODEL}`, `BLK_MQ_PCI`, `NVME_MULTIPATH`, `NVME_HWMON`, `IO_URING`, `USB_ANNOUNCE_NEW_DEVICES`, `USB_SERIAL_FTDI_SIO`, `USB_SERIAL_CP210X`, `USB_USBNET`, `USB_NET_RNDIS_HOST`, `USB_NET_CDCETHER`, `KEXEC{,_FILE}`, `CRASH_DUMP`, `PROC_VMCORE`, `SECURITY{,_YAMA,_LOCKDOWN_LSM}`, `LSM`, `TCG_TPM`, `TCG_TIS`, `MODVERSIONS`, `MODULE_SRCVERSION_ALL`, `MODULE_FORCE_LOAD`, `HARDENED_USERCOPY`, `FORTIFY_SOURCE`, `STACKPROTECTOR_STRONG`, `RANDOMIZE_BASE`, `RANDOMIZE_MODULE_REGION_FULL`, `INIT_STACK_ALL_ZERO`, `DEVMEM`, `LEGACY_PTYS`, `RTW88{,_8822CE}`, `ARM64_PTR_AUTH`, `ARM64_BTI{,_KERNEL}`, `CRYPTO_AES_ARM64_CE`, `CRYPTO_SHA512_ARM64`, `KERNEL_MODE_NEON`.

**Source**: `https://raw.githubusercontent.com/torvalds/linux/v5.15/<path>` for each Kconfig file referenced.

---

## Section 4, Telemetry / MAVLink / MAVROS / Iridium

### 4.1 ❌ WRONG → FIXED · Pixhawk 6X TELEM2 → `/dev/ttyTHS1` (not `ttyTHS0`)

**Claim**: TELEM2 maps to `/dev/ttyTHS0`.
**Reality**: On P3509-class carriers, Pixhawk TELEM2 is typically wired to UART1, exposed as `/dev/ttyTHS1`. `/dev/ttyTHS0` is the debug console. Verify with `dmesg | grep ttyTHS` on your specific carrier.
**Fix**: `versions.env` adds `FCU_TTY_DEFAULT=/dev/ttyTHS1`, telemetry-failover.conf default updated, install_telemetry_failover.sh helper text updated.
**Source**:
- [PX4 companion computer docs](https://docs.px4.io/main/en/companion_computer/)

### 4.2 ❌ WRONG → REWRITTEN · RockBLOCK 9704 enumeration + protocol

**Claim**: RockBLOCK 9704 enumerates as CDC-ACM (`/dev/ttyACM0`) and uses the AT command set (`AT+SBDWB`, `AT+SBDIX`).
**Reality**: The 9704 uses an FTDI USB-TTL bridge (`/dev/ttyUSB0` via `ftdi_sio`), NOT CDC-ACM. The 9704 protocol is **JSPR (JSON-based Serial Protocol for REST)**, NOT AT commands. AT commands belong to the legacy 9602/9603 modems.
**Fix**: `install_telemetry_failover.sh` rewritten to be model-aware. New env knob `IRIDIUM_MODEL` (default `9704`) selects the sender:
- `9704` → uses `rockblock9704` Python SDK (Rock7's official client; `pip install rockblock9704`); JSPR JSON via FTDI at 230400 baud.
- `9603` / `9602` → legacy AT path over CDC-ACM at 19200.
The relay's packing layer (mavlink → 36-byte payload) is shared; only the sender differs.
**Source**:
- [GroundControl 9704 hardware docs (FTDI)](https://docs.groundcontrol.com/iot/rockblock-9704/hardware)
- [Rock7 RockBLOCK-9704 SDK](https://github.com/rock7/RockBLOCK-9704)
- [GroundControl 9602/9603 AT command manual](https://docs.groundcontrol.com/iot/rockblock/user-manual/at-commands)

### 4.3 ❌ WRONG → FIXED · `RC_CHANNELS_RAW` → `RC_CHANNELS`

Both messages exist in MAVLink common dialect, but PX4 / ArduPilot now emit `RC_CHANNELS` (up to 18 channels). Updated the relay's TRACKED tuple.
**Source**: [MAVLink common.xml](https://mavlink.io/en/messages/common.html)

### 4.4 ⚠️ NOTE · `CONFIG_USB_ACM` was added for the WRONG reason

We added it thinking RockBLOCK 9704 needed it. The 9704 actually uses FTDI (already covered by `CONFIG_USB_SERIAL_FTDI_SIO`). `CONFIG_USB_ACM=m` is still useful, it covers the **legacy 9602/9603** if anyone uses one, plus various cellular modems that present as CDC-ACM. Kept in defconfig with corrected justification.

### 4.5 ❌ WRONG → FIXED · MAVROS install_geographiclib path

**Claim**: `bash /opt/ros/humble/lib/mavros/install_geographiclib_datasets.sh`.
**Reality**: Canonical invocation is `ros2 run mavros install_geographiclib_datasets.sh`: the hardcoded path is not portable.
**Fix**: `install_av_stack.sh` updated.
**Source**: [mavros ros2 README](https://github.com/mavlink/mavros/blob/ros2/mavros/README.md)

### 4.6 ✅ VERIFIED · mavlink-router config syntax

Sections, keys, and modes all correct (`[General]`, `[UartEndpoint <name>]`, `[UdpEndpoint <name>]`, `Mode = Server|Normal`, `Address`, `Port`, `Device`, `Baud`, `TcpServerPort`, `Log`, `LogMode = while-armed`, `ReportStats = true`).
**Source**: [mavlink-router examples/config.sample](https://github.com/mavlink-router/mavlink-router/blob/master/examples/config.sample)

### 4.7 ✅ VERIFIED · MAVLink message names + GCS sysid 255

`GLOBAL_POSITION_INT`, `ATTITUDE`, `SYS_STATUS`, `RC_CHANNELS` all canonical. System ID 255 is the de-facto GCS convention.

### 4.8 ✅ VERIFIED · MAVROS package names

`ros-humble-mavros`, `ros-humble-mavros-extras` correct apt names.

### 4.9 ✅ VERIFIED · MAVROS FCU URL format

`/dev/ttyTHS1:921600` valid. Schemes: `serial://`, `serial-hwfc://`, `udp://`, `tcp://`, `tcp-l://`.

### 4.10 ✅ VERIFIED · `nav2_bringup navigation_launch.py`

Canonical Nav2 bringup launch on Humble.

### 4.11 ✅ VERIFIED · `ros-humble-rosbag2-storage-mcap`

Correct apt name.

### 4.12 ✅ VERIFIED · Isaac ROS: Jazzy-only for 4.x, Humble pinned to 3.x

Isaac ROS **4.4.0** (released 2026-04-30) requires ROS 2 **Jazzy on Ubuntu 24.04**: Humble is not supported in the 4.x line. Humble operators must use Isaac ROS 3.x. Apt package coverage for `ros-humble-isaac-ros-*` was field-confirmed sufficient on the reference device 2026-06-11 (FC-4, [FIELD_CONFIRM_RESULTS.md](FIELD_CONFIRM_RESULTS.md) §3.4): `install_av_stack.sh` installs from the release-3 apt repo, keeping the `git clone NVIDIA-ISAAC-ROS/isaac_ros_*` + colcon build only as a fallback. Plan Jazzy migration when moving to JetPack 7.x.

Source: https://nvidia-isaac-ros.github.io/releases/index.html

### 4.13 ✅ VERIFIED with caveat · FastDDS UFW port range `7400:7500/udp`

Correct for **DDS domain 0**. Formula `7400 + 250*domainID + offset + 2*participantID` means non-default domains need a wider or different range.

---

## Section 5, May 2026 re-audit (upstream version check)

### 5.1 ❌ WRONG → FIXED · PyTorch version and index domain

**Claim**: `PYTORCH_VERSION=2.8.0`, domain `pypi.jetson-ai-lab.io`
**Reality (updated 2026-06-10)**: the index prunes old wheels; it now serves 2.8.0 through 2.11.0 (2.7.0 is gone) and only the `pypi.jetson-ai-lab.io` host resolves (`.dev` is dead at the DNS level). The pin is 2.8.0 (torchvision 0.23.0); device-verified download from the live index.
**Fix**: `versions.env`, `scripts/jetson_first_boot.sh`, `docs/FLASH.md`, `README.md`.
**Update (June 2026)**: Jetson AI Lab has since migrated the index host back to `pypi.jetson-ai-lab.io`. `.io` is now primary; `.dev` is kept only as a first-boot fallback. See §6.2.
**Source**: https://pypi.jetson-ai-lab.io/jp6/cu126/

### 5.2 ❌ WRONG → FIXED · APX recovery USB ID for Orin NX

**Claim**: `USB_ID_APX=0955:7023`
**Reality**: `0955:7023` is the AGX Orin APX ID. Orin NX (P3767) APX ID is **`0955:7323`**.
**Fix**: `versions.env`, `scripts/04_flash_nvme.sh`, `docs/FLASH.md`, `docs/QUICKSTART.md`, `docs/RUNBOOK.md`, `docs/TROUBLESHOOTING.md`, `docs/index.md`, `docs/AUTOMATION.md`.

### 5.3 ❌ WRONG → FIXED · RockBLOCK 9704: IMT not SBD

**Claim**: "Iridium SBD", `/dev/ttyACM0` at 19200 baud, `CONFIG_USB_ACM=m`.
**Reality**: 9704 uses **Iridium IMT** (Messaging Transport), JSPR JSON over FTDI USB-serial (`/dev/ttyUSB0`) at **230400 baud**. Needs `CONFIG_USB_SERIAL_FTDI_SIO=m`. SBD/ACM/19200 applies to 9602/9603 only.
**Fix**: `docs/TELEMETRY_FAILOVER.md`, `versions.env` comment, `docs/index.md`, `README.md`.
**Source**: https://docs.groundcontrol.com/iot/rockblock-9704/intro

### 5.4 ❌ WRONG → FIXED · TELEMETRY_FAILOVER FCU_TTY example

**Claim**: `FCU_TTY=/dev/ttyTHS0` in the config example.
**Reality**: TELEM2 → `/dev/ttyTHS1`. `ttyTHS0` is the debug console.
**Fix**: `docs/TELEMETRY_FAILOVER.md` config example.

### 5.5 ⤳ SUPERSEDED BY §6.1 · baseline pin

The May audit verified JetPack 6.2.2 / L4T R36.5.0 as current for Orin NX. The June re-pin (§6.1) deliberately moves the baseline to JetPack 6.2 / L4T R36.4.3 for a validated Isaac ROS combination. Both run kernel 5.15 and CUDA 12.6; 6.2.2 / R36.5 stays a valid Layer-1 target. (version-lint-ok)

### 5.6 ✅ VERIFIED · CUDA 12.6, SM 8.7, ZED SDK 5.3, MAVROS 2.14.0, Axelera PCI ID 1f9d:1100, /dev/ttyTHS1 at 921600

All confirmed against upstream docs May 2026.

---

## Section 6, June 2026 re-pin and grounded corrections

A second grounding pass cross-checked every component against current NVIDIA, Stereolabs, Axelera, kernel.org, and PX4 documentation. Findings below.

### 6.1 🔧 RE-PIN · baseline JetPack 6.2.2 / R36.5 → JetPack 6.2 / R36.4.3

No Isaac ROS release was ever validated on JetPack 6.2.2 / L4T R36.5. JetPack-6 Isaac ROS support tops out at L4T 36.4.x: Isaac ROS 3.2 "Update 1" (Jan 2025) added JetPack 6.2 on Humble, and Isaac ROS 4.x moved to JetPack 7 / Jazzy. JetPack 6.2 maps to L4T **36.4.3** (kernel 5.15, CUDA 12.6.10) and still carries the MAXN_SUPER profile, so the uncapped super ceiling (up to 157 TOPS) is unaffected.

CDN note: R36.4.3 BSP/rootfs/sources live under `r36_release_v4.3/`. The Bootlin toolchain stays at the release-independent `r36_release_v3.0/toolchain/` mirror (v4.3/toolchain 404s). All four URLs verified June 2026.
**Source**: https://nvidia-isaac-ros.github.io/releases/index.html , https://developer.nvidia.com/embedded/jetson-linux-r3643

### 6.2 🔧 FIXED · PyTorch index host migrated `.dev` → `.io`

Jetson AI Lab renamed its PyPI index host from `pypi.jetson-ai-lab.dev` to `pypi.jetson-ai-lab.io`. `.io` is now primary in `versions.env`; `jetson_first_boot.sh` falls back to `.dev`. Supersedes the §5.1 domain note.
**Source**: https://forums.developer.nvidia.com/t/packages-removed-from-pypi-jetson-ai-lab-io-indexes/348376

### 6.3 🔧 FIXED · prose corrections grounded against vendor docs

| Was | Corrected to | Source |
|---|---|---|
| "stock CMA reserves 32 MB" | Orin reserves CMA via the device-tree `linux,cma` pool (256 MiB on this board). Live-verified (2026-06-10): a cmdline `cma=2048M` FAILED to reserve ("cma: Failed to reserve 2048 MiB") and also bypassed the DT pool, leaving zero CMA; nvgpu then failed its 64 MB contiguous comptag allocation at GPU poweron (`ga10b_cbc_alloc_comptags`, "DMA alloc FAILED"), cascading into "Unable to recover GR falcon", FECS init error, no CUDA, no GPU devfreq, and nvpmodel unable to set any mode. Fix: pass NO `cma=` boot arg; the DT pool then takes over (verified `CmaTotal: 262144 kB`, zero nvgpu errors, GPU healthy) | on-device boot log + `/proc/meminfo` |
| "MAXN 25 W / 100 TOPS" as one figure | Two axes: 100 TOPS is sparse-INT8 compute, 25 W is the standard module power budget. Super Mode raises both axes: compute up to 157 TOPS, power to the uncapped MAXN_SUPER budget (the fixed 40 W budget is the separate mode 4). Exact per-mode wattages come from the carrier nvpmodel table, not the docs | NVIDIA PlatformPowerAndPerformance |
| "ZED X is a 4K@30 camera" | ZED X is 2× 1920×1200 global-shutter @ 60 fps; 4K@30 is the ZED Link Mono **capture card** throughput ceiling | Stereolabs ZED X datasheet |
| Metis "in-tree, no DKMS" implied as vendor behavior | Axelera ships the driver out-of-tree/DKMS-like; in-tree promotion is a repo PREEMPT_RT hardening choice | Axelera Metis-on-Jetson article |
| `LINK_WAIT_MAX_RETRIES` patch | vendor `axl-jetson.patch` raises 10 → 50; this repo overrides to the `PCIE_LINK_WAIT_MAX_RETRIES` pin in [versions.env](../versions.env), for Metis link-training reliability | Axelera bring-up guide |
| Metis "~18-20 W" framing | Axelera rated typical application power is 3.5-9 W; 18 W is a carrier brownout-budget ceiling, not the device draw | Axelera Metis M.2 product page |
| deserializer "MAX9296" (prose) | physical part is **MAX9296A**; kernel symbol `CONFIG_SL_DESER_MAX9296` unchanged | Stereolabs ZED Link datasheet |
| `lspci -d 1f9d:1100` | match on vendor only (`lspci -d 1f9d:`) so rev-01 boards (`1f9d:11aa`) also enumerate | upstream pci.ids |

## Files modified by this verification pass

```
versions.env                                ← board name, FCU TTY default,
                                              Voyager pip URL, IRIDIUM_MODEL knob
Dockerfile                                  ← Bootlin URL v5.0 → v3.0
scripts/01_extract_and_patch.sh             ← TPM_HW_RANDOM → HW_RANDOM_TPM,
                                              DEVKMEM annotation
scripts/jetson_rt_tune.sh                   ← GPU devfreq path probe
scripts/jetson_first_boot.sh                ← Voyager pip URL
scripts/axelera_brownout_guard.sh           ← PCI vendor 1d60 → 1f9d
scripts/install_uav_phase7.sh               ← PCI vendor 1d60 → 1f9d
scripts/verify_tuning.sh                    ← PCI vendor 1d60 → 1f9d
scripts/install_zed_sdk.sh                  ← drop skip_drivers; use real flags
scripts/install_av_stack.sh                 ← MAVROS install_geographiclib via ros2 run
scripts/install_telemetry_failover.sh       ← FCU TTY, Iridium 9704 model-aware
                                              relay rewrite (JSPR + AT modes)
docs/DRIVERS.md                             ← form factor, ZED X source caveat
docs/UAV_RESILIENCE.md                      ← PCI vendor
README.md                                   ← form factor + PCI ID
docs/VERIFICATION_REPORT.md                 ← THIS FILE
```

Note: `docs/JETSON_AV_PLATFORM_GUIDE.md` was touched by this pass but removed in a later documentation trim, so it no longer exists in the tree.

## Field-confirm checklist

Of the six original field-confirm items, FC-2, FC-3, and FC-4 are CLOSED (2026-06-11); FC-1, FC-5, and FC-6 remain open. [Section 7](#section-7-phase-8-closeout-may-2026) tracks each by its FC-n label.

- **FC-1, `LINK_WAIT_MAX_RETRIES` stock value**: verify in `Linux_for_Tegra/source/kernel/kernel-jammy-src/drivers/pci/controller/dwc/pcie-designware.h` after the extract phase. If NVIDIA already patched it to a sufficient value, the repo's override (`PCIE_LINK_WAIT_MAX_RETRIES=200` in versions.env, for Metis link-training reliability) is harmless but unnecessary.
- **FC-2, `axdevice` exact flag spelling**: CLOSED 2026-06-11: `axdevice --help` on the installed Voyager 1.6.1 runtime lists `--set-power-limit LIMIT` verbatim; `axelera_brownout_guard.sh` is correct as written (see §2.9).
- **FC-3, `AXELERA_GST_EXPLICIT_PARSE=1`**: ✅ CLOSED 2026-06-11: stale, removed (zero references in Voyager 1.6.1; see §2.10).
- **FC-4, Isaac ROS Humble apt package coverage**: CLOSED 2026-06-11: apt coverage confirmed sufficient on the reference device (`ros-humble-isaac-ros-nitros`, `-image-pipeline`, `-visual-slam`, `-nvblox`, `-detectnet` all from the release-3 repo); no source build needed. See [AV_STACK.md](AV_STACK.md) and [FIELD_CONFIRM_RESULTS.md](FIELD_CONFIRM_RESULTS.md) §3.4.
- **FC-5, `/dev/ttyTHS1` enumeration on your carrier**: run `dmesg | grep tty` after flashing to confirm Pixhawk TELEM2 enumerated where expected.
- **FC-6, carrier HV rail and Super Mode** (see §1.10): confirm your carrier's input voltage and DC-DC rating support 40 W sustained before flying with `nvpmodel -m 0` (MAXN_SUPER on this image). MAXN_SUPER is confirmed active on the bench; verify under sustained load with `tegrastats`. This is safety-critical for flight.

## Sources index

NVIDIA:
- https://developer.nvidia.com/embedded/jetson-linux-r3643
- https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/index.html
- https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/SD/FlashingSupport.html
- https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/HR/JetsonModuleAdaptationAndBringUp/JetsonOrinNxNanoSeries.html
- https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/SD/PlatformPowerAndPerformance/PlatformPowerAndPerformance.html
- https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/SD/Clocks.html
- https://developer.nvidia.com/cuda/gpus
- https://developer.nvidia.com/downloads/jetson-orin-nx-module-series-data-sheet

Stereolabs:
- https://www.stereolabs.com/developers/drivers
- https://www.stereolabs.com/docs/embedded/zed-link/install-the-drivers
- https://www.stereolabs.com/developers/release
- https://www.stereolabs.com/docs/development/zed-sdk/jetson
- https://github.com/orgs/stereolabs/repositories
- https://github.com/stereolabs/zed-python-api

Axelera:
- https://github.com/axelera-ai-hub/voyager-sdk
- https://community.axelera.ai/product-updates/voyager-sdk-new-pipeline-builder-and-more-1313
- https://community.axelera.ai/metis-pcie-7/axelera-metis-pcie-ai-accelerator-not-recognized-by-lspci-145
- https://axelera.ai/ai-accelerators/metis-m2-ai-acceleration-card
- https://axelera.ai/hubfs/Axelera_February2025/pdfs/axelera-ai-m2-ai-edge-accelerator-module.pdf

PX4 companion computer docs: https://docs.px4.io/main/en/companion_computer/

MAVLink / MAVROS / mavlink-router:
- https://mavlink.io/en/messages/common.html
- https://mavlink.io/en/services/mavlink_id_assignment.html
- https://github.com/mavlink/mavros/blob/ros2/mavros/README.md
- https://github.com/mavlink-router/mavlink-router/blob/master/examples/config.sample

Rock7 / GroundControl (Iridium):
- https://docs.groundcontrol.com/iot/rockblock-9704/hardware
- https://docs.groundcontrol.com/iot/rockblock-9704/intro
- https://github.com/rock7/RockBLOCK-9704
- https://docs.groundcontrol.com/iot/rockblock/user-manual/at-commands

ROS 2 / Isaac ROS / Nav2 / FastDDS:
- https://nvidia-isaac-ros.github.io/getting_started/index.html
- https://github.com/NVIDIA-ISAAC-ROS/isaac_ros_common
- https://github.com/ros-navigation/navigation2/tree/humble/nav2_bringup
- https://docs.ros.org/en/humble/p/rosbag2_storage_mcap/
- https://fast-dds.docs.eprosima.com/en/latest/fastdds/discovery/simple.html

Linux kernel (5.15):
- https://raw.githubusercontent.com/torvalds/linux/v5.15/<Kconfig path>

---

## Section 7, Phase 8 closeout (May 2026)

This section marks items from earlier sections as closed once the Phase 8 runbook procedures run on hardware. The "Pending FC-n" labels map to the field-confirm checklist above and to the per-unit result slots in [FIELD_CONFIRM_RESULTS.md](FIELD_CONFIRM_RESULTS.md).

| VR item | Description | Status |
|---|---|---|
| §1.1 | `-super` board target paragraph | CLOSED: [index.md](index.md) rewritten to separate flash config from the nvpmodel unlock; P-number map and P3509 carrier explanation added |
| §1.9 | `LINK_WAIT_MAX_RETRIES` pre-patch value | Pending FC-1 |
| §1.10 | Carrier HV rail and MAXN_SUPER capability | Pending FC-6 |
| §2.9 | `axdevice` power-limit flag spelling | CLOSED 2026-06-11: `--set-power-limit` confirmed on the installed Voyager 1.6.1 runtime |
| §2.10 | `AXELERA_GST_EXPLICIT_PARSE` env var | CLOSED 2026-06-11: stale, removed |
| §3 | DMABUF zero-copy kernel CONFIG | CLOSED: [DMABUF_ZEROCOPY.md](DMABUF_ZEROCOPY.md) documents the kernel bridge (`axl_dmabuf.c`), tracepoints, GStreamer caps, and the [verify_dmabuf_zerocopy.sh](../scripts/verify_dmabuf_zerocopy.sh) invariant checker |
| §4.1 | `/dev/ttyTHS1` enumeration on carrier | Pending FC-5 |
| §4.12 | Isaac ROS Humble apt package coverage | CLOSED 2026-06-11: apt coverage confirmed sufficient on the reference device ([FIELD_CONFIRM_RESULTS.md](FIELD_CONFIRM_RESULTS.md) §3.4) |
| §5.2 | APX USB ID `0955:7023` to `0955:7323` | CLOSED: [index.md](index.md) home page updated |
| §5.5 | cuDNN 8 to cuDNN 9.3 (JetPack 6.2.x) | CLOSED: [index.md](index.md) home page updated |

The remaining Pending items (FC-1, FC-5, FC-6) follow the procedures in [FIELD_CONFIRM_RESULTS.md](FIELD_CONFIRM_RESULTS.md); FC-2, FC-3, and FC-4 closed 2026-06-11 on the reference device. Run [verify_dmabuf_zerocopy.sh](../scripts/verify_dmabuf_zerocopy.sh) for DMABUF. Paste results into the `<!-- RESULT: -->` slots in that document.
