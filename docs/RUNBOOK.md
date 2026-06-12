---
title: Runbook
layout: default
description: "Operational decision trees for the repeat operator: re-flash, recovery, debugging failures, and maintaining a production fleet."
nav_order: 4
---

# Runbook

Decision trees for the repeat operator. Each entry (R1 to R18) maps a situation
to the minimum set of commands that resolves it. For your first build, follow
[Quickstart]({{ '/QUICKSTART' | relative_url }}) end to end. To take a fresh
flash to the **complete verified AV stack** (CUDA, ZED X, Metis inference),
follow **R18**. For symptom-driven debugging, see
[Troubleshooting]({{ '/TROUBLESHOOTING' | relative_url }}).

Scaling past one unit (the build-once, flash-N workflow the community post
points here for): **R10** reuses one build across devices, **R13** produces a
signed release tarball and batch-flashes from `fleet.csv`, and **R16** clones
a fully provisioned golden unit with per-device identity. Full guides:
[Fleet]({{ '/FLEET' | relative_url }}) and
[Golden Image]({{ '/GOLDEN_IMAGE' | relative_url }}).

This runbook targets a Jetson Orin NX 16GB (p3767-0000 module on a p3768 Orin
Nano carrier) running L4T R36.4.3 / JetPack 6.2 with a PREEMPT_RT kernel, an
NVMe root on `/dev/nvme0n1p1`, the Axelera Metis NPU, and the ZED X camera
overlay.

---

## R1: Flash a brand-new Jetson

```
make doctor          # 30 s, abort here on any FAIL
make ignite-no-flash # 60 to 90 min, produces a clean, audited image
                     # Now plug the Jetson in recovery mode.
make flash           # 15 to 25 min
                     # Wait for boot; first-boot service runs ~3 to 5 min then reboots.
make verify          # post-flash gauntlet
```

Note on `make verify`: the first-boot service provisions the `/opt/av-env`
Python environment only when the device has internet. After an offline first
boot the service re-runs on every boot and finishes provisioning once a
network is available (for example, an Ethernet cable); until then the
venv-import step of `make verify` fails, which is expected.

Judging boot: a blank HDMI screen or a boot logo frozen on its last square is
normal on Orin and proves nothing. Judge boot health by the USB gadget
instead: wait for `lsusb` to show 0955:7020, then `ping 192.168.55.1`, then
ssh. A healthy boot reaches sshd in about 60 seconds.

Or run the full interactive sequence:

```bash
make ignite          # doctor -> all -> audit -> flash (interactive) -> verify
```

---

## R2: Changed a CONFIG flag, minimum rebuild?

```
Did you change LOCALVERSION, PREEMPT_RT, MODVERSIONS, or anything that
changes UTS_RELEASE or vermagic constituents?
   yes -> full rebuild path: make clean && make all && make audit && make flash
   no  -> try the partial path:
         make extract             # idempotent, only re-applies changed patches
         make build               # rebuilds kernel + all modules + headers .deb
         make bake                # restages payloads
         make audit               # confirms gates still green
         make flash               # write
```

Always end with `make verify` after the flash completes.

---

## R3: Changed a kernel patch, minimum rebuild?

```bash
# Edit scripts/01_extract_and_patch.sh or KERNEL_PATCHES.md instructions
make clean         # most reliable, patches are not always reversible
make all && make audit
# ... recovery mode ...
make flash && make verify
```

Skipping `make clean` after a patch change risks Phase 1 silently no-op'ing
because of its idempotency guards.

---

## R4: Audit failed

[scripts/pre_flash_audit.sh](../scripts/pre_flash_audit.sh) prints which check
FAILed. Decode it:

