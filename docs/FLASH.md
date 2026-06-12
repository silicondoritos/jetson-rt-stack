---
title: Flash
layout: default
description: "Phase 4 flash mechanics: APX recovery mode, l4t_initrd_flash.sh invocation, NVMe targeting, and post-flash validation flow."
nav_order: 11
---

# Flash Guide

This is Phase 4 of the pipeline: it writes the staged rootfs and the custom
PREEMPT_RT kernel to the target's NVMe over USB. It is the operator-facing guide
for flash day, and it assumes Phases 1 to 3 are done and the audit gate is green
(see [BUILD.md](../docs/BUILD.md)). It covers putting the Jetson into APX
recovery mode, what `make flash` does, the first-boot sequence, post-flash
validation, and recovery from a bad flash.

> **WARNING**: Flashing erases the target NVMe completely. Back up
> anything you need before proceeding.

## Standard flow

```bash
make audit               # gate: must be green before flashing
# ... put the Jetson in recovery mode (see below) ...
make flash               # ~15 to 25 minutes
# ... a healthy boot reaches sshd in ~60 s; first boot then provisions and reboots
# ... (the /opt/av-env provisioning step needs internet; it retries each boot until done) ...
make verify              # post-flash gauntlet
```

Or run the full sequence including the audit and verification:

```bash
make ignite              # doctor -> all -> audit -> flash -> verify
```

## Putting the Jetson in recovery mode

1. Power the Jetson **off** completely (pull USB-C; carrier board fully
   unpowered).
2. Locate the **REC** and **GND** pins/headers on the carrier board.
3. With the device unpowered, **short REC to GND** with a jumper or
   tweezers.
4. While holding the short, **plug USB-C** into the rear motherboard
   port. **No hub. No extender. No docking station.** Use a data-rated
   USB-C cable of 1 m or less.
5. Hold the short for ~2 s after power-on, then release.
6. On the host, `lsusb | grep 0955:7323` must show
   `NVIDIA Corp. APX`. If absent, repeat from step 1.

## What `make flash` does

[scripts/04_flash_nvme.sh](../scripts/04_flash_nvme.sh) runs the following
steps:

1. `cd latest_jetson/Linux_for_Tegra`.
2. Runs `sudo ./tools/l4t_flash_prerequisites.sh` to fuse the NVIDIA
   bootloader binaries into the rootfs.
3. Runs `sudo ./apply_binaries.sh`: stages NVIDIA userspace and firmware
   into the rootfs. **This also installs the stock kernel**, so the script
   immediately restores the custom PREEMPT_RT kernel on top (see below).
4. **Restores the custom kernel** across `apply_binaries`: backs up
   `lib/modules/<rel>`, `boot/Image`, and the ZED X `.dtbo` beforehand, puts
   them back after, then **regenerates the initrd** with the RT modules and
   **gates on vermagic** (rootfs and initrd modules must be `preempt_rt`).
   Because NVMe, PCIe, and PHY are built into the kernel (`=y`), the script
   strips those now-built-in entries from the `nv-update-initrd` module list,
   so no `nvme.ko` is needed in the initrd. The flash aborts before any device
   write if the gate fails. See
   [TROUBLESHOOTING.md](../docs/TROUBLESHOOTING.md) F-3 (clobber) and F-6
   (initrd).
5. **Pre-seeds a headless login by default** (`SEED_USER=j` unless explicitly
   overridden; set `SEED_USER=""` to opt out): skips the oem-config first-boot
   wizard and comes up SSH-ready with autologin. This matters because
   `apply_binaries.sh` re-creates the wizard's `default.target` symlink on
   every flash, and an unseeded flash boots into the wizard, which waits
   before sshd with the USB gadget up and answering ping, so it looks exactly
   like a hang. The script hard-fails if the wizard symlink survives the seed
   step.
6. Auto-detects the APX recovery device (`0955:7323`); falls back to a prompt
   if it does not appear within `APX_TIMEOUT` seconds.
7. Installs a udev rule that names the NVIDIA RNDIS gadget `usb0`.
8. Installs the super nvpmodel conf as the default power table (mode 0 =
   MAXN_SUPER on this image).
