---
title: Field Confirm Results
layout: default
description: "Running log of the six Phase 8 field-confirm items: LINK_WAIT_MAX_RETRIES, axdevice power flag, AXELERA_GST_EXPLICIT_PARSE, Isaac ROS apt coverage, ttyTHS1 enumeration, and the MAXN_SUPER HV rail. Three closed on the bench unit 2026-06-11."
nav_order: 98
---

# Field Confirm Results

This is the running log for the six Phase 8 field-confirm items. Each item is a procedure that runs on real hardware to either prove an assumption or replace it with a measured result. Record one row per item per hardware unit. Status as of 2026-06-11: items 3.2, 3.3, and 3.4 are closed on the bench unit; 3.1, 3.5, and 3.6 (the safety-critical rail test) remain open. When all six pass, drop the "configured, verify on device" caveats from [index.md](index.md) and the [Verification Report](VERIFICATION_REPORT.md). If a procedure fails in an unexpected way, debug it through the symptom catalog in [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## How to use this log

1. Run the procedure for an item on the target board.
2. Compare the output against the pass criteria in that item's section.
3. Fill in the row in the [results table](#results-table) and replace the `<!-- RESULT: -->` placeholder in the item's section with the date, unit serial, and outcome.
4. Apply the follow-up action the item specifies (keep, remove, or change a setting).

## Device baseline, verified 2026-06-10

Live verification on the bench Orin NX (NVMe rootfs) established the platform baseline these items run on. This section is a dated snapshot of that first session; where a later run superseded a bullet, the bullet says so:

- PREEMPT_RT kernel 5.15.148-tegra with `/sys/kernel/realtime` = 1, boot to sshd in about 60 seconds, GUI desktop session on :0 with gdm3 autologin (user `j`).
- GPU kernel side fully healthy after the CMA fix: no `cma=` boot arg (the device tree `linux,cma` pool provides 256 MB, CmaTotal = 262144 kB), zero nvgpu errors across the boot, GPU devfreq present, `/dev/nvgpu/igpu0` nodes present, GPU at 918 MHz.
- Power: MAXN_SUPER active ("NV Power Mode: MAXN_SUPER", CPU at 1.98 GHz on all cores, EMC locked at max). This image installs the SUPER nvpmodel table: 0 = MAXN_SUPER, 1 = 10W, 2 = 15W, 3 = 25W, 4 = 40W.
- Metis NPU enumerated on PCIe (1f9d:1100) with `metis.ko` loaded.
- Camera: staged-only as of 2026-06-10 (ZED X modules and DT overlay in place, no GMSL camera physically attached). SUPERSEDED 2026-06-11: end-to-end capture verified live, 29.5 FPS stereo plus CUDA depth maps (see [VERIFICATION_REPORT.md](VERIFICATION_REPORT.md)).
- CUDA userspace: untested as of 2026-06-10 (the first boot ran offline, so `/opt/av-env` provisioning had not run; the GPU kernel side was clean). SUPERSEDED 2026-06-11: `/opt/av-env` is provisioned (PyTorch cu126, Voyager 1.6.1) and `verify_opengl_cuda.sh` passes 14/14.

Throughput on this baseline (the C++ samples, fusion with the `--depth-every` cadence, GPU load, power, thermals) is characterized with the reproducible harness in [BENCHMARKS.md](BENCHMARKS.md).

## Results table

| Item | Unit serial | Date | Result | Notes |
|---|---|---|---|---|
| [3.1 LINK_WAIT_MAX_RETRIES](#31-link_wait_max_retries-stock-value) | | | pending | |
| [3.2 axdevice power flag](#32-axdevice-power-flag-spelling) | bench Orin NX | 2026-06-10 | blocked | `/opt/av-env` not provisioned (first boot ran offline). |
| [3.2 axdevice power flag](#32-axdevice-power-flag-spelling) | bench Orin NX | 2026-06-11 | confirmed | Voyager 1.6.1 `axdevice --help` lists `--set-power-limit LIMIT`; brownout guard correct as written. |
| [3.3 AXELERA_GST_EXPLICIT_PARSE](#33-axelera_gst_explicit_parse) | bench Orin NX | 2026-06-10 | blocked | `/opt/av-env` not provisioned (first boot ran offline). |
| [3.3 AXELERA_GST_EXPLICIT_PARSE](#33-axelera_gst_explicit_parse) | bench Orin NX | 2026-06-11 | stale, removed | Zero references in Voyager 1.6.1 source/wheels; export removed from jetson_first_boot.sh. |
| [3.4 Isaac ROS apt coverage](#34-isaac-ros-humble-apt-coverage) | bench Orin NX | 2026-06-10 | blocked | Needs network; first boot ran offline. |
| [3.4 Isaac ROS apt coverage](#34-isaac-ros-humble-apt-coverage) | bench Orin NX | 2026-06-11 | confirmed | apt repo (release-3, jammy) covers nitros/image_pipeline/visual_slam/nvblox/detectnet; no source build needed. |
| [3.5 ttyTHS1 enumeration + MAVROS](#35-devttyths1-enumeration) | | | pending | |
| [3.6 HV rail + MAXN_SUPER](#36-hv-rail--maxn_super-safety-critical) | bench Orin NX | 2026-06-10 | partial | MAXN_SUPER (mode 0) confirmed active; sustained-load rail test not yet run. |

## 3.1 LINK_WAIT_MAX_RETRIES stock value

**Item**: Confirm the pre-patch value of `LINK_WAIT_MAX_RETRIES` in the L4T 5.15 kernel tree, so we know whether the PCIe patience patch in [plugins/axelera/plugin.sh](../plugins/axelera/plugin.sh) is changing the value or only confirming it.

The project pins this value to `PCIE_LINK_WAIT_MAX_RETRIES` in [versions.env](../versions.env) and forces it into the header with a `sed`, regardless of what the stock tree contains. [scripts/pre_flash_audit.sh](../scripts/pre_flash_audit.sh) compares the header against the pinned value and aborts on a mismatch.

```bash
F=Linux_for_Tegra/source/kernel/kernel-jammy-src/drivers/pci/controller/dwc/pcie-designware.h
grep -n LINK_WAIT_MAX_RETRIES "$F"
```

| Stock value | Action |
|---|---|
| `#define LINK_WAIT_MAX_RETRIES  10` | Mainline default. The patch raises it to the pinned value. **Pass, keep patch.** |
| `#define LINK_WAIT_MAX_RETRIES  <pinned value>` | NVIDIA already patched it to our target. The `sed` is idempotent. **Pass, annotate in [KERNEL_PATCHES.md](KERNEL_PATCHES.md).** |
| Any other value | Document the divergence and reconsider the pinned value against NVIDIA's choice. **Action, review.** |

The pinned value of 200 exists for Metis PCIe link-training reliability. Record here which value the header carries after Phase 1.

Log: `/var/log/jetson-rt-stack/field-confirm/link-wait-retries-<ts>.log`

<!-- RESULT: -->

## 3.2 axdevice power-flag spelling

**Item**: Confirm the exact flag the Voyager 1.6 `axdevice` CLI uses to set the Metis power limit. [scripts/axelera_brownout_guard.sh](../scripts/axelera_brownout_guard.sh) currently calls `axdevice --set-power-limit <watts>`; this item verifies that flag against the installed runtime.

The Voyager runtime is a separate on-device install, so run this on the board after the Voyager SDK is installed. Activate the AV Python environment that the first-boot service creates ([scripts/jetson_first_boot.sh](../scripts/jetson_first_boot.sh) writes it to `/opt/av-env`):

```bash
source /opt/av-env/bin/activate
axdevice --help 2>&1 | tee /var/log/jetson-rt-stack/field-confirm/axdevice-help-$(date +%s).log
```

Expected: one of `--set-power-limit`, `--power-limit`, or `--power-cap`.

**Action**: if the observed flag differs from `--set-power-limit`, update [scripts/axelera_brownout_guard.sh](../scripts/axelera_brownout_guard.sh) to match. If `axdevice` exposes no power-related flag, file a report at [community.axelera.ai](https://community.axelera.ai) and switch the guard to read `/sys/class/powercap/` instead.

**Result (2026-06-10, bench Orin NX)**: blocked. The first boot ran offline, so `/opt/av-env` provisioning has not run and the Voyager runtime is not installed. The Metis NPU itself is healthy (enumerated as 1f9d:1100, `metis.ko` loaded). Re-run once the AV environment is provisioned.

**Result (2026-06-11, bench Orin NX): CONFIRMED.** Voyager 1.6.1 `axdevice --help` lists `--set-power-limit LIMIT` verbatim. [scripts/axelera_brownout_guard.sh](../scripts/axelera_brownout_guard.sh) is correct as written, no change needed. Live inference verified the same day: YOLOv5s-v7-coco at 49.2 FPS end-to-end on a 1080p video and 29.6 FPS (camera-limited) on the live ZED X feed, 13.7% CPU. See [AV_STACK.md](AV_STACK.md) for the working procedure.

## 3.3 AXELERA_GST_EXPLICIT_PARSE

**Item**: Confirm or remove `AXELERA_GST_EXPLICIT_PARSE=1`. [scripts/jetson_first_boot.sh](../scripts/jetson_first_boot.sh) appends this export to the AV environment's activate script (`/opt/av-env/bin/activate`); this item decides whether the variable still does anything.

First check whether the Voyager source mentions the variable, then compare a pipeline's negotiated caps with the variable set versus unset:

```bash
grep -rn AXELERA_GST_EXPLICIT_PARSE /opt/axelera /opt/av-env 2>/dev/null

unset AXELERA_GST_EXPLICIT_PARSE
gst-launch-1.0 -v <pipeline> 2>&1 | tee /tmp/gst-without.log
export AXELERA_GST_EXPLICIT_PARSE=1
gst-launch-1.0 -v <pipeline> 2>&1 | tee /tmp/gst-with.log
diff /tmp/gst-without.log /tmp/gst-with.log
```

| Result | Action |
|---|---|
| Found in Voyager source with an explanatory comment | Document in [DRIVERS.md](DRIVERS.md) 2.10 and keep. |
| No source mention and no caps diff | Remove the export from [scripts/jetson_first_boot.sh](../scripts/jetson_first_boot.sh). It is stale. |
| No source mention but a real caps diff | Open an Axelera support ticket with the diff and keep the export with a TODO. |

**Result (2026-06-10, bench Orin NX)**: blocked. `/opt/av-env` provisioning has not run (first boot was offline), so neither the activate script nor the Voyager source is on the device yet. Re-run once the AV environment is provisioned.

**Result (2026-06-11, bench Orin NX): STALE, removed.** `grep -rn AXELERA_GST_EXPLICIT_PARSE` over the full voyager-sdk checkout AND the installed 1.6.1 wheels returns zero hits. Nothing references the variable, so it can do nothing. Per the decision table above, the export was removed from [scripts/jetson_first_boot.sh](../scripts/jetson_first_boot.sh). Inference runs fine without it; the decode fix that IS needed on Jetson is `GST_PLUGIN_FEATURE_RANK=nvv4l2decoder:NONE` (see [AV_STACK.md](AV_STACK.md)).

## 3.4 Isaac ROS Humble apt coverage

**Item**: Confirm whether the `ros-humble-isaac-ros-*` apt packages cover everything the stack needs, or whether the source build in [scripts/install_av_stack.sh](../scripts/install_av_stack.sh) is mandatory.

```bash
sudo apt update
apt-cache search ros-humble-isaac-ros | sort | tee \
    /var/log/jetson-rt-stack/field-confirm/isaac-ros-humble-apt-$(date +%s).log

diff <(apt-cache search ros-humble-isaac-ros | awk '{print $1}' | sort) \
     <(grep -oE 'isaac_ros_[a-z_]+' scripts/install_av_stack.sh | sort -u)
```

| Coverage | Action |
|---|---|
| All required packages available in apt | Switch [scripts/install_av_stack.sh](../scripts/install_av_stack.sh) to the apt path. This saves roughly 30 minutes of install time per unit. |
| Partial | Keep the source build and document in [AV_STACK.md](AV_STACK.md) which packages come from apt and which from source. |
| None | Stay on the full source build and revisit for Isaac ROS 4.x / Jazzy. |

**Result (2026-06-10, bench Orin NX)**: blocked. The first boot ran offline, so apt has not been reachable from the device. Re-run once the board has network access.

**Result (2026-06-11, bench Orin NX): CONFIRMED.** The apt repo (`isaac.download.nvidia.com/isaac-ros/release-3`, jammy) covers everything the stack needs: `ros-humble-isaac-ros-nitros`, `-image-pipeline`, `-visual-slam`, `-nvblox`, and `-detectnet` all install from apt, no source build needed (note the package is `-detectnet`; an `-object-detection` meta-package does not exist in the 3.x repo). Per the decision table above, this is the "all required packages available in apt" outcome: [scripts/install_av_stack.sh](../scripts/install_av_stack.sh) takes the apt path, with the colcon source build kept only as a fallback. See [AV_STACK.md](AV_STACK.md).

## 3.5 /dev/ttyTHS1 enumeration

**Item**: Confirm `/dev/ttyTHS1` enumerates after flash and that the Pixhawk TELEM2 link talks on it. The default port is pinned to `FCU_TTY_DEFAULT` in [versions.env](../versions.env).

```bash
dmesg | grep -E 'tty(THS|S)' | tee \
    /var/log/jetson-rt-stack/field-confirm/tty-enum-$(date +%s).log

sudo stty -F /dev/ttyTHS1 921600 raw -echo
sudo timeout 3 cat /dev/ttyTHS1 | xxd | head -50
# Expected: MAVLink magic byte 0xfd (MAVLink 2) or 0xfe (MAVLink 1) at a regular cadence

ros2 launch mavros apm.launch fcu_url:=/dev/ttyTHS1:921600 &
sleep 8
ros2 topic echo /mavros/state --once
# Expected: connected: true
```

**Pass criteria**: `/dev/ttyTHS1` enumerates AND `/mavros/state` reports `connected: true`.

If the FCU enumerates at a different `ttyTHS*` index, update `FCU_TTY_DEFAULT` in [versions.env](../versions.env) and add a row to the carrier compatibility table in [index.md](index.md).

<!-- RESULT: -->

## 3.6 HV rail + MAXN_SUPER, safety-critical

**Item**: Confirm the carrier's HV DC-in rail sustains the MAXN_SUPER profile (uncapped, above the fixed 40 W mode) without brownout or thermal shutdown. **Do not enable Super Mode for flight until this passes.**

**Pre-flight setup**: bench only, active cooling confirmed, 12 V bench supply current-limited at 5 A, multimeter on V_IN and the 5V rail.

The board ships with MAXN_SUPER as the default profile, set by [scripts/04_flash_nvme.sh](../scripts/04_flash_nvme.sh) (the flash installs the SUPER nvpmodel conf as the default table) and reasserted at boot by [scripts/jetson_rt_tune.sh](../scripts/jetson_rt_tune.sh) (default `NVPMODEL_MODE=0`, overridable in `/etc/jetson-av/power.conf`). The live-verified mode IDs on this image are 0 = MAXN_SUPER, 1 = 10W, 2 = 15W, 3 = 25W, 4 = 40W. This procedure first establishes a 25 W baseline (mode 3) and then steps to MAXN_SUPER under sustained load:

```bash
# Baseline at 25 W (mode 3)
sudo nvpmodel -m 3 && sudo jetson_clocks
tegrastats --interval 1000 > /var/log/jetson-rt-stack/field-confirm/super-baseline-$(date +%s).log &
TS_PID=$!
scripts/run_sustained_load.sh 300
kill $TS_PID

# Step to MAXN_SUPER (mode 0)
sudo nvpmodel --available    # confirm the MAXN_SUPER index on this unit
sudo nvpmodel -m 0 && sudo jetson_clocks
tegrastats --interval 1000 > /var/log/jetson-rt-stack/field-confirm/super-maxn-$(date +%s).log &
TS_PID=$!
scripts/run_sustained_load.sh 600
kill $TS_PID
```

**Pass criteria**:

| Metric | Threshold |
|---|---|
| V_IN minimum during 10 min MAXN_SUPER | at least 10.5 V on a 12 V supply |
| 5V rail minimum | at least 4.85 V |
| tegrastats thermal markers | no `@` suffix (no throttling) |
| Junction temperature peak | at most 85 °C with the carrier's stock thermal solution |
| dmesg | no PCIe link retrains, no nvgpu faults |
| Pixhawk heartbeats | unbroken throughout via TELEM2 |

If any threshold fails, set `NVPMODEL_MODE=3` in `/etc/jetson-av/power.conf` to hold the board at 25 W. If all thresholds pass, keep the default `NVPMODEL_MODE=0` (MAXN_SUPER) and drop the "verify on device" qualifier on the Super Mode line in [index.md](index.md).

**Result (2026-06-10, bench Orin NX)**: partial. MAXN_SUPER (mode 0) is confirmed active on the bench ("NV Power Mode: MAXN_SUPER", CPU at 1.98 GHz on all cores, EMC locked at max) with zero nvgpu faults in dmesg. The sustained-load V_IN and 5V rail measurements have not been run, so the safety-critical pass criteria above remain open. Do not enable Super Mode for flight until they pass.