| Failed check | Most likely cause | Fix |
|---|---|---|
| Version string | Phase 2 ran with wrong LOCALVERSION | rebuild Phase 2 |
| Real-time core | PREEMPT_RT not active in built kernel | check defconfig, run `generic_rt_build.sh enable`, rebuild |
| DMABUF heaps | CONFIG_DMABUF_HEAPS=y missing | check that defconfig injection ran in Phase 1 |
| PCIe retries | LINK_WAIT_MAX_RETRIES != 200 | re-run Phase 1 (the patch forces 200, pinned in versions.env) |
| CPU isolation | extlinux.conf missing isolcpus | re-run `make bake` |
| Tickless mode | extlinux.conf missing nohz_full | re-run `make bake` |
| CMA policy | extlinux.conf contains a cma= boot arg (it must not; the device tree linux,cma pool supplies CMA) | remove the cma= arg, re-run `make bake` |
| ZED X overlay | DTBO missing in `/boot/` | re-run Phase 2 (the DTBO compile is in 02_build_kernel.sh) |
| Module vermagic | At least one .ko has the wrong vermagic | `make clean && make all` (never partial) |

After fixing, re-run `make audit`. If it stays red, gather logs (`make logs`)
and consult [Troubleshooting]({{ '/TROUBLESHOOTING' | relative_url }}) §B.

---

## R5: Flash hangs

Work the tree top to bottom:

```
1. lsusb -t
   - Jetson on a hub or extender? -> move to a direct motherboard port.
   - Multiple USB devices on same controller? -> unplug others.

2. lsusb | grep 0955
   - Nothing? -> Jetson is not in recovery mode. Power off, re-short
     REC+GND, re-power.
   - Shows 0955:7323? -> recovery OK; the flash should be progressing.

3. ip link show
   - Look for usb0. If absent, the RNDIS gadget did not enumerate on
     the host. Check dmesg for the rndis_host module loading.
   - sudo modprobe rndis_host
   - sudo udevadm control --reload-rules

4. sudo dmesg -w  (in another terminal)
   - Watch for USB enumeration and disconnect events.

5. Verify USB autosuspend is off:
   sudo sh -c 'echo -1 > /sys/module/usbcore/parameters/autosuspend'
   sudo sh -c 'echo 200 > /sys/module/usbcore/parameters/usbfs_memory_mb'

6. Re-run: make flash
```

If it is still stuck, run `make logs` and see
[Troubleshooting]({{ '/TROUBLESHOOTING' | relative_url }}) §F.

---

## R6: Jetson boots but verify_tuning shows FAILs

[scripts/verify_tuning.sh](../scripts/verify_tuning.sh) reports each check.
Common patterns:

```
RT Kernel: FAIL
   -> Boot landed on the stock kernel. Likely the wrong kernel image was
      written, or extlinux.conf points at the wrong label. SSH in and check
      the default label in /boot/extlinux/extlinux.conf.

CPU Isolation: FAIL
   -> extlinux.conf is missing isolcpus. The first-boot script may have
      failed before the inject step. Run it manually:
        sudo /home/j/jetson_first_boot.sh
        sudo reboot

CMA Reservation: FAIL
   -> The verified-good state is CmaTotal=262144 kB (256MB), supplied by the
      device tree linux,cma pool. There must be NO cma= arg on the cmdline:
      a cmdline cma= bypasses the device tree pool, and large values fail to
      reserve on Orin NX ("cma: Failed to reserve 2048 MiB"), leaving zero
      CMA. With zero CMA, nvgpu cannot make its 64MB physically-contiguous
      comptag allocation at GPU poweron ("DMA alloc FAILED"), GR falcon
      recovery fails, CUDA is unavailable, and nvpmodel cannot set any
      power mode.
      - grep CmaTotal /proc/meminfo   expect 262144 kB
      - cat /proc/cmdline             must contain no cma= arg
      - dmesg | grep -i cma           any "Failed to reserve" means a cma=
                                      arg slipped in
      If a cma= arg is present, remove it from /boot/extlinux/extlinux.conf
      and reboot; the device tree pool takes over.

Power Mode: FAIL
   -> The flash installs the SUPER nvpmodel conf as the default table.
      Verified mode IDs on this image: 0=MAXN_SUPER, 1=10W, 2=15W, 3=25W,
      4=40W. Set the maximum profile with:
        sudo nvpmodel -m 0          # MAXN_SUPER
      rt-tune requests mode 0 on every boot (NVPMODEL_MODE in power.conf
      overrides it). If nvpmodel cannot set ANY mode, it is failing to read
      the GPU frequency table, which means the GPU did not come up: work the
      CMA entry above first.

Axelera Metis: GHOST
   -> The PCIe link failed to train. See KERNEL_PATCHES.md §1.
      Most likely the LINK_WAIT_MAX_RETRIES=200 patch did not apply.

ZED X Driver: MISSING
   -> sl_zedx.ko is not loaded. Check its vermagic:
        modinfo /lib/modules/$(uname -r)/.../sl_zedx.ko | grep vermagic
      If the vermagic does not match $(uname -r), it is a mismatch. Re-flash
      with a fresh build.
```

