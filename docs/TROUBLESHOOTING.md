---
title: Troubleshooting
layout: default
description: "Symptom-first failure catalog: build and vermagic failures, flash and boot hangs, first-boot provisioning traps, and camera/NPU/runtime issues, each as symptom, cause, fix."
nav_order: 5
---

# Troubleshooting

This is a symptom-first failure catalog for the jetson-rt-stack pipeline: building
the PREEMPT_RT kernel, flashing the Jetson Orin NX 16GB to NVMe, and bringing up the
Metis NPU, ZED X camera, and RTL8822CE Wi-Fi on L4T R36.4.3 / JetPack 6.2.

Each entry follows the same shape: **symptom**, then **cause**, then **fix**. Find the
symptom that matches what you see in the index below, then work the fix. Entries are
grouped by phase: build and integration, flashing, vermagic and module loadability,
first-boot provisioning, and hardware.

Related docs: [RUNBOOK.md](RUNBOOK.md) for the happy-path procedures,
[VERIFICATION_REPORT.md](VERIFICATION_REPORT.md) for the audit behind each pinned value,
[SAMPLES.md](SAMPLES.md) for known-good run commands, and [BENCHMARKS.md](BENCHMARKS.md)
for healthy performance baselines.

## Symptom index

**Build & integration**:
[B-1](#b-1-build-fails-with-missing-cross-compiler) cross-compiler missing ·
[B-2](#b-2-make-build-fails-at-bindeb-pkg-stage) `bindeb-pkg` tools missing ·
[B-3](#b-3-vermagic-mismatch-in-the-build-tree-phase-2-fails-the-gate) vermagic gate fails ·
[B-4](#b-4-dtbo-file-empty-0-bytes-or-absent) DTBO empty or absent ·
[B-5](#b-5-zed-x-stereolabs-modules-absent-or-extract-logs-patching-file-null) ZED X modules absent ·
[B-6](#b-6-make-build-fails-on-a-second-run-with-cp-cannot-stat-debianlinux-headers) incremental rebuild fails ·
[B-7](#b-7-cuda-pip-builds-mmcv-get-oom-killed) CUDA build OOM (no swap)

**Flashing & boot**:
[F-1](#f-1-flash-hangs-at-sending-mb1-or-waiting-for-target-to-boot-up) flash hangs ·
[F-2](#f-2-flash-succeeds-but-jetson-doesnt-boot) no boot after flash ·
[F-3](#f-3-apply_binariessh-clobbers-the-custom-kernel-device-boots-stock) device boots stock kernel ·
[F-4](#f-4-frozen-right-after-the-nvidia-logo-kernel-waits-forever-for-root) frozen at NVIDIA logo ·
[F-5](#f-5-blank-hdmi-after-exiting-boot-services-is-normal-not-a-hang) blank HDMI (normal) ·
[F-6](#f-6-custom-rt-kernel-hangs-in-early-boot-but-the-stock-kernel-boots-fine) RT kernel early-boot hang ·
[F-7](#f-7-boot-reaches-the-usb-gadget-ping-works-but-never-reaches-sshd) ping OK but no ssh ·
[F-8](#f-8-nvgpu-unable-to-recover-gr-falcon-no-cuda-nvpmodel-fails-cma) nvgpu falcon errors, no CUDA ·
[F-9](#f-9-rtl8822ce-wi-fi-pcie-link-never-trains-no-wlan0) Wi-Fi PCIe link never trains ·
[F-10](#f-10-never-force-load-a-hardware-probing-driver-from-modules-loadd) modules-load.d boot hang ·
[F-11](#f-11-every-boot-lands-in-recovery-boot-and-drops-to-bash-51) every boot drops to `bash-5.1#` ·
[F-12](#f-12-boot-worked-then-an-in-place-rebuild-mangled-extlinuxconf-multiple-root) in-place rebuild mangled extlinux ·
[F-13](#f-13-anything-plugged-into-usb-c-storms-the-log-and-wedges-the-console) USB-C storms the console ·
[F-14](#f-14-intel-ax210-wi-fi-bring-up-iwlwifi-m2-key-e--pcie-c1) AX210 Wi-Fi bring-up ·
[F-15](#f-15-boot-hangs-in-a-uefi-httppxe-network-boot-loop-usb-eth-dongle) UEFI netboot loop

**Vermagic / module loadability**:
[V-1](#v-1-invalid-module-format-in-dmesg) `Invalid module format` ·
[V-2](#v-2-zed-sdk-install-fails-to-build-sl_zedxko) sl_zedx.ko DKMS build fails ·
[V-3](#v-3-on-target-module-build-fails-scriptsbasicfixdep-exec-format-error) `fixdep: Exec format error` ·
[V-4](#v-4-loaded-modules-look-fine-but-driver-behaves-wrong) loaded module misbehaves

**First-boot / provisioning**:
[P-1](#p-1-phase-5-completes-but-installs-nothing-steprun-command-not-found) Phase 5 installs nothing ·
[P-2](#p-2-torch-in-optav-env-is-cpu-only-2xycpu-torchcudais_available-false) torch is CPU-only ·
[P-3](#p-3-nvcc-not-found-and-zero-cuda--packages-on-a-freshly-flashed-device) `nvcc` missing ·
[P-4](#p-4-opencv-build-deps-fail-nvidia-cuda-toolkit--depends-nvidia-cuda-dev--1151-1ubuntu1) OpenCV apt deps conflict ·
[P-5](#p-5-installer-or-mission-launcher-dies-right-after-step-complete-install-ros-2) ROS setup.bash unbound variable ·
[P-6](#p-6-cv2-import-dies-with-numpycoremultiarray-failed-to-import) cv2 numpy import failure

**Hardware & runtime**:
[H-1](#h-1-lspci-shows-nothing-for-axelera) Metis not in `lspci` ·
[H-2](#h-2-zed-x-frames-appear-but-stereo-depth-is-wrong) stereo depth wrong ·
[H-3](#h-3-cyclictest-reports-max-latency--1-ms) RT latency high ·
[H-4](#h-4-performance-tanks-mid-mission) performance tanks mid-mission ·
[H-5](#h-5-zed-x-works-but-the-image-is-soft--not-crisp) image soft ·
[H-6](#h-6-zed-sdk-camera-motion-sensors-not-detected--no-camera-to-spsc-mappings-found) motion sensors not detected ·
[H-7](#h-7-zed-sdk-suddenly-fails-failed-to-connect-to-daemon-socket) daemon socket lost ·
[H-8](#h-8-slam--detect-node-run-but-receive-no-frames-silent) SLAM/detect get no frames ·
[H-9](#h-9-every-mission-unit-crash-loops-instantly-activating-auto-restart) mission units crash-loop ·
[H-10](#h-10-jtop-crashes-when-opening-the-gpu-tab-keyerror-3d_scaling) jtop GPU tab crash ·
[H-11](#h-11-no-way-to-see-metis-utilization-axmonitor-missing-from-the-pip-installed-runtime) no Metis utilization view ·
[H-12](#h-12-zed-sdk-camera-stream-failed-to-start-after-a-camera-client-is-killed) CAMERA STREAM FAILED TO START ·
[H-13](#h-13-metis-enumerates-in-lspci-but-axl-irq-msi-timeout-floods-dmesg) Metis enumerates but `axl IRQ MSI timeout`

## Build & integration

### B-1. Build fails with missing cross-compiler

- **Symptom**: `aarch64-buildroot-linux-gnu-gcc: command not found`.
- **Cause**: Phase 2 was launched on the host, not inside Docker.
- **Fix**: `make docker-build` once, then `make build` (the Makefile
  routes through Docker automatically when not running inside the
  container).

### B-2. `make build` fails at `bindeb-pkg` stage

- **Symptom**: `make[1]: dpkg-buildpackage: command not found` or similar.
- **Cause**: Headers `.deb` build needs Debian packaging tools.
- **Fix**: Add to `Dockerfile`: `apt-get install -y dpkg-dev fakeroot
  build-essential debhelper`. Already present in the current image; if you
  rebuilt locally without it, run `make docker-build` again.

### B-3. Vermagic mismatch in the build tree (Phase 2 fails the gate)

- **Symptom**: end-of-Phase-2 vermagic gate prints
  `[FAIL] Vermagic mismatches detected`.
- **Cause**: a module was built outside the kernel's `make modules`
  invocation (e.g., a vendor build script that called `make` against the
  wrong KDIR).
- **Fix**: rebuild from clean (`make clean && make extract && make build`).
  Check that the relevant plugin ran (`run_hook post_extract` in
  `01_extract_and_patch.sh`) and registered the driver in-tree via its
  Kconfig+Makefile shim.

### B-4. DTBO file empty (~0 bytes) or absent

- **Symptom**: `pre_flash_audit.sh` reports
  `ZED X Overlay: FAIL (Missing binary in rootfs)`.
- **Cause**: NVIDIA's `kernel-devicetree` build system silently skipped
  the `dtbo-y` target.
- **Fix**: `02_build_kernel.sh` now compiles the overlay directly via
  `cpp -DBUILDOVERLAY ... | dtc -@ -f`. Confirm Phase 2 ran the manual
  compile block (look for `ZED X overlay DTBO compiled` in the log).

### B-5. ZED X (stereolabs) modules absent, or extract logs `patching file null`

- **Symptom**: no `sl_zedx.ko` in the rootfs after `make build`; or `make extract`
  logs `patching file null` for `0006-...stereolabs_compilation_makefile.patch`; or
  the DTBO compile fails with `Utils/camera-clks.dtsi: No such file or directory`.
- **Cause**: three distinct traps the Stereolabs vendor tree springs, all now handled
  by `plugins/zedx/plugin.sh`:
  1. The `0006` patch adds `source/stereolabs/Makefile{,-dkms}` from `/dev/null`;
     `patch -p2` mangles the `/dev/null` source to a file literally named `null` and
     the patch's `src/kernel/stereolabs/` layout doesn't line up with our
     `source/stereolabs/` copy at any `-p` level, so the Makefiles are never created.
  2. The in-tree `zedx-wrapper/` Kbuild shim uses a custom `modules:` target that
     Kbuild's `obj-m` subdir descent never invokes (same trap as `metis-wrapper/`),
     so the modules silently don't build during the in-tree pass.
  3. The overlays `#include "Utils/camera-clks.dtsi"` and `Utils/<sensor>-sl-modes.dtsi`
     relative to their nv-public location, but `Utils/` isn't an overlay file so the
     `*.dtsi` glob copy misses it.
- **Fix** (all automatic now):
  1. `zedx_post_extract` awk-materializes `source/stereolabs/Makefile{,-dkms}` straight
     from the `*compilation_makefile*.patch` body to the correct path.
  2. `02_build_kernel.sh` builds the stereolabs tree as an **external module** (`M=`)
     against the freshly built kernel, exactly like Metis: look for
     `Building ZED X (stereolabs) external module` in the Phase 2 log.
  3. `zedx_post_extract` copies the `Utils/` include tree into nv-public beside the
     overlays.
- Layer 1 (Metis, no camera) is still selectable independently with `CONFIG_CAMERA_NONE=y`.

### B-6. `make build` fails on a second run with `cp: cannot stat .../debian/linux-headers/...`

- **Symptom**: an incremental re-run fails at the `nvidia-headers` target with `cp: cannot stat '.../debian/linux-headers/.../include-prefixes/arm64'`.
- **Cause**: `bindeb-pkg` consumes its own `debian/` staging, so the tree does not rebuild reliably in place.
- **Fix**: always build clean, `make clean && make extract && make build`. Phase 2 runs under `set -eo pipefail`, so a failed compile aborts loudly rather than exiting 0 behind a stale Image.

### B-7. CUDA pip builds (mmcv) get OOM-killed

- **Symptom**: a pip build of a CUDA extension (e.g. `mmcv==2.1.0`, pulled by the Axelera mmseg model deploy `unet_fcn_256-cityscapes-onnx`) dies mid-compile with a bare `Killed`. `journalctl -k` shows `Out of memory: Killed process NNNNN (cicc)` (or `(nvcc)`), `constraint=CONSTRAINT_NONE ... global_oom`.
- **Cause**: this stack ships ZRAM deliberately disabled for RT memory determinism (`CONFIG_ZRAM is not set`; `nvzramconfig.service` masked in `03_bake_rootfs.sh`), and a freshly baked rootfs has no disk swap. CUDA extension builds fan out one `nvcc`/`cicc` process per source file, each ~2 GB resident; with zero swap on a 16 GB Orin NX (worse if another compile runs concurrently) the kernel OOM-kills the build. `00_doctor.sh` already assumes "swap covers peaks" for builds, so the swap is expected to be present but is not created by the flash/bake flow.
- **Fix** (two independent levers; use both):
  1. Add a disk swapfile on the NVMe (fast, no flash-wear; ZRAM stays off so the RT path is untouched). Keep `vm.swappiness` low so the kernel swaps only under real pressure and the real-time app never pages out:
     ```bash
     sudo fallocate -l 16G /swapfile && sudo chmod 600 /swapfile
     sudo mkswap /swapfile && sudo swapon /swapfile
     echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab           # persist across reboots
     echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swappiness.conf  # persist
     sudo sysctl -w vm.swappiness=10
     ```
  2. Cap build parallelism so peak RAM stays bounded even without swap, and build only the Orin GPU arch (less RAM, less time):
     ```bash
     MAX_JOBS=2 TORCH_CUDA_ARCH_LIST=8.7 pip install --no-build-isolation --no-deps "mmcv==2.1.0"
     ```
- **Note**: ZRAM (compressed-RAM swap) is intentionally NOT the remedy here. It is masked on this stack on purpose (RT determinism); a low-swappiness NVMe swapfile gives the same build headroom without the latency jitter ZRAM adds to the RT scheduling path. The Axelera runtime separately carries an OOM shield (`oom_score_adj=-1000`, applied by `jetson_rt_tune.sh`), so under memory pressure the mission-critical inference process is never the OOM victim; build-time compilers are.

## Flashing

### F-1. Flash hangs at "Sending mb1" or "Waiting for target to boot-up"

- **Symptom**: `l4t_initrd_flash.sh` polls forever; no progress past
  ~30 s.
- **Cause**: USB chain issue (hub, autosuspend, RNDIS not enumerating),
  or Jetson did not enter recovery mode.
- **Fix**:
  1. `lsusb -t`: Jetson must be on a direct motherboard port, not a hub.
  2. `lsusb | grep 0955:7323`: APX must be present (= recovery mode).
  3. `sudo sh -c 'echo -1 > /sys/module/usbcore/parameters/autosuspend'`.
  4. `sudo sh -c 'echo 200 > /sys/module/usbcore/parameters/usbfs_memory_mb'`.
  5. Reseat USB-C, re-short REC+GND, re-power.

### F-2. Flash succeeds but Jetson doesn't boot

- **Symptom**: After flash and recovery-pin removal, no HDMI, no SSH.
- **Most common cause (check first)**: wrong root device, see **F-4** below. A frozen
  logo with no `192.168.55.1` is almost always `root=/dev/mmcblk0p1` on a board with no
  eMMC.
- **Other cause**: extlinux.conf has duplicate or malformed lines from a
  partial bake.
- **Fix**: Re-run Phase 3 (`make bake`): the script now defensively
  removes prior RT args and `OVERLAYS` lines before injecting fresh ones.
  Then `make flash` again.

### F-3. `apply_binaries.sh` clobbers the custom kernel (device boots stock)

- **Symptom**: the flash completes, but on-device `uname -v` shows `SMP preempt`
  (not `preempt_rt`), `cyclictest` latency is bad, and `dmesg` is full of
  `Invalid module format` / `version magic mismatch` for nvgpu, the camera, and
  Metis. Nothing custom loads.
- **Cause**: `04_flash_nvme.sh` must run `apply_binaries.sh` to stage NVIDIA
  userspace and firmware into the rootfs, **but `apply_binaries.sh` also installs
  the stock `nvidia-l4t-kernel*` debs** (Image + base/OOT/display modules, vermagic
  `...preempt`). That overwrites the PREEMPT_RT Image and ~105 OOT modules built in
  Phase 2, so the device flashes a stock kernel with stock modules and none of our
  RT-built `.ko` (vermagic `...preempt_rt`) match.
- **Fix** (automatic): `04_flash_nvme.sh` now backs up `rootfs/lib/modules/<rel>`,
  `boot/Image`, and the ZED X `.dtbo` **before** `apply_binaries.sh`, restores them
  **after**, re-runs `depmod`, and then runs the rootfs vermagic gate
  (`verify_vermagic.sh --rootfs`). If the gate fails it **aborts before any device
  write**, so a clobbered rootfs can never reach the NVMe. Look for
  `Restoring custom RT kernel over apply_binaries' stock kernel` and
  `Custom RT kernel restored and vermagic-verified` in the flash log.
- **Manual recovery** (if you ever hit a half-clobbered rootfs): re-install the base
  modules with `make install -C kernel version=-tegra`, re-run the OOT
  `make modules_install` **with `KERNEL_HEADERS=<src>/kernel/kernel-jammy-src` set**
  (without it, modules_install targets `/lib/modules/$(uname -r)/build` and fails),
  copy the RT display modules from `source/nvdisplay/kernel-open/` over the stock ones
  in `updates/opensrc-disp/`, then `depmod -b rootfs <rel>` and re-run the gate.

### F-4. Frozen right after the NVIDIA logo (kernel waits forever for root)

- **Symptom**: the flash completes, the board powers on, shows the NVIDIA logo, and
  **hangs there forever**. No SSH, no `192.168.55.1` USB gadget on the host, the fan
  spins down. It looks dead but the kernel is actually alive, just stuck.
- **Cause**: the kernel command line carries `root=/dev/mmcblk0p1` (eMMC). **An Orin NX
  has no eMMC**, the rootfs is on NVMe (`/dev/nvme0n1p1`). With `rootwait` the kernel
  boots fine, then waits *indefinitely* for a disk that will never appear. The root of
  the root-device bug: a custom `extlinux.conf` that relies only on `${cbootargs}`
  inherits the board's eMMC default. A stock NVMe flash writes `root=/dev/nvme0n1p1`
  explicitly; a hand-rolled boot config must do the same. The `boot.img` used by
  L4TLauncher's "Attempting Recovery Boot" path carries the same default
  (`p3767.conf.common` `CMDLINE_ADD` has no `root=`), so **both** boot paths need fixing.
- **Confirm it**: read the baked-in cmdline straight out of the kernel partition image:
  `python3 -c "import sys;d=open('bootloader/boot.img','rb').read();print(d[64:576].split(b'\\0')[0])"`
  If you see `root=/dev/mmcblk0p1`, this is your bug.
- **Fix** (automatic now): the last `root=` on the cmdline wins, so we append the right
  one in both places. `03_bake_rootfs.sh` adds `root=/dev/<TARGET_STORAGE_DEV> rootwait
  rootfstype=ext4` to the extlinux `APPEND` (normal boot); `01_extract_and_patch.sh`
  appends `root=/dev/<TARGET_STORAGE_DEV>` to `p3767.conf.common` `CMDLINE_ADD` (the
  recovery `boot.img` path). Both default to `nvme0n1p1`.

### F-5. Blank HDMI after "Exiting boot services" is NORMAL, not a hang

- **Symptom**: HDMI shows the UEFI menu and the `EFI stub: ...` lines, then goes
  **completely dark** the moment `Exiting boot services...` prints. Tempting to read as
  "the kernel died here." **Do not.**
- **Why it's normal**: NVIDIA's `tegra_defconfig` (and therefore ours) does **not** set
  `CONFIG_FRAMEBUFFER_CONSOLE`, so the kernel never draws a text console on any
  framebuffer. The EFI/GOP framebuffer that `efifb` would use is **torn down at
  ExitBootServices** on ARM64, and Orin's real HDMI/DP comes from the *out-of-tree*
  `nvidia-drm`/`nvidia-modeset` modules that load late from userspace. So a **perfectly
  healthy** Orin also shows nothing on HDMI between "Exiting boot services" and the
  desktop. The blank screen is **non-diagnostic**: it looks identical whether the kernel
  is booting fine or fatally hung. Don't chase `FRAMEBUFFER_CONSOLE` or HDMI tweaks.
- **`earlycon=efifb` does NOT help on Orin**: the GOP framebuffer is gone by the time it
  would print. It produces nothing; skip it.
- **The real "did it boot?" signal** is the USB device-mode gadget: if `192.168.55.1`
  (RNDIS) and `/dev/ttyACM0` appear on the host, the kernel reached `multi-user.target`.
  If they never appear, it hung **before** multi-user. That, not the screen, is the test.
- **The real boot log** goes to `console=ttyTCU0,115200` (the Tegra Combined UART), which
  `${cbootargs}` injects via `CMDLINE_ADD`. On a carrier with a debug-UART header, a
  USB-TTL adapter on it reads the entire boot up to the hang. (The p3768 devkit has no
  onboard USB-serial bridge, so this needs an adapter.)
- **Related**: `L4TLauncher: Attempting Recovery Boot` means the normal extlinux boot was
  not used and the QSPI `boot.img` was loaded instead (a fallback). `Attempting Direct
  Boot` means the rootfs extlinux path was used. If you see Recovery Boot **and** a hang,
  suspect the root device (F-4) in the `boot.img` cmdline. If you see Recovery Boot on
  **every** power-on and it dead-ends at a `bash-5.1#` shell, the A/B boot-status flag is
  exhausted and L4TLauncher is forcing the fallback; see **F-11**.

### F-6. Custom RT kernel hangs in early boot, but the stock kernel boots fine

- **Symptom**: the flash succeeds, but our PREEMPT_RT kernel never reaches
  `multi-user.target` (no `192.168.55.1`, no `/dev/ttyACM0`), while a bone-stock NVIDIA
  kernel on the same board boots normally.
- **Step 1, isolate it (the decisive A/B test)**: re-flash with `STOCK_BASELINE=1`:
  `STOCK_BASELINE=1 SEED_USER=j SEED_PASS=jetson bash scripts/04_flash_nvme.sh`. This
  leaves `apply_binaries`' stock kernel in place (no RT restore). If the **stock** image
  boots and comes up on `192.168.55.1`, the board, SSD, PCIe (NVMe + Metis), and the
  entire flash pipeline are proven good and the fault is **100% the RT kernel**, and you
  now have **SSH into a working device** to debug from. If even stock hangs, the problem
  is below the kernel (DTB / hardware).
- **Gotcha in stock-baseline mode**: the flasher boots `kernel/Image` + `l4t_initrd.img`
  as its RAM environment. `apply_binaries` rebuilds `l4t_initrd.img` with stock `preempt`
  modules, but `kernel/Image` is still the RT build, so the flasher's RT kernel can't load
  the stock initrd's USB/RNDIS modules and you get **"Device failed to boot to the initrd
  flash kernel."** `04_flash_nvme.sh` handles this by copying the stock Image over
  `kernel/Image` in stock-baseline mode so the flash environment is internally consistent.
  (A genuinely transient version of that same error is USB autosuspend: `sudo sh -c 'echo
  -1 > /sys/module/usbcore/parameters/autosuspend'` and use a direct USB port, then retry.)
- **Step 2, the leading fix**: build the NVMe root chain **into** the kernel rather than
  as modules: `CONFIG_NVME_CORE=y`, `CONFIG_BLK_DEV_NVME=y`, `CONFIG_PCIE_TEGRA194=y`,
  `CONFIG_PCIE_TEGRA194_HOST=y`, `CONFIG_PHY_TEGRA194_P2U=y` (wired into
  [01_extract_and_patch.sh](../scripts/01_extract_and_patch.sh)). This takes the initrd
  module-load step out of the root-mount path, the most likely location of the PREEMPT_RT
  early hang. The verified kernel runs the NVMe and PCIe chain built-in, which removes the
  initrd's dependency on a preempt_rt `nvme.ko`. Keep the Axelera
  `LINK_WAIT_MAX_RETRIES=200` patch in place so the slow Metis endpoint trains reliably.
  (The RTL8822CE Wi-Fi link not coming up is a **separate** problem, see F-9: a confirmed
  board-side hardware fault, not link-wait timing.) Confirm on-device that the
  rebuilt RT kernel reaches `192.168.55.1` before treating this as settled.

### F-7. Boot reaches the USB gadget (ping works) but never reaches sshd

- **Symptom**: after flashing, the host sees the booted-OS USB gadget (`lsusb` shows
  `0955:7020 ... running on Tegra`, an `L4T-README` volume mounts, and `192.168.55.1`
  **pings**), but `ssh`/`:22` stays refused indefinitely (10+ min, no reboot) and the
  USB serial gadget shows no login prompt. The kernel booted; userspace never delivered
  a login. Field-diagnosed 2026-06-10: two independent traps produce this signature, and
  both were present at once. Check both.
- **Trap 1, the oem-config wizard (unseeded flash)**: `apply_binaries.sh` re-creates
  `/etc/systemd/system/default.target -> nv-oem-config.target` on EVERY flash; only the
  user pre-seed (`tools/l4t_create_default_user.sh`) removes it. A flash without the seed
  boots into the first-boot wizard flow, which waits forever before `sshd` with the USB
  gadget up and pinging. [scripts/04_flash_nvme.sh](../scripts/04_flash_nvme.sh) now
  seeds by default (user `j` unless `SEED_USER` is overridden; set `SEED_USER=""` for the
  interactive wizard on purpose) and aborts the flash if the wizard symlink survives
  seeding.
- **Trap 2, a hardware-probing driver force-loaded at sysinit**: see F-10. A
  `/etc/modules-load.d/*.conf` entry runs inside `systemd-modules-load.service`
  (sysinit); if that probe hangs, `sysinit.target` never completes and ssh/getty never
  start, while the kernel still answers ICMP.
- **Diagnosis order**: confirm the seed state first
  (`readlink rootfs/etc/systemd/system/default.target` must NOT be
  `nv-oem-config.target` on the staged rootfs), then audit every name in
  `rootfs/etc/modules-load.d/`. The blunt instrument, a diagnostic boot with the suspect
  modules held back (`install <mod> /bin/true` in a modprobe.d file) plus
  `default.target -> multi-user.target`, still works as a last resort but was NOT needed
  once both traps above were fixed: a healthy image reaches sshd in about 60 seconds.

### F-8. `nvgpu` "Unable to recover GR falcon", no CUDA, nvpmodel fails (CMA)

- **Symptom**: `dmesg` loops `nvgpu ... Unable to recover GR falcon` and `FECS context
  switch init error`; CUDA never initialises; the GPU devfreq node
  (`/sys/devices/platform/17000000.gpu/devfreq/`) is absent; `nvpmodel` fails with
  `Error opening /sys/devices/platform/17000000.gpu/devfreq_dev/available_frequencies`,
  so no power mode can be set either.
- **Root cause (live-verified 2026-06-10)**: **zero CMA**. The boot args carried
  `cma=2048M`; on Orin NX the kernel cannot place a 2 GiB contiguous reservation
  (`cma: Failed to reserve 2048 MiB`), and any cmdline `cma=` ALSO bypasses the device
  tree's `linux,cma` pool ("Reserved memory: bypass linux,cma node"). Net effect:
  `CmaTotal: 0 kB`. At GPU power-on, nvgpu must allocate a ~64 MB physically contiguous
  comptag buffer (`ga10b_cbc_alloc_comptags`); with zero CMA that allocation can never
  succeed (`DMA alloc FAILED: [sysmem] size=64225280 ... PHYSICALLY_ADDRESSED`), and the
  GR falcon / FECS chain collapses. The dramatic falcon errors are all downstream of one
  missing memory pool.
- **Fix**: pass NO `cma=` boot argument at all. The device tree `linux,cma` pool
  (256 MB, NVIDIA-sized, proven on stock) then takes over.
  [scripts/03_bake_rootfs.sh](../scripts/03_bake_rootfs.sh) no longer emits `cma=` and
  strips stale ones; the pre-flash audit fails if any `cma=` is present. Verified result
  on device: `CmaTotal 262144 kB`, zero nvgpu errors for the whole boot, GPU devfreq
  present, `/dev/nvgpu/igpu0` populated, and `nvpmodel` sets MAXN_SUPER.
- **Verify with**: `grep -i cma /proc/meminfo` (CmaTotal must be > 0) and
  `sudo journalctl -k -b | grep -iE "cma|falcon"` (no "Failed to reserve", no falcon
  errors). Build hygiene that is still good practice but was NOT the root cause here:
  export `IGNORE_PREEMPT_RT_PRESENCE=1` for the OOT GPU build (02_build does), keep OOT
  modules in lockstep with the kernel, and run `depmod -b $ROOTFS -F System.map` at
  flash time (04_flash does).

### F-9. RTL8822CE Wi-Fi: PCIe link never trains (no `wlan0`)

- **Symptom**: no wireless interface; `lspci -d 10ec:c822` is empty; the C1 controller
  logs `tegra194-pcie 14100000.pcie: Phy link never came up`. The card itself is alive:
  its Bluetooth half enumerates over USB (`lsusb` shows `0bda:c822`).
- **Verdict (final, 2026-06-10): board-side hardware fault in this dev board's M.2
  Key-E slot.** The software stack is exonerated by a five-track investigation:
  1. The STOCK NVIDIA kernel fails identically on this board, so the RT kernel and its
     config are not the cause. The Realtek options ARE enabled in our build (`RTW88=m`,
     `RTW88_8822CE=m`, vendor `rtl8822ce.ko` present) and the config diff against the
     pristine BSP contains zero lane-specific deltas.
  2. The flashed QSPI inputs (ODMDATA/BPMP UPHY config, MB1 pinmux, BCTs) are
     bit-identical to stock.
  3. The PHY bank is healthy: Metis trains on HSIO lanes 4-7, the live BPMP DTB
     confirms lane 3 is owned by PCIe C1, and the USB3 ports that could share the lane
     are disabled.
  4. The original card trains fine in another Jetson running a stock image.
  5. A second identical card ALSO fails to train on this board.

  Slot power is good too: the C1 node carries `vpcie3v3-supply = <&vdd_3v3_pcie>`
  (wired into [01_extract_and_patch.sh](../scripts/01_extract_and_patch.sh)), the rail
  measures 3300 mV, and retrains plus a full slot power cycle change nothing. The LTSSM
  never leaves Detect: electrically, nothing answers on lane 3. Full experiment log and
  captures: [WIFI_EVIDENCE.md](WIFI_EVIDENCE.md).
- **If YOUR board shows this**: the Wi-Fi support in this image works fine on healthy
  boards; do not start by suspecting the kernel. Check your hardware the same way:
  `sudo dmesg | grep 14100000` for `Phy link never came up`, try your card in another
  machine, and try a known-good card in your slot. If two known-good cards fail in your
  slot under the stock NVIDIA kernel too, it is your board, not this image.
- **Bring-up on a healthy board**: the vendor driver is present but blacklisted from
  autoload (see F-10), and the NetworkManager profile for the target SSID is staged.
  `sudo modprobe rtl8822ce` (manual loads bypass the blacklist) plus the staged profile
  bring Wi-Fi up without a reflash; once the driver probes cleanly, re-bake with
  `WIFI_AUTOLOAD=1` for boot-time autoload.
- **Boot-time cost of a dead C1**: the controller burns ~40 s per boot in link-wait
  windows (two ~20 s LTSSM waits at our `LINK_WAIT_MAX_RETRIES=200`). If Wi-Fi on a
  faulted board is abandoned, trim `LINK_WAIT_MAX_RETRIES` back toward stock or disable
  the C1 controller in the device tree to reclaim that time. The surgical, **reversible**
  way (no rebuild — patch the booted DTB and point `extlinux` at it):
  ```bash
  cp /boot/<your>.dtb /boot/<your>-c1off.dtb
  fdtput -t s /boot/<your>-c1off.dtb /bus@0/pcie@14100000 status disabled
  fdtget    /boot/<your>-c1off.dtb /bus@0/pcie@14100000 status   # -> disabled
  fdtget    /boot/<your>-c1off.dtb /bus@0/pcie@14160000 status   # Metis -> okay (untouched)
  # then set  FDT /boot/<your>-c1off.dtb  in /boot/extlinux/extlinux.conf
  ```
  Verified 2026-06-27: with C1 disabled the 40 s stall is gone and the serial log no longer
  shows `14100000.pcie` at all, while Metis (`14160000`), NVMe (`141e0000`), and Realtek GbE
  (`140a0000`) still train `Link up`. To bring the Intel/Key-E slot back later, point `FDT`
  back at the unmodified DTB — nothing else changes.

### F-10. Never force-load a hardware-probing driver from modules-load.d

- **Symptom**: identical to F-7 trap 2: gadget up, ping OK, no ssh/getty, forever.
- **Mechanism**: files in `/etc/modules-load.d/` are loaded by
  `systemd-modules-load.service` at **sysinit**. A driver whose probe touches real
  hardware (PCI/I2C) and hangs in D-state blocks `sysinit.target`, and with it every
  login path, while ICMP (kernel) still answers. This happened with a vendor
  `rtl8822ce.ko` force-load: harmless while the Wi-Fi slot was unpowered (probe found
  nothing and returned), fatal the moment the slot was powered.
- **Policy (enforced by [scripts/03_bake_rootfs.sh](../scripts/03_bake_rootfs.sh))**: the
  bake never writes wifi force-load entries. The vendor driver is `blacklist`ed, which
  stops both modalias autoload (udev coldplug) and the systemd-modules-load path, while
  a deliberate `sudo modprobe rtl8822ce` still works for supervised bring-up. Once the
  driver is proven to probe cleanly, re-bake with `WIFI_AUTOLOAD=1` to enable boot-time
  autoload.

### F-11. Every boot lands in Recovery Boot and drops to `bash-5.1#`

- **Symptom**: on the serial console (F-5), **every** power-on prints
  `L4TLauncher: Attempting Recovery Boot`, then the recovery initrd insmods a few
  modules (`tegra-bpmp-thermal.ko`, `pwm-tegra.ko`, `pwm-fan.ko`), prints
  `Finding OTA work dir on external storage devices` →
  `OTA work directory is not found on internal and external storage devices`, and lands
  on a shell:
  ```
  bash: cannot set terminal process group (-1): Inappropriate ioctl for device
  bash: no job control in this shell
  bash-5.1#
  ```
  The **same** sequence appears whether you attempt a "normal" boot or a deliberate
  recovery boot. It reads like a kernel crash at the `insmod`/OTA step. **It is not.**
- **Why it's not a crash**: that whole sequence *is* the recovery initrd's designed
  dead-end — it hunts for an OTA update package, finds none, and drops to a maintenance
  shell; the watchdog then reboots. Your real kernel and the rootfs `extlinux.conf`
  **never execute**, so nothing downstream (Metis, NVMe, camera) is "broken" — it is
  simply never reached. The fact that it happens on *both* a "normal" and a "recovery"
  attempt is the tell: **both are being redirected into the same fallback.**
  (`/dev/mmcblk0 does not exist` is normal — the Orin NX has no eMMC; `/dev/sd?1 does not
  exist` just means no USB disk was attached for that boot.)
- **Cause**: L4TLauncher falls back to Recovery Boot when the rootfs A/B **boot-status /
  retry-count** redundancy — stored in the module QSPI UEFI varstore, managed by
  `nvbootctrl` — is exhausted. A run of failed or power-cut boots (exactly what a botched
  in-place rebuild, F-12, or a wedged root device, F-4, produces) burns the retry count to
  zero and pins **every** subsequent boot into the fallback, even after the underlying
  problem is fixed.
- **Fix (non-destructive, stack untouched — verified 2026-06-27)**: force Direct Boot from
  UEFI. Power on with HDMI + a USB keyboard, tap `Esc`/`Del` at the splash →
  **Device Manager → NVIDIA Configuration → L4T Configuration**, set **OS chain A status →
  Normal (0x0)** (and chain B if present) and **L4T Boot Mode → ExtLinux**, then `F10` to
  save and reset. The board then prints `Attempting Direct Boot`, runs the rootfs
  `extlinux.conf`, and a single clean boot to `multi-user.target` resets the retry counter
  via `l4t-rootfs-validation-config.service`, so later boots Direct-Boot on their own.
  (Menu labels vary slightly by UEFI build; the two knobs are always the OS-chain status
  and the boot mode.) Verified result: serial shows `Attempting Direct Boot` → our cmdline
  (`root=PARTUUID=… rootfstype=ext4 … console=ttyTCU0`) → Ubuntu autologin, with
  Metis/NVMe/Realtek PCIe all `Link up`.
- **Prerequisite**: the rootfs extlinux must actually be bootable first — a single correct
  `root=` (F-12) and the right `FDT` — or Direct Boot just bounces back into recovery and
  re-exhausts the counter.

### F-12. Boot worked, then an in-place rebuild mangled `extlinux.conf` (multiple `root=`)

- **Symptom**: the stack booted fine, then an in-place "make it new" / re-bake **on the
  running device** left it unbootable — black screen, or forced into Recovery Boot (F-11).
  The rootfs `/boot/extlinux/extlinux.conf` `APPEND` line now carries **two or three
  `root=`** tokens, e.g. `root=/dev/nvme0n1p1 … root=PARTUUID=<uuid> … root=/dev/nvme0n1p1`,
  with RT isolation args concatenated onto a second copy of the stock factory args. Sibling
  `/boot/Image.prestock-custom` and `/boot/Image.custom-bak-<date>` files confirm the
  kernel was swapped in place too.
- **Cause**: a re-bake/restore that **appended** boot args instead of replacing them,
  layering the factory cmdline over the custom one (and sometimes pointing `FDT` at the
  wrong DTB). The kernel uses the *last* `root=`, so a duplicate is not always fatal, but
  mixing `root=/dev/nvme0n1p1` (enumeration-order, races PCIe bring-up) with
  `root=PARTUUID=` plus a wrong/limited `FDT` wedges the mount and trips the boot-status
  flag (→ F-11).
- **Fix**: restore a clean **single-`root=`** extlinux. Canonical good form for this build:
  ```
  LABEL primary
    LINUX /boot/Image
    INITRD /boot/initrd
    FDT /boot/<your>.dtb
    APPEND ${cbootargs} root=PARTUUID=<APP-partuuid> rw rootwait rootfstype=ext4 pcie_aspm=off nohz_full=1-5 isolcpus=1-5 rcu_nocbs=1-5 irqaffinity=0 console=ttyTCU0,115200 console=tty0
    OVERLAYS /boot/<camera-overlay>.dtbo
  ```
  Get the APP PARTUUID with `lsblk -o NAME,PARTUUID` (or `blkid`); confirm it is the rootfs
  partition.
- **Integrity check** (make this a habit before every reboot after touching boot config):
  ```bash
  grep -c 'root=' /boot/extlinux/extlinux.conf   # must print 1
  ```
  If it prints 2+, you have the mangle. Keep a known-good copy (`extlinux.conf.good`) so a
  bad re-bake is a one-line restore. The supported pipeline avoids this entirely —
  `03_bake_rootfs.sh` strips prior RT args / `OVERLAYS` / `root=` before injecting fresh
  ones (F-2); this failure mode comes from hand-editing or re-baking *in place on the live
  device*.
- **The DTB is almost certainly not your problem**: a `dtc` decompile of the custom
  `tegra234-p3768-0000+p3767-0000-nv.dtb` against the pristine BSP DTB is **identical** for
  the Metis controller node (`pcie@14160000`) and every PCIe node — the whole-file diff is
  two lines (build name/timestamp). So if Metis worked before and stopped, look at the boot
  config (this entry) and the firmware handshake (H-13), not the DTB. Verify yourself:
  `fdtget <dtb> /bus@0/pcie@14160000 status` (Metis) and
  `fdtget <dtb> /bus@0/pcie@14100000 status` (Key-E Wi-Fi).

### F-13. Anything plugged into USB-C storms the log and wedges the console

- **Symptom**: the box runs fine until you plug **anything** into the USB-C port (to flash,
  or a peripheral); the kernel console then instantly floods, forever:
  ```
  tegra-xudc 3550000.usb: CEC, PORTSC = 0xffffffff
  ** 437 printk messages dropped **
  ```
  hundreds of lines a second with hundreds dropped between each — the `tty`/serial console
  becomes unusable and the box *feels* dead ("USB-C kills the kernel"). The controller
  initialises cleanly at boot (`tegra-xudc 3550000.usb: Adding to iommu group 6`, ~6 s);
  the storm begins **only** at the plug-in event (observed t≈171 s, telemetry 2026-06-27).
- **Cause**: `3550000.usb` is the Tegra **device-mode (xudc / USB gadget)** controller.
  `PORTSC = 0xffffffff` is an all-ones MMIO read — the controller's register block is
  returning garbage (clock-gated / wedged) while its IRQ handler tries to service a
  port-change event. Unable to read a valid status, the handler never clears the interrupt,
  so it immediately re-fires → a self-sustaining printk storm. This is the device/gadget
  side, separate from the xHCI **host** side and from PCIe.
- **Does NOT affect recovery flashing**: USB-C recovery (RCM) flashing runs over the
  **bootROM / MB1 USB path**, not the Linux `tegra-xudc` driver, so this running-kernel
  storm does not break `l4t_initrd_flash` in recovery mode. If flashing itself fails, that
  is F-1, not this.
- **Mitigation (working theory; permanent fix pending live confirmation, 2026-06-27)**: if
  the running OS does not need USB device-mode (gadget RNDIS/ACM), stop the storm by
  unbinding the controller —
  ```bash
  echo 3550000.usb | sudo tee /sys/bus/platform/drivers/tegra-xudc/unbind
  ```
  — or simply keep USB-C empty during operation. While working the console, `sudo dmesg -n 1`
  raises the loglevel threshold so the storm stops blinding you. A permanent fix (rate-limit
  the handler, or build the port host-only in the DTB/defconfig when device-mode is unused)
  is being confirmed against this unit; this entry will record the verified resolution once
  tested.

### F-14. Intel AX210 Wi-Fi bring-up (iwlwifi, M.2 Key-E / PCIe C1)

- **Card**: the deployed Key-E card is an **Intel AX210** — Wi-Fi `8086:2725` on PCIe C1
  (`pcie@14100000`), Bluetooth `8087:0032` over USB. This supersedes the RTL8822CE the F-9
  saga was about; the AX210 BT half enumerates over USB regardless of C1.
- **Baked support**: `CONFIG_IWLWIFI=m` + `CONFIG_IWLMVM=m`
  ([01_extract_and_patch.sh](../scripts/01_extract_and_patch.sh)), firmware
  `iwlwifi-ty-a0-gf-a0-*.ucode` + `.pnvm` staged into the rootfs
  ([03_bake_rootfs.sh](../scripts/03_bake_rootfs.sh), from `linux-firmware`), and C1 left
  **enabled** in the DTB. `iwlwifi` modalias-autoloads (no blacklist — it is in-tree and
  well-behaved, unlike the RTL vendor blob behind F-10).
- **Requires C1 enabled**: `extlinux.conf` `FDT` must point at a DTB whose `pcie@14100000`
  is `okay` (NOT a `*c1off*` DTB). Verify: `fdtget /boot/<fdt>.dtb /bus@0/pcie@14100000
  status` → `okay`. (The C1-off DTB in F-9 is only for *abandoning* Key-E to reclaim the
  ~40 s link-wait; with the AX210 in use, keep C1 on.)
- **Bring-up / check**:
  ```bash
  lspci -d 8086:                       # AX210 present (8086:2725) on bus 0001
  sudo dmesg | grep -iE 'iwlwifi|14100000'   # fw load; want "Link up", not "Phy link never came up"
  nmcli dev status                     # wlan0 present
  nmcli dev wifi connect "<SSID>" password "<PASS>"
  ```
- **Result on this board (verified 2026-06-27)**: the AX210 PCIe link **does NOT train on
  C1** — `tegra194-pcie 14100000.pcie: Phy link never came up`, no `8086:2725` in `lspci`, no
  `wlan0` — **even with C1's DTB made byte-identical to factory** (the `vpcie3v3-supply`
  removed). That is now **three** cards (2× RTL8822CE + the Intel AX210) plus the **stock
  NVIDIA kernel** all failing identically. A forum survey of "Phy link never came up" on
  C1/`14100000` found **no software fix for this exact fingerprint** (factory card + factory
  DTB + stock kernel all fail, while the card's Bluetooth works over USB): every matching
  case resolved to a board/signal-integrity fault or RMA. So — unlike Metis, which was a
  software clock bug (H-13) — the **C1 Key-E PCIe lane is a genuine board-side fault** on this
  unit. (`lane 3` per the stock ODMDATA `hsio-uphy-config-0` is correctly assigned to C1;
  it simply never leaves LTSSM Detect/Polling.)
- **Remaining software long-shots (low probability)**: C1 is trained by the **kernel** (it is
  not a UEFI boot device), so a kernel-side Gen1 clamp `nvidia,max-link-speed = <1>` on the
  `pcie@14100000` node *via the extlinux FDT* is the one cheap thing left to try (NVIDIA's
  documented workaround for marginal-SI "Phy link never came up"; rarely rescues a link stuck
  in Polling.Compliance). The firmware Gen2 clamp via ODMDATA `hsio-uphy-config-40` would need
  a full QSPI reflash. **Practical path: a USB Wi-Fi dongle** — the AX210's Bluetooth keeps
  working over USB regardless.

### F-15. Boot hangs in a UEFI HTTP/PXE network-boot loop (USB-eth dongle)

- **Symptom**: the board never reaches the OS; the serial console repeats the UEFI splash and
  `>>Start HTTP Boot over IPv4 …` / `PXE …` endlessly (a flood of `IPv4` retries). SSH never
  comes up. Often appears right after a host starts serving DHCP on the rescue link.
- **Cause**: the UEFI `BootOrder` lists the **network interfaces as bootable devices ahead of
  the NVMe**. On this unit the USB-eth dongle's HTTP/PXE entries (`Boot000B/000A/0009/0001`,
  MAC `00E04C1D7288`) were *first*, with the NVMe (`Boot0008`) fifth. When a DHCP server
  answers on that link, UEFI gets a lease and chases network boot forever instead of falling
  through to the NVMe. With no DHCP it fails fast and boots the NVMe — which is why it only
  bites once you add a DHCP server (e.g. the rescue-link `dnsmasq`).
- **Fix (no UEFI menu needed — from inside Linux)**: put the NVMe first in the UEFI boot
  order with `efibootmgr` (it edits the `BootOrder` EFI variable directly):
  ```bash
  sudo efibootmgr                       # find the NVMe entry (… NVMe(…)) and the netboot ones
  sudo efibootmgr -o 0008,0006,0007,0000,0001,0002,0003,0004,0005,0009,000A,000B
  #                  ^ NVMe first; netboot entries pushed to the end
  ```
  After this the NVMe boots first and the dongle is never a boot target, so the rescue-link
  DHCP can stay up for SSH/internet without the loop. (To get *into* Linux the first time so
  you can run `efibootmgr`, momentarily stop the host DHCP — `sudo systemctl stop
  rescue-dhcp` — power-cycle so UEFI fails netboot fast and boots the NVMe, then restart it.)
- **Alternative**: in UEFI Setup (`Esc` at splash) disable HTTP/PXE/Network boot. Same effect,
  but `efibootmgr` is scriptable and survives.

## Vermagic / module loadability

### V-1. `Invalid module format` in dmesg

- **Symptom**: `dmesg | grep -i "invalid module format"` or a service
  fails because its driver isn't loaded.
- **Cause**: vermagic mismatch, a `.ko` whose vermagic doesn't match
  the running kernel's.
- **Fix**:
  1. Identify the offender: `for ko in /lib/modules/$(uname -r)/...
     /*.ko; do modinfo "$ko" | grep -H vermagic; done`.
  2. Confirm the running kernel's expectation: `cat /proc/version`.
  3. If a vendor `.deb` was installed post-flash (e.g. someone ran
     `apt install nvidia-l4t-kernel-modules`), re-flash from a clean
     build. APT pinning (`Pin-Priority: -1`) added by first-boot
     prevents recurrence.
  4. See [VERMAGIC_STRATEGY.md](VERMAGIC_STRATEGY.md).

### V-2. ZED SDK install fails to build sl_zedx.ko

- **Symptom**: `dkms install -m sl_zedx ...` fails with
  `Cannot find sources for kernel 5.15.x-tegra`.
- **Cause**: linux-headers-*.deb wasn't installed before the SDK
  installer ran.
- **Fix**: `dpkg -i /opt/kernel-headers/linux-headers-*.deb`, then
  re-run `/opt/zed-sdk/install_zed_sdk.sh`. If the .deb is missing
  entirely, re-run Phase 2 (`make build`) and re-bake (`make bake`).

### V-3. On-target module build fails: `scripts/basic/fixdep: Exec format error`

- **Symptom**: any module build against `/usr/src/linux-headers-$(uname -r)`
  (DKMS, or a manual `make -C ... M=...`) dies with `Exec format error` on
  `fixdep`, later `genksyms: not found` or modpost failures.
- **Cause**: the headers .deb is produced by the **cross-compile** in Phase 2,
  so its `scripts/` host tools are x86_64 binaries that cannot execute on the
  Jetson. This silently breaks the "DKMS installers can rebuild against our
  headers" guarantee.
- **Fix**: rebuild the host tools natively.
  [`install_zedx_daemons.sh`](../scripts/install_zedx_daemons.sh) §1 does it
  automatically (purge x86 binaries under `scripts/`, `gcc fixdep.c`,
  bison/flex + `gcc` for genksyms, `mk_elfconfig` + `gcc` for modpost, then
  freeze mtimes of `auto.conf`/`autoconf.h` so kbuild does not trigger
  `syncconfig`). Do **NOT** run `make scripts` in the headers tree: the deb
  ships no Kconfig files, so it fails AND deletes `autoconf.h` (restore by
  re-installing the deb: `dpkg -i --force-overwrite /opt/kernel-headers/*.deb`).

### V-4. Loaded modules look fine but driver behaves wrong

- **Symptom**: `lsmod` shows the module, but downstream subsystems
  (V4L2 device, PCIe link) misbehave.
- **Cause**: per-symbol CRC drift (`CONFIG_MODVERSIONS=y` mismatch even
  though vermagic strings happen to match): extremely rare but possible
  if someone built modules against a different kernel source tree with
  the same `LOCALVERSION`.
- **Fix**: Force-load is not allowed (`CONFIG_MODULE_FORCE_LOAD` is off).
  The only path is rebuild from a clean tree.

## First-boot / provisioning

### P-1. Phase 5 "completes" but installs nothing (`step::run: command not found`)

- **Symptom**: first-boot journal shows `[WARN] Phase 5 install reported
  issues`, every step logs `install_av_phase5.sh: line NN: step::run:
  command not found`, and afterwards there is no OpenCV, no `/opt/ros/humble`,
  no `jetson-av-mission.service`, no `/etc/jetson-av/mission.conf`, yet the
  script printed its "Phase 5 Install Complete" banner.
- **Cause**: two stacked bugs, both fixed in the repo 2026-06-10.
  (1) `install_av_phase5.sh` / `install_av_stack.sh` sourced `lib/verify.sh`
  without `lib/config.sh` first; verify.sh refuses to define the `step::*`
  functions, and `STRICT=0` swallowed the failures. (2) The lib include
  guards (`JETSON_AV_LOG_LOADED` etc.) were **exported**, so a sub-script
  (`build_opencv_cuda.sh` invoked by the orchestrator) inherited the guard
  but not the functions (env vars cross fork+exec, shell functions don't)
  and its libs short-circuited to the same `command not found`. Staged
  copies under `/home/j/phase5` on devices flashed before the fix are still
  broken (their `lib/config.sh` also dies on unbound pins without
  `versions.env`).
- **Fix**: run Phase 5 from a repo checkout on the device:
  `cd ~/Documents/jetson-rt-stack && sudo bash scripts/install_av_phase5.sh`.
  Devices baked after the fix run it correctly at first boot.

### P-2. torch in `/opt/av-env` is CPU-only (`2.x.y+cpu`, `torch.cuda.is_available()` False)

- **Symptom**: `/opt/av-env/bin/python -c "import torch; print(torch.__version__)"`
  prints a `+cpu` build even though first boot installed the cu126 wheel.
- **Cause**: a later unconstrained pip run (observed live 2026-06-10: the
  Voyager SDK step, PyPI primary + Axelera extra-index) "upgrades" torch to
  generic PyPI's CPU wheel. An unpinned `torchvision` similarly resolves to
  0.26.0 and drags in numpy 2.x, breaking the Voyager pins.
- **Fix**:
  ```bash
  sudo /opt/av-env/bin/pip install --force-reinstall torch==2.8.0 \
      torchvision==0.23.0 "numpy<2.0.0" \
      --index-url https://pypi.jetson-ai-lab.io/jp6/cu126
  ```
  `jetson_first_boot.sh` now restates `torch==2.8.0` in the Voyager pip call
  and pins torchvision/numpy in the torch call, so freshly baked images don't
  regress.

### P-3. `nvcc` not found and zero `cuda-*` packages on a freshly flashed device

- **Symptom**: `which nvcc` empty, `dpkg -l | grep -c '^ii  cuda'` is 0,
  torch import fails with `libcudart.so.12: cannot open shared object file`.
- **Cause**: the NVIDIA sample rootfs ships **without** JetPack userspace
  (CUDA toolkit, cuDNN, TensorRT, VPI, NVIDIA GL). Nothing in Phases 1-4
  installs it; it comes from apt on the running device.
- **Fix**: `sudo apt update && sudo apt install nvidia-jetpack` (~3.8 GB).
  Safe by design: the kernel/bootloader pins (`Pin-Priority: -1`) block any
  RT-kernel clobber. Then see [CUDA_LIBS.md](CUDA_LIBS.md) for the OpenCV
  build and the verification gauntlet.

### P-4. OpenCV build deps fail: `nvidia-cuda-toolkit : Depends: nvidia-cuda-dev (= 11.5.1-1ubuntu1)`

- **Symptom**: the "Install OpenCV build deps" step fails with an apt
  dependency conflict, and downstream `cmake: command not found` (the whole
  apt transaction was rolled back, so none of the build deps installed).
- **Cause**: `nvidia-cuda-toolkit` is **Ubuntu universe's CUDA 11.5**, which
  conflicts with JetPack's `nvidia-cuda-dev` 6.x. On Jetson the CUDA toolkit
  comes from JetPack (`cuda-toolkit-12-6`, installed by `nvidia-jetpack`) and
  lives at `/usr/local/cuda`. It must never be apt-installed from Ubuntu.
- **Fix**: removed from `build_opencv_cuda.sh` deps (2026-06-10). If you hit
  this on an old checkout, drop `nvidia-cuda-toolkit` from the apt line and
  ensure `/usr/local/cuda/bin` is on `PATH` for the build.

### P-5. Installer or mission launcher dies right after "STEP COMPLETE: Install ROS 2"

- **Symptom**: the script aborts with
  `/opt/ros/humble/setup.bash: line 8: AMENT_TRACE_SETUP_FILES: unbound variable`
  immediately after the ROS apt install succeeds; `launch_av_mission.sh`
  can die the same way at startup.
- **Cause**: ROS 2 setup scripts reference unset variables. Under `set -u`
  an expansion error aborts a non-interactive bash even when the `source` is
  guarded with `|| true`.
- **Fix**: wrap every ROS `setup.bash` source in `set +u` … `set -u`
  (applied 2026-06-10 to `install_av_stack.sh` and `launch_av_mission.sh`).

### P-6. cv2 import dies with `numpy.core.multiarray failed to import`

- **Symptom**: `/opt/av-env/bin/python -c "import cv2"` fails right after an
  OpenCV-CUDA build that completed cleanly; `cmake` output (or
  `CMakeCache.txt`) shows `numpy ... (ver 2.x)` with a `numpy/_core/include`
  path.
- **Cause**: the bindings compile against the venv's numpy **headers** and
  only run on the same numpy major version. pyzed's wheel declares an
  unbounded numpy dependency and its installer runs `--ignore-installed`,
  silently bumping the venv to numpy 2.x; an OpenCV build configured in that
  window produces bindings that break once the Voyager `numpy<2` pin is
  restored. Two guards added 2026-06-10: `install_zed_sdk.sh` re-asserts the
  pin after pyzed, and `build_opencv_cuda.sh` refuses to configure when the
  venv numpy is >=2.
- **Fix** (without a full rebuild: only the bindings need recompiling):
  ```bash
  sudo /opt/av-env/bin/pip install --force-reinstall "numpy<2.0.0"
  cd /var/tmp/opencv-build/opencv/build
  sudo cmake -U 'PYTHON3*' -U 'OPENCV_PYTHON3*' \
       -D PYTHON3_EXECUTABLE=/opt/av-env/bin/python -D BUILD_opencv_python3=ON .
  sudo make opencv_python3 -j6 && sudo make install
  ```
  Also remove pip's CPU `opencv-python` if present (it shadows the CUDA
  build): `sudo /opt/av-env/bin/pip uninstall -y opencv-python`, and ensure
  the venv sees the system install:
  `ln -sfn /usr/local/lib/python3.10/site-packages/cv2 /opt/av-env/lib/python3.10/site-packages/cv2`.

## Hardware

### H-1. `lspci` shows nothing for Axelera

- **Symptom**: `lspci -d 1f9d:` is empty; the Metis NPU does not enumerate at
  `0004:01:00.0`.
- **Cause**: PCIe link training failed. The cold-boot `LINK_WAIT_MAX_RETRIES`
  patch is the most common culprit.
- **Fix**: Verify `pcie-designware.h` shows `LINK_WAIT_MAX_RETRIES 200`
  in the source tree, then rebuild and re-flash. The patch is applied by
  `plugins/axelera` in Phase 1. See [KERNEL_PATCHES.md](KERNEL_PATCHES.md) §1.

### H-2. ZED X frames appear but stereo depth is wrong

- **Cause**: MAX96712 deserializer was selected instead of MAX9296.
- **Fix**: See [DRIVERS.md](DRIVERS.md) §1.2, "MAX9296 vs MAX96712 silent-corruption trap".

### H-3. cyclictest reports max latency > 1 ms

- **Cause**: RT boot args missing, governor wrong, or IRQs not pinned.
- **Fix**:
  1. `cat /proc/cmdline` must contain `isolcpus=1-5 nohz_full=1-5
     rcu_nocbs=1-5`.
  2. `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor` must
     be `performance`.
  3. `sudo /home/j/jetson_rt_tune.sh` to re-apply per-boot tuning.

### H-4. Performance tanks mid-mission

- **Cause**: thermal throttling; check
  `cat /sys/class/thermal/thermal_zone*/temp` (millidegrees C).
- **Fix**: `jetson_rt_tune.sh` already pegs the fan at PWM 255. If you're
  still hitting >85°C, add active cooling.
- **Baselines**: expected FPS, GPU load, power, and temperature per
  configuration are in [BENCHMARKS.md](BENCHMARKS.md). For the C++ fusion
  sample specifically, the `--depth-every` cadence flag is the biggest
  throughput lever; see [ZEDX_METIS_CPP.md](ZEDX_METIS_CPP.md).

### H-5. ZED X works but the image is soft / not crisp

- **Symptom**: capture runs at full FPS, colors fine, but the image lacks
  sharpness regardless of `.isp` tuning files.
- **Cause**: stock L4T R36.4.x `libnvisppg.so` (NVIDIA ISP post-processing
  library) has an image-quality regression with the ZED X. Distinct from
  the `.isp` calibration files (§1.4 of DRIVERS.md).
- **Fix**: install Stereolabs' patched build from
  `zedx-driver/nvidia_364_fix/R36.4.3/libnvisppg.so`.
  [`install_zedx_daemons.sh`](../scripts/install_zedx_daemons.sh) does it
  automatically via `dpkg-divert` and restarts `nvargus-daemon`. Verified
  live 2026-06-11 (sharp at 29.5 FPS sustained, HD1200).

### H-6. ZED SDK: `CAMERA MOTION SENSORS NOT DETECTED` / `No camera-to-SPSC mappings found`

- **Symptom**: the camera enumerates in V4L2 (`/dev/video*` present) but
  `pyzed`/SDK `open()` fails; later stages may show `Device 0 not
  accessible` or `Failed to configure device 0`.
- **Cause**: ZED SDK 5.3 needs the BMI088 IMU + SPSC kernel modules and the
  vendor daemons (`ZEDX_Driver`, `ZEDX_Daemon`, `IMU_Daemon`) from the
  zedx-driver tree, none of which the SDK installer provides. Two traps:
  the loader insmods from `kernel/drivers/stereolabs/` (NOT `updates/`),
  and `/dev/spsc_bmi*` is root-only without a udev rule.
- **Fix**: `sudo scripts/install_zedx_daemons.sh` (builds modules against
  the running kernel, installs daemons + udev rule, restarts the chain).
  Full background: [DRIVERS.md §1.5](DRIVERS.md).

### H-7. ZED SDK suddenly fails: `Failed to connect to daemon socket`

- **Symptom**: the camera worked, then `pyzed` open fails with
  `Failed to connect to daemon socket` / `Failed to configure device 0`;
  `IMU_Daemon.service` shows **active**.
- **Cause**: `IMU_Daemon` listens on `/tmp/imu_daemon.sock`. Anything that
  wipes `/tmp` (the Phase 7 resilience step activating `tmp.mount` is the
  documented offender) deletes the socket while the daemon keeps running.
- **Fix**: restart the chain:
  `sudo systemctl restart driver_zed_loader && sleep 3 && sudo systemctl restart zed_x_daemon IMU_Daemon`.
  `install_uav_resilience.sh` now does this automatically after enabling
  tmp.mount.

### H-8. SLAM / detect node run but receive no frames (silent)

- **Symptom**: `zed_wrapper`, cuVSLAM, and `detect_metis.py` all show running;
  `ros2 topic hz` on the consumer side prints nothing; no errors anywhere.
- **Cause**: zed-ros2-wrapper **5.1.0 renamed every image topic**
  (`rgb/image_rect_color` → `rgb/color/rect/image` etc.), topics are **lazy**
  (published only while subscribed), and left/right topics are **off by
  default** (`video.publish_left_right: false`), exactly what cuVSLAM needs.
  Any consumer wired to a pre-5.1 name waits forever.
- **Fix**: subscribe to the >=5.1 names (`/zed/zed_node/rgb/color/rect/image`,
  `/zed/zed_node/depth/depth_registered`); for stereo consumers enable
  left/right via `/etc/jetson-av/zedx_overrides.yaml` (staged by
  `install_mission_inference.sh`; the mission launcher passes it as
  `ros_params_override_path`). cuVSLAM is wired through
  `/opt/jetson-av/zedx_vslam.launch.py`. The stock
  `isaac_ros_visual_slam.launch.py` declares NO remappings at all.

### H-9. Every mission unit crash-loops instantly (`activating auto-restart`)

- **Symptom**: `systemctl start jetson-av-mission` spawns the units, but
  `jetson-av-camera/slam/nav2/...` all cycle `activating auto-restart`;
  journals show `ros2: command not found` or
  `failed to initialize logging: Failed to get logging directory`.
- **Cause**: `systemd-run` transient units start from PID 1 with **no ROS
  environment and no HOME**: nothing from the launcher's shell carries over.
  Both bit the first live mission run (2026-06-11).
- **Fix** (in `launch_av_mission.sh` since 2026-06-11): nodes spawn via
  `/bin/bash -lc` (login shell sources `/etc/profile.d/jetson-av-stack.sh`)
  with `--setenv=HOME=/root --setenv=ROS_LOG_DIR=/var/log/jetson-av/ros`.
  If you add new spawn sites, keep that pattern.

### H-10. jtop crashes when opening the GPU tab (`KeyError: '3d_scaling'`)

- **Symptom**: `jtop` runs fine until you switch to the GPU page, then the
  curses UI dies with `KeyError: '3d_scaling'` raised from
  `jtop/gui/pgpu.py`. Confirmed on this image 2026-06-11 (jetson-stats
  4.3.2, L4T r36.4.3).
- **Cause**: upstream jetson-stats bug on JetPack 6. The GUI reads
  `gpu_status['3d_scaling']` unconditionally, but the jtop service only
  populates that key when
  `/sys/devices/platform/17000000.gpu/enable_3d_scaling` is readable, and
  r36's out-of-tree nvgpu driver no longer exposes that node anywhere in
  `/sys` (`railgate_enable` survives, so the rest of the page is fine).
  4.3.2 is the latest PyPI release, so upgrading does not help.
- **Fix**: make the missing key non-fatal in the two places that assume it
  (the page render, and the toggle-button callback path in the client API):
  ```bash
  sudo sed -i "s/gpu_status\['3d_scaling'\]/gpu_status.get('3d_scaling', False)/g" \
      /usr/local/lib/python3.10/dist-packages/jtop/gui/pgpu.py
  sudo sed -i "s/\['status'\]\['3d_scaling'\]/['status'].get('3d_scaling', False)/" \
      /usr/local/lib/python3.10/dist-packages/jtop/core/gpu.py
  ```
  No service restart needed. Showing "Disable" is accurate: the 3D-scaling
  knob genuinely no longer exists on JP6. Re-apply after any jetson-stats
  reinstall/upgrade unless upstream has fixed it by then.

### H-11. No way to see Metis utilization: `axmonitor` missing from the pip-installed runtime

- **Symptom**: jtop shows nothing for the NPU (it only knows Tegra hardware),
  and the Metis monitoring tool `axmonitor` is not in `/opt/av-env/bin`
  alongside `axdevice`/`axrunmodel`. Found on this image 2026-06-11
  (Voyager runtime 1.6.1 via pip).
- **Cause**: not a bug. The pip install path deliberately omits `axmonitor`
  and its backend service `axsystemserver`; Axelera only ships them in the
  apt packages (`axelera-voyager-sdk-base-*` → `axelera-runtime-*`). The SDK
  docs note this in `~/voyager-sdk/docs/tutorials/axmonitor.md`. arm64
  builds matching runtime 1.6.1 confirmed present in their apt repo.
- **Fix**: add the Axelera apt repo and install the matching base
  metapackage, then start `axsystemserver.service`. Full commands and usage
  in [Samples]({{ '/SAMPLES' | relative_url }}) § "Monitoring the Metis".
  Verified live 2026-06-11. Two traps in the packaging, both hit on this
  unit:
  1. `axmonitor` dies with `libQt6Svg.so.6: cannot open shared object
     file`: the deb does not declare its Qt dependency. `sudo apt-get
     install libqt6svg6` fixes it (sole missing lib per
     `ldd .../bin/axmonitor`).
  2. `systemctl enable axsystemserver` aborts with `update-rc.d: error:
     axsystemserver Default-Start contains no runlevels`: the package ships
     both a native unit and a malformed SysV init script, and the SysV sync
     kills the enable. `systemctl start` works; for boot persistence,
     symlink the unit into `/etc/systemd/system/multi-user.target.wants/`
     by hand (then `systemctl is-enabled` reports `enabled`).
  No power readings on the M.2 module (4-Metis PCIe card only). Use jtop's
  INA3221 rails for board draw.

### H-12. ZED SDK: `CAMERA STREAM FAILED TO START` after a camera client is killed

- **Symptom**: `sl::Camera::open()` returns `CAMERA STREAM FAILED TO START`, and every
  subsequent open fails the same way, even though `/dev/video0,1` exist and `zed_x_daemon`
  reports `active`. Usually appears right after a camera app was hard-killed or hung
  mid-stream (an OOM-killed or `timeout`-killed process, or a thread-join deadlock on
  shutdown).
- **Cause**: the GMSL2 / Argus capture pipeline is left wedged. The deserializer plus the
  `nvargus` session were not torn down cleanly, so the stream cannot restart until the
  daemons reset it. The devices and the daemon still look healthy, which makes it read like
  a camera fault when it is really a stuck pipeline.
- **Fix**: restart the capture daemons, then retry:
  ```bash
  sudo systemctl restart nvargus-daemon zed_x_daemon
  ```
  If it persists, also `sudo systemctl restart driver_zed_loader` and re-probe with a short
  capture. Prevent it by shutting camera clients down gracefully (let them finalize) instead
  of `SIGKILL`; a well-behaved client releases the stream on exit. Distinct from H-7 (daemon
  socket lost) - there the daemon is gone, here the daemon is up but the stream pipeline is
  stuck. Verified live 2026-06-11.

### H-13. Metis enumerates in `lspci` but `axl IRQ MSI timeout` floods dmesg

- **Symptom**: unlike H-1, the Metis **does** enumerate — `lspci -d 1f9d:` shows it at
  `0004:01:00.0` (`[1f9d:1100]`, class `0x120000`), `14160000.pcie` logs `Link up`, BARs are
  assigned, and the `axl` driver binds — but the NPU is unusable and dmesg repeats, every
  ~2.048 s forever:
  ```
  axl 0004:01:00.0: IRQ MSI timeout (24 2)
  ```
  No model ever runs. Observed 2026-06-27 on the restored stack.
- **What it means**: link training and PCIe enumeration **succeeded** — this is *past* H-1,
  so do not chase `LINK_WAIT_MAX_RETRIES`. The failure is one step later: the `axl` driver
  kicks the device's boot/mailbox handshake and waits for the Metis to answer with an MSI;
  the MSI never arrives, so it times out and retries on a ~2 s heartbeat. The card is
  electrically present but its firmware/interrupt path is not completing.
- **Key cross-check**: **NVMe on `0007:01:00.0` also uses PCIe MSI and works** on the same
  boot (root mounts, EXT4 clean), so the GIC/MSI mechanism is alive system-wide — the fault
  is specific to the Metis controller/device or its driver↔firmware pairing, **not** MSI in
  general.
- **Root cause (verified live 2026-06-27): the system clock was stuck at 1970-01-01.** The
  Metis is not wedged at all — `axdevice` reads it fine (`flver=1.3.2 bcver=1.4
  clock=800MHz`) and the on-device firmware logs over MMIO (`axlogdevice`); **only the MSI
  (device→host interrupt) path is dead.** A 1970 clock breaks the Axelera Voyager runtime's
  device bring-up — time/cert validation fails and the tooling throws
  `ERROR: ZIP does not support timestamps before 1980` — so the runtime never finishes
  programming the device's interrupt path. The kernel's `metis.ko` mailbox heartbeat then
  waits forever for an MSI the device was never told to send → `IRQ MSI timeout` every 2 s.
  (The same 1970 tell shows up as PAM's `account root has password changed in future` on
  every `sudo`.)
- **Confirm it**:
  ```bash
  date                                               # is it 1970?  <-- the smoking gun
  grep -E '^ *(25[1-9]|2[678][0-9]):' /proc/interrupts | awk '{for(i=2;i<=9;i++)s+=$i}END{print "Metis MSI:",s+0}'
  /opt/av-env/bin/axdevice                           # device IS readable (flver/bcver/clock) => not dead
  /opt/av-env/bin/axdevice report                    # fails: "ZIP does not support timestamps before 1980"
  sudo lspci -vvv -s 0004:01:00.0 | grep -iE 'MSI|Masking'   # host side: Enable+ Count=32/32 Masking 0 (perfect)
  sudo dmesg | grep -iE 'smmu|iommu|fault'           # NO fault => host plumbing flawless, device just never fires
  ```
  The signature is unambiguous: MSI count **frozen at 0**, host MSI capability `Enable+` and
  unmasked, **zero** SMMU faults, and the clock at 1970. The device is alive on the
  control-plane but never delivers an interrupt.
- **Fix (verified)**: set the clock, then let the runtime re-init (it retries on its own; or
  restart `axsystemserver.service`):
  ```bash
  sudo date -u -s "2026-06-27 17:18:16"   # a real UTC time (copy from any synced box)
  sudo hwclock -w                          # persist to the RTC
  ```
  Within seconds the `IRQ MSI timeout` spam **stops**, the Metis MSI vectors in
  `/proc/interrupts` start climbing (0 → hundreds), and inference returns. Verified on this
  unit immediately after: `axrunmodel --seconds 5 ~/voyager-sdk/build/yolo11s-coco-onnx/yolo11s-coco-onnx/1`
  → **dev 469 FPS / system 405 FPS**, 2028 frames, 45 °C; MSI delivered 0 → 1167+.
- **Why a no-battery carrier hits this, and why it "never happened before" (deeper
  mechanism, confirmed from kernel source)**: this carrier has no RTC backup cell, so every
  cold boot starts at 1970. The PMIC RTC (`nvvrs-pseq-rtc`) registers as **rtc0 ~30 s into
  boot**, and the kernel calls `do_settimeofday64()` *unconditionally* at RTC registration
  for the hctosys device (`drivers/rtc/class.c`, no "skip if already set", no build-date
  floor) — so rtc0's **late** probe **stomps the clock back to 1970 *after* early userspace
  already set it**, and `axsystemserver` then brings up Metis at 1970. It "worked before"
  only because those boots had **internet**: `chrony` corrected the clock before the runtime
  ran. On an isolated/offline boot, nothing does — so it surfaced now. It is **not** a kernel
  security guardrail; it's the userspace runtime failing date validation (ZIP<1980 + certs).
- **Keep it fixed — baked into the image, works OFFLINE** (no internet required):
  1. **Kernel** — `CONFIG_RTC_HCTOSYS_DEVICE="rtc1"`
     ([01_extract_and_patch.sh](../scripts/01_extract_and_patch.sh)): points hctosys at the
     early-probing Tegra SoC RTC (rtc1, ~2 s) so the late rtc0 never stomps the clock.
  2. **clock-floor guard** ([03_bake_rootfs.sh](../scripts/03_bake_rootfs.sh)):
     `/usr/local/sbin/jetson_clock_floor.sh` + `jetson-clock-floor.service` (sysinit) + a 45 s
     re-apply timer + an `ExecStartPre` on `axsystemserver` — floors the clock to the
     last-known-good time. **Hardened** after a self-inflicted bug (the early version's `save`
     wrote a 1970 value into the floor during a cold-boot window and then perpetuated it): now
     a hard-coded minimum (`HARD_MIN`), ratchet-up-only `save` that refuses any pre-2023 time,
     and `apply` also writes the RTC. A corrupted/empty floor file can no longer push the
     clock into the past.
  3. **`/usr/lib/clock-epoch`** stamped to the build date — systemd PID1 floors the clock to
     this file's mtime at boot (survives a `/var` wipe).
  4. **chrony** with Cloudflare/Google/NIST servers — corrects to exact time the moment the
     unit is online (on top of the offline floor).
  Manual recovery on an un-fixed image: `sudo date -u -s "<real UTC>"` → `sudo hwclock -w` →
  `axdevice --reload-firmware` (re-triggers Metis bring-up; MSI starts flowing again).
- **Do NOT chase**: `LINK_WAIT_MAX_RETRIES` (this is past H-1), the DTB (byte-identical to
  factory, see F-12), SMMU/IOMMU (no fault logged), driver vermagic (`metis.ko` binds fine),
  or any hardware / cold-drain-the-card theory — the card runs at full FPS the instant the
  clock is sane.

## Logs

Include with any support request:

- **Kernel build**: `tail -2000 BUILD_LOG.md`.
- **Flash**: full `l4t_initrd_flash.sh --showlogs` output.
- **First-boot**: `journalctl -b 0 -u jetson-first-boot.service`.
- **Per-boot tune**: `journalctl -b 0 -u jetson-rt-tune.service`.
- **dmesg**: `dmesg --level=err,warn,crit,alert,emerg`.
- **Vermagic state**: the full output of `sudo /home/j/verify_tuning.sh`.