9. Runs `sudo ./tools/kernel_flash/l4t_initrd_flash.sh` with:
   - `--external-device nvme0n1p1`
   - `-c tools/kernel_flash/flash_l4t_t234_nvme.xml` (partition table)
   - `-p "-c bootloader/generic/cfg/flash_t234_qspi.xml"` (QSPI config)
   - `--showlogs --network usb0`
   - `jetson-orin-nano-devkit internal` (board + storage target)

> **Boot root device:** because this build ships a custom `extlinux.conf`, the
> explicit `root=/dev/nvme0n1p1` must be present, or the kernel inherits the
> board's eMMC default (`mmcblk0p1`) and waits forever at `rootwait` for a disk
> that does not exist on an NVMe-only Orin NX.
> [scripts/03_bake_rootfs.sh](../scripts/03_bake_rootfs.sh) (extlinux) and
> [scripts/01_extract_and_patch.sh](../scripts/01_extract_and_patch.sh)
> (`p3767.conf.common` `CMDLINE_ADD`, the recovery `boot.img` path) both inject
> it. See [TROUBLESHOOTING.md](../docs/TROUBLESHOOTING.md) F-4.

The flash takes 15 to 25 minutes. The Jetson:

1. Boots into a minimal initrd from the host (RNDIS USB Ethernet).
2. Mounts the host's rootfs over NFS.
3. Writes NVMe partitions from the host-staged images.
4. Reboots into the new firmware.

## After flashing

1. Power off the Jetson.
2. **Remove the recovery jumper.** This is critical: with the jumper in
   place, the device re-enters recovery on every boot.
3. Power on. The Jetson boots into the new firmware. A healthy boot reaches
   sshd in about 60 seconds.
4. The `jetson-first-boot.service` runs:
   - `apt-mark hold` plus Pin-Priority -1 for kernel and bootloader packages.
   - Installs the vermagic-aligned `linux-headers-*.deb` from
     `/opt/kernel-headers/`.
   - Builds the `/opt/av-env` venv with `numpy<2.0.0`, PyTorch 2.8.0 (Jetson
     wheel), and Voyager SDK 1.6 (pip wheels). This step requires internet
     access. If the first boot runs offline, `/opt/av-env` is not provisioned;
     the service re-runs on each boot and completes provisioning once the
     device has a network connection (for example an Ethernet cable).
   - Runs `/opt/zed-sdk/install_zed_sdk.sh` if a `.run` was staged
     (`runtime_only` mode, DKMS path skipped, because this build owns
     `sl_zedx.ko`).
   - Injects the RT boot args into `/boot/extlinux/extlinux.conf`.
   - Touches `/home/j/.jetson_initialized` and signals a reboot.
5. Reboot. The RT cmdline activates, and `jetson-rt-tune.service` sets
   nvpmodel mode 0 (MAXN_SUPER by default, overridable via `power.conf`),
   pins IRQs, and applies all per-boot tuning.

> **Blank HDMI is normal.** On Orin, the display stays blank between "Exiting
> boot services" and the desktop: `FRAMEBUFFER_CONSOLE` is off, and
> `earlycon=efifb` does not work because the GOP framebuffer is torn down at
> ExitBootServices. Do not treat a blank screen as a hang. The real "it booted"
> signal is the USB device-mode gadget at `192.168.55.1` (and `/dev/ttyACM*`)
> reaching multi-user. See [TROUBLESHOOTING.md](../docs/TROUBLESHOOTING.md) F-5.

## Validation

```bash
make verify
```

[scripts/05_post_flash_validate.sh](../scripts/05_post_flash_validate.sh) runs
from the host. It:

1. Confirms ICMP and SSH reachability on `192.168.55.1`.
2. Runs `verify_tuning.sh` over SSH on the target to check the RT kernel
   (`/sys/kernel/realtime`), isolated cores (`isolcpus=1-5`), CMA, the vermagic
   of mission-critical modules, and cyclictest jitter under 100 us.
3. Confirms `/usr/src/linux-headers-$(uname -r)/` is present (DKMS).
4. Imports `axelera.runtime`, `torch` (CUDA), and `pyzed.sl` from
   `/opt/av-env`. This step fails until first-boot provisioning has completed
   online: `/opt/av-env` is built only when the device has internet, so on a
   device whose first boot ran offline, expect this step (and therefore
   `make verify` overall) to fail until the device gets a network connection
   and the first-boot service finishes.