---

## R7: Vermagic mismatch

Never force-load. Rebuild.

```bash
make clean
make all          # kernel + all modules + headers .deb in one Docker run
make audit        # verify_vermagic.sh --rootfs gates here
make flash
```

Never run `insmod --force`. Never `apt install nvidia-l4t-kernel-modules`.
The `Pin-Priority: -1` in `/etc/apt/preferences.d/99-jetson-av-kernel-lock`
already blocks the latter, but operator discipline is the final defense.

See [Vermagic strategy]({{ '/VERMAGIC_STRATEGY' | relative_url }}).

---

## R8: Install ZED SDK / Voyager SDK after first boot

First boot handles this when the artifacts were staged at bake time and the
device has internet; after an offline first boot the service re-runs each boot
and completes provisioning once a network is available. To install manually on
the target (the pip step requires `/opt/av-env`, which first boot creates
during online provisioning):

```bash
# CUDA userspace first: the flashed image has no JetPack packages and the
# ZED SDK requires CUDA 12.6 (TROUBLESHOOTING P-3)
sudo apt update && sudo apt install nvidia-jetpack

# ZED SDK
ls /opt/zed-sdk/ZED_SDK_Tegra_*.run             # already there?
sudo /opt/zed-sdk/install_zed_sdk.sh            # idempotent

# Voyager SDK (pip wheels, not install.sh). torch==2.8.0 is restated as a
# constraint: without it pip "upgrades" the cu126 wheel to PyPI's CPU-only
# torch (TROUBLESHOOTING P-2)
sudo /opt/av-env/bin/pip install axelera-rt axelera-devkit torch==2.8.0 \
    --extra-index-url https://software.axelera.ai/artifactory/api/pypi/axelera-pypi/simple
```

Both depend on the linux-headers .deb being installed (handled by first boot).
Confirm with `dpkg -l | grep linux-headers`.

---

## R9: OTA update overwrote the kernel

If `apt upgrade` proposes `nvidia-l4t-kernel*`, decline it. First boot pins
these packages at `Pin-Priority: -1`.

If it ran anyway:

```bash
# Confirm the damage
uname -r              # expect 5.15.x-tegra
                      # if it is anything else, the kernel is stock again

# Recovery: re-flash from a fresh build
make clean && make all && make audit && make flash
```

There is no in-place repair. The module ABI is ruined the moment a stock
kernel boots.

---

## R10: Fleet-deploy multiple Jetsons

Build once, then reuse `latest_jetson/` for each subsequent flash:

```bash
# Build once (or pull a pre-built artifact from CI)
make doctor
make all        # produces deterministic artifacts (SOURCE_DATE_EPOCH locked)
make audit

# Per device: put each Jetson in recovery mode, then
make flash      # rewrites the same image
make verify     # confirm
```

To validate that two builds are byte-identical (fleet QA):

```bash
sha256sum latest_jetson/Linux_for_Tegra/kernel/Image
sha256sum latest_jetson/Linux_for_Tegra/staging/kernel-headers/linux-headers-*.deb
sha256sum latest_jetson/Linux_for_Tegra/kernel/dtb/*.dtbo
```

