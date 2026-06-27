---
title: Operations
layout: default
description: "Day-2 operator guide for the deployed Jetson AV box: the 1970-clock/Metis golden rule, SSH/serial access, GUI vs headless toggle, NPU/Wi-Fi/USB-C checks, and boot recovery. A copy ships on-device as ~/README.md."
nav_order: 6
---

> This guide also ships on the device as `~/README.md` (run `cat ~/README.md` after SSH).

# Jetson AV Box — Operator Guide ("wtf to do")

**Hardware:** Jetson Orin NX 16GB (p3768 carrier, no RTC battery) · PREEMPT_RT kernel
5.15.148-tegra · JetPack 6.2 / L4T R36.4.3 · Axelera Metis NPU · ZED X camera ·
Intel AX210 Wi-Fi/BT (M.2 Key-E) · NVMe rootfs · Realtek GbE on PCIe.

---

## 0. THE GOLDEN RULE — the clock must be sane (>= 2020)

This carrier has **no RTC battery**, so after a full power-off the clock resets to
**1970**. A 1970 clock **breaks the Metis NPU**: the Axelera runtime can't finish
device bring-up (cert/time + `ZIP < 1980` failures), so the NPU never gets interrupts
and `dmesg` spams `axl 0004:01:00.0: IRQ MSI timeout`. Everything else looks fine —
this trap has cost days. **If the NPU is dead, check `date` FIRST.**

- The **clock-floor guard** (`clock-floor.service`) fixes this automatically at every
  boot — it floors the clock to the last-known-good time *before* the Axelera runtime
  starts. Normally you do nothing.
- Manual fix if ever needed:
  ```
  sudo date -u -s "YYYY-MM-DD HH:MM:SS"   # real UTC, copy from a synced machine
  sudo hwclock -w
  ```
- When the box has internet, `chrony` pulls exact time on top of the floor.

---

## 1. Get in (access)

- **SSH over the USB-A ethernet dongle (primary):** from the dev host run
  `ssh j@192.168.66.106`. The host serves DHCP on `enp175s0` (192.168.66.1); the
  dongle leases 192.168.66.100–150. If the IP changed, on the host check
  `cat /var/lib/misc/dnsmasq.leases` or sweep `for n in $(seq 100 150); do ping -c1 -W1 192.168.66.$n; done`.
- **Serial console:** `ttyTCU0` @ 115200 8N1 — 40-pin header pin 8 (TX) / 10 (RX) /
  6 (GND), **3.3 V** (not 5 V tolerant). On the host: `picocom -b 115200 /dev/ttyUSB0`.
- A **black DP/HDMI screen is normal** when headless (§2) — it is NOT a hang. Use
  SSH or serial to confirm the box is up.

---

## 2. GUI vs headless (DP image on/off)

Headless by default (best for streaming tools / inference — no wasted GPU on a desktop).
Toggle any time; `nvidia_drm` loads automatically when the GUI starts:

| Want | Command |
|------|---------|
| GUI **now** (no reboot) | `sudo systemctl isolate graphical.target` |
| Headless **now** | `sudo systemctl isolate multi-user.target` |
| Boot to GUI from now on | `sudo systemctl set-default graphical.target` |
| Boot headless from now on (default) | `sudo systemctl set-default multi-user.target` |

---

## 3. Metis NPU — is it alive?

Runtime lives in `/opt/av-env` (`source /opt/av-env/bin/activate`, or use full paths
in `/opt/av-env/bin`).

- **List the device:** `axdevice` → expect `Device 0: metis-4:1:0 … flver=… clock=800MHz`.
- **Benchmark it:** `axrunmodel --seconds 5 ~/voyager-sdk/build/yolo11s-coco-onnx/yolo11s-coco-onnx/1`
  → ~**405 FPS** system on YOLO11s.
- **If it's dead:**
  1. `date` — wrong/1970? Fix the clock (§0). This is the #1 cause.
  2. `grep msi-metis /proc/interrupts | awk '{for(i=2;i<=9;i++)s+=$i}END{print s}'` —
     should be > 0 and climbing. Stuck at 0 = MSI not flowing (almost always the clock).
  3. `sudo dmesg | grep axl` — repeating `IRQ MSI timeout` = device never came up.

---

## 4. Wi-Fi (Intel AX210, M.2 Key-E / PCIe C1)

- The driver (`iwlwifi`) and firmware (`iwlwifi-ty-a0-gf-a0-*`) are installed. WiFi needs
  PCIe **C1 enabled** in the boot DTB (`/boot/extlinux/extlinux.conf` → `FDT` must point
  at a DTB whose `pcie@14100000` is `okay`, NOT the `*c1off*` one).
- **Check:** `lspci -d 8086:` (card present), `ip link` / `nmcli dev status` (`wlan0`),
  `dmesg | grep iwlwifi`.
- **Connect:** `nmcli dev wifi connect "<SSID>" password "<PASS>"`.
- The AX210 **Bluetooth** half works over USB regardless of C1.
- If `wlan0` is missing: confirm the FDT is a C1-enabled DTB, and
  `dmesg | grep 14100000` — `Link up` = good; `Phy link never came up` = slot/link issue.

---

## 5. USB-C

The old "USB-C kills the kernel" storm (`tegra-xudc … PORTSC = 0xffffffff` flood) is
fixed by a udev rule that keeps the device-mode controller powered. Plug freely.
Recovery-mode **flashing** uses the bootROM USB path and is unaffected by any of this.

---

## 6. If it won't boot

- **Lands in a `bash-5.1#` recovery shell** (serial shows "Finding OTA work dir" →
  drops to shell): the bootloader fell back to Recovery Boot. Fix in UEFI: power on →
  tap `Esc` → **Device Manager → NVIDIA Configuration → L4T Configuration** → set
  **OS chain A status = Normal** and **L4T Boot Mode = ExtLinux** → `F10` → reboot.
- **`extlinux.conf` sanity:** must have exactly one `root=` —
  `grep -c root= /boot/extlinux/extlinux.conf` returns `1`. More than one = mangled
  (restore a `*.good`/backup). Full detail: repo `docs/TROUBLESHOOTING.md` F-11 / F-12.

---

## 7. Key files & services

- `clock-floor.service` + `clock-floor-save.timer` — clock guard. Script
  `/usr/local/sbin/clock-floor`, saved floor in `/var/lib/clock-floor.epoch`.
- `/etc/udev/rules.d/99-tegra-xudc-keepawake.rules` — USB-C storm fix.
- `/boot/extlinux/extlinux.conf` — boot config (single `root=`, C1-enabled FDT).
- Full docs: the **jetson-rt-stack** repo `docs/` — especially `TROUBLESHOOTING.md`
  (H-13 Metis clock, F-11/12/13 boot & USB-C) and `OPERATIONS.md` (this guide).