Exit 0 means the device is mission-ready. Exit 1 means investigate (see
[RUNBOOK.md](../docs/RUNBOOK.md) R6).

Once `make verify` is green, the freshly flashed device runs the full camera
plus NPU stack: [SAMPLES.md](../docs/SAMPLES.md) has copy-paste run commands,
[ZEDX_METIS_CPP.md](../docs/ZEDX_METIS_CPP.md) covers the C++ samples, and
[BENCHMARKS.md](../docs/BENCHMARKS.md) has the measured throughput and the
reproducible bench harness.

## Board target → nvpmodel table (L4T R36.4.3 / JetPack 6.2)

The flash config string, the module SKU, and the nvpmodel profile are three
independent things. This table shows how they relate on L4T R36.4.3.

| Flash board target | Module | Standard mode | Super Mode (JetPack 6.2+) |
|---|---|---|---|
| `jetson-orin-nano-devkit` | **Orin NX 16GB** (P3767-0000) | `nvpmodel -m 3` → 25 W (1 = 10 W, 2 = 15 W, 4 = 40 W) | `nvpmodel -m 0` → MAXN_SUPER ¹ |
| `jetson-orin-nano-devkit` | Orin NX 8GB (P3767-0001) | `nvpmodel -m 0` → MAXN 20 W / 70 TOPS | no Super profile |
| `jetson-orin-nano-devkit` | Orin Nano 8GB (P3767-0003) | `nvpmodel -m 0` → MAXN 15 W / 40 TOPS | no Super profile |
| `jetson-orin-nano-devkit-super` | **Orin Nano Super 8GB** (P3767-0004) | `nvpmodel -m 0` → MAXN 25 W / 67 TOPS | different SKU, do not confuse |

¹ This image installs the super nvpmodel conf as the default table, so the
  mode IDs above are live-verified on the device (2026-06-10): 0 = MAXN_SUPER,
  1 = 10 W, 2 = 15 W, 3 = 25 W, 4 = 40 W. Older docs that claim mode 0 = MAXN
  25 W or mode 4 = MAXN_SUPER describe the stock (non-super) conf and are
  wrong for this image; confirm with `nvpmodel --available` if in doubt.
  Super Mode still requires the carrier to supply the HV power rail sustained
  and a thermal solution rated for that TDP.

**Rule**: if your module is Orin NX 16GB (P3767-0000), always flash with
`jetson-orin-nano-devkit`. Never use `jetson-orin-nano-devkit-super`: that is a different module SKU (Nano Super). Super Mode on NX is activated
at runtime via nvpmodel, not via the flash config. On this image the flash
step installs the super conf as the default table and `jetson-rt-tune.service`
selects mode 0 (MAXN_SUPER) on every boot, so no manual step is needed.

## Recovery from a bad flash

- If the device fails to boot after flashing, re-enter recovery mode and
  re-flash.
- If `extlinux.conf` was overwritten by a later package upgrade, run
  `sudo /home/j/jetson_first_boot.sh` to re-inject the RT args. It is idempotent
  after marker removal (`sudo rm /home/j/.jetson_initialized`).
- If a vermagic mismatch appears post-flash, never run `insmod --force`.
  Re-flash from a clean rebuild. See
  [VERMAGIC_STRATEGY.md](../docs/VERMAGIC_STRATEGY.md).

## Common errors

| Error | Cause | Fix |
|---|---|---|
| Hangs at "Waiting for target to boot-up" | RNDIS gadget not enumerated | [RUNBOOK.md](../docs/RUNBOOK.md) R5 |
| Error 3 / 202 | USB chain (hub, autosuspend) | direct port; `echo -1 > /sys/module/usbcore/parameters/autosuspend` |
| ECID blank | Jetson not in recovery mode | repeat the recovery procedure |
| Flash succeeds, no boot | Wrong board target | confirm `jetson-orin-nano-devkit internal` matches |

For the full failure-mode table see
[TROUBLESHOOTING.md](../docs/TROUBLESHOOTING.md) section F.