See [Build]({{ '/BUILD' | relative_url }}) for the reproducibility theory.

---

## R11: Bundle logs for a support request

```bash
make logs
```

Produces `support-bundle-YYYYMMDD-HHMMSS.tar.gz` containing:

- `BUILD_LOG.md`, `FLASH_LOG.txt`, `IGNITION_*.log`
- `EXPECTED_VERMAGIC`, `BUILD_MANIFEST.json`
- the staged defconfig and extlinux.conf
- a vermagic snapshot (`vermagic-rootfs.txt`)
- if the target is reachable: `target-uname.txt`, `target-dmesg-err.txt`,
  `target-journal-{first-boot,rt-tune}.txt`, `target-hardware.txt`,
  `target-vermagic.txt`

Attach the tarball to your support ticket.

---

## R12: Check pinned versions

```bash
make versions
```

Reads [versions.env](../versions.env) and prints every pinned version, URL,
USB ID, and RT tuning value. It also prints the last-build vermagic and
manifest if a build has run.

---

## R13: Release tarball + batch flash N units

```bash
make doctor                        # preflight
make all && make audit             # build + gate

GPG_KEY=YOUR_KEY make release VERSION=v1.0.0   # signed release tarball
                                               # -> releases/release-v1.0.0.tar.gz

# On the flash station(s):
make fleet-init                    # creates fleet.csv from the example
$EDITOR fleet.csv                  # add device labels + hostnames + IPs
make flash-batch FLEET=fleet.csv   # iterates devices; per-device PASS/FAIL log

make fleet-status                  # summarize fleet_log.csv
```

The full workflow is in [Fleet]({{ '/FLEET' | relative_url }}).

---

## R14: Verify resilience layer

```bash
ssh j@av-07 << 'EOF'
    systemctl is-active systemd-journald jetson-blackbox.service \
                       jetson-brownout-guard.service tmp.mount
    cat /etc/jetson-av-resilience-installed
    journalctl --disk-usage
    chronyc tracking | head -3
    sudo ufw status verbose
    ls /var/log/jetson-av/flights/
EOF
```

The resilience layer's core services are verified live on the reference device
(2026-06-11): `jetson-blackbox`, `jetson-brownout-guard`, and
`jetson-av-pcie-aer-monitor` all active, btrfs data partition mounted with the
weekly scrub timer (see SAMPLES.md §5). Every line should report a healthy
state. The post-flash validator (`make verify`) runs most of these
automatically.

Force a black-box flush before powering off (for example, when aborting a
flight):

```bash
ssh j@av-07 'sudo kill -USR1 $(systemctl show jetson-blackbox -p MainPID --value)'
```

Full guide in [Platform Resilience]({{ '/UAV_RESILIENCE' | relative_url }}) and
[Black Box]({{ '/BLACKBOX' | relative_url }}).

---

## R15: Verify AV stack (GPU / Metis / DLA)

Status: the Phase 5 stack (CUDA userspace, ROS 2, Isaac ROS, the mission
service) is installed and verified live on the reference device (2026-06-11):
`verify_opengl_cuda.sh` 14/14, ZED X capture at 29.5 FPS, live Metis inference
at 49.2 FPS (29.6 camera-limited), full mission graph active under systemd.
See R18. To check a unit:

```bash
ssh j@av-07 'jetson-av-version'                            # build identity
ssh j@av-07 'sudo /home/j/phase5/verify_opengl_cuda.sh'   # CUDA stack
ssh j@av-07 'ros2 pkg list | grep -E "isaac_ros|nav2"'
ssh j@av-07 'sudo /usr/local/bin/launch_av_mission.sh --dry-run'
```

To start the mission:

```bash
ssh j@av-07 'sudo systemctl start jetson-av-mission.service'
ssh j@av-07 'systemctl status "jetson-av-*"'
```

Inspect it at runtime:

```bash
ssh j@av-07 'ros2 topic hz /zed/zed_node/rgb/color/rect/image'   # camera
ssh j@av-07 'ros2 topic hz /detections'                          # Metis
ssh j@av-07 'ros2 topic echo /vslam/pose --once'                 # SLAM
```

Full guide in [AV Stack]({{ '/AV_STACK' | relative_url }}) and
[CUDA Libraries]({{ '/CUDA_LIBS' | relative_url }}); measured throughput for
every camera + Metis configuration is in
[Benchmarks]({{ '/BENCHMARKS' | relative_url }}).

---

## R16: Clone a configured Jetson to N units

Flash one unit with `make ignite`, install apps, ROS packages, and models,
then validate it. From that golden unit:

```bash
# On Jetson #0 (the golden), boot, install everything, validate.
# Then power off, put it in APX recovery mode, and from the host:

make clone-golden TAG=v1.0-bench-validated
# -> golden-images/golden-v1.0-bench-validated-<timestamp>/

make list-goldens                                 # confirm

# For each receiving Jetson (in recovery mode each time):
make flash-golden GOLDEN=golden-v1.0-bench-validated-<ts> DEVICE=av-07
make verify
```

Every clone runs `personalize_first_boot.sh` at first boot, which sets a
unique hostname, fresh SSH host keys, and an optional static IP. The result is
bit-identical at flash time and divergent in identity at boot.

Full guide in [Golden Image]({{ '/GOLDEN_IMAGE' | relative_url }}).

---

## R17: Audit step manifest

`logs/STEP_MANIFEST.tsv` records every step. To query it:

```bash
column -t -s$'\t' logs/STEP_MANIFEST.tsv | tail -50

# Just the failures:
awk -F$'\t' '$4!="PASS" && $4!="SKIPPED" && NR>1' logs/STEP_MANIFEST.tsv

# Time spent per phase:
awk -F$'\t' 'NR>1 {s[$3]+=$5} END {for (p in s) printf "  %-12s %ds\n", p, s[p]}' \
    logs/STEP_MANIFEST.tsv
```

Per-step logs are at `logs/<timestamp>_<slug>.log` and are bundled by
`make logs`. See [Verification]({{ '/VERIFICATION' | relative_url }}).

---

## R18: Full AV stack on a fresh flash (the complete replication sequence)

The end-to-end sequence that takes a freshly flashed unit to a **verified
working stack**: CUDA, OpenCV-CUDA, ZED X capture (sharp, with IMU), ROS 2 +
Isaac ROS, and live Metis inference. Every step and trap below was verified
live on the reference device 2026-06-10/11. Run on the Jetson, in this order;
each stage gates the next.

**Stage 0: prerequisites.** Flash per R1. First boot must complete online
(`/opt/av-env` provisioned, marker `~/.jetson_initialized` present). For the
camera, the `zedx-driver` vendor tree must be available, either staged at
`/opt/zedx-daemons/vendor` by the bake (images built after 2026-06-11) or
cloned to `~/zedx-driver` on the device.

**Stage 1: CUDA userspace (~15 min, ~3.8 GB).** The sample rootfs ships *no*
JetPack packages ([Troubleshooting]({{ '/TROUBLESHOOTING' | relative_url }}) P-3):

```bash
sudo apt update && sudo apt install -y nvidia-jetpack
/usr/local/cuda/bin/nvcc --version            # CUDA 12.6
/opt/av-env/bin/python -c "import torch; print(torch.cuda.is_available())"  # True
```

If torch prints `False` or a `+cpu` version, repair per P-2.

**Stage 2, Phase 5: OpenCV-CUDA + ROS 2 + Isaac ROS + mission service
(~70 min first unit, minutes thereafter via /opt/opencv-cache).**

```bash
cd ~/Documents/jetson-rt-stack          # or wherever the repo is checked out
sudo bash scripts/install_av_phase5.sh
/opt/av-env/bin/python -c "import cv2; print(cv2.cuda.getCudaEnabledDeviceCount())"  # 1
ros2 pkg list | grep -cE 'isaac_ros|nav2|mavros'   # > 25
```

Isaac ROS installs from NVIDIA's apt repo (added automatically); no source
build needed (FIELD_CONFIRM 3.4).

**Stage 3: ZED X camera (~10 min; ~2 min with the daemon cache).**

```bash
sudo bash scripts/install_zedx_daemons.sh    # or /opt/zedx-daemons/install_zedx_daemons.sh
sg zed -c '/opt/av-env/bin/python -c "
import pyzed.sl as sl
c = sl.Camera(); p = sl.InitParameters(); print(c.open(p))"'   # SUCCESS
```

Installs the BMI088/SPSC IMU modules, the three vendor daemons, the udev
rule, and the patched `libnvisppg.so` (sharp image). Re-login (or use
`sg zed`) after the script adds you to the `zed` group. Details:
[Drivers]({{ '/DRIVERS' | relative_url }}) §1.4-1.5.

**Stage 3b: mission camera + detect node (~20 min first unit).**

```bash
sudo bash scripts/install_zed_ros2_wrapper.sh    # colcon-builds wrapper v5.3.1 at /opt/zed_ros_ws
sudo bash scripts/install_mission_inference.sh   # models -> /opt/jetson-av/models, detect node, SLAM wiring
```

(Both run automatically as Phase 5 steps 3b/3c on fresh installs.) Note the
wrapper >= 5.1 topic rename: consumers use
`/zed/zed_node/rgb/color/rect/image` ([Troubleshooting]({{ '/TROUBLESHOOTING' | relative_url }}) H-8).

**Stage 4: Voyager inference (~25 min first model, then cached).**
Follow [AV stack]({{ '/AV_STACK' | relative_url }}) §"Voyager inference:
verified procedure": install the app deps (minus `opencv-python`/`pyopencl`),
`make operators` (needs `ninja-build opencl-headers ocl-icd-opencl-dev
libsimde-dev`), then:

```bash
cd ~/voyager-sdk
GST_PLUGIN_FEATURE_RANK=nvv4l2decoder:NONE PYTHONPATH=$PWD DISPLAY=:0 \
  /opt/av-env/bin/python inference.py yolov5s-v7-coco media/h264/traffic1_1080p.mp4
# expected: ~49 FPS end-to-end, <15% CPU
DISPLAY=:0 PYTHONPATH=$PWD sg zed -c \
  "/opt/av-env/bin/python ~/Documents/jetson-rt-stack/scripts/demo_zedx_metis.py"
# expected: ~29.6 FPS (camera-limited), live detections on screen
```

For the C++ equivalents on the live camera (detector-only and full sensor
fusion with depth, skeletons, and IMU-fused pose), build per
[ZED X + Metis C++]({{ '/ZEDX_METIS_CPP' | relative_url }}): the fusion sample
keeps every feature at speed via `--depth-every` and records annotated H.264
through NVENC with `--record`. Measured numbers for each configuration, plus
the reproducible harness, are in
[Benchmarks]({{ '/BENCHMARKS' | relative_url }}).

**Stage 5: verify everything.**

```bash
sudo bash scripts/verify_tuning.sh         # RT + vermagic + power gauntlet
sudo bash scripts/verify_opengl_cuda.sh    # 14/14 CUDA/GL/TRT/VPI checks
sudo /usr/local/bin/launch_av_mission.sh --dry-run   # all 6 nodes resolve
```

The cyclictest `<100 µs` gate must be re-run headless (an interactive desktop
session adds ~150 µs IPI spikes; the 3 µs average is unaffected).

**Still operator-provided afterwards**: compiled models +
`/opt/jetson-av/detect_metis.py` under `/opt/jetson-av/`, the `zed_wrapper`
ROS package (source build against the SDK), Pixhawk on `ttyTHS1`, and the
FIELD_CONFIRM §3.6 HV-rail test before any flight on MAXN_SUPER.
