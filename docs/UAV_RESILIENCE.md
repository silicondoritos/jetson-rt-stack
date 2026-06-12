---
title: Platform Resilience
layout: default
description: "Phase 7 hardening: systemd watchdog, persistent journald, kdump, security hardening, chrony time sync, brownout guard, PCIe AER, black-box recorder, btrfs data partition, telemetry failover."
nav_order: 20
---

# Platform Hardening (Phase 7)

Phase 7 adds operational hardening for field deployment: a hardware watchdog, persistent logging, time sync, network and SSH hardening, crash capture, and power/PCIe protection for the Metis NPU.

Phase 7 is optional. The baseline (Phases 1-4) flashes and boots without it. Install Phase 7 when you need the device to survive hangs, power sags, and link drops unattended.

Status (2026-06-11): Phase 7 is **installed and exercised live** on the reference device: platform resilience (systemd watchdog 30 s, persistent journald, /tmp on tmpfs, chrony, ufw with SSH allowed, sshd hardening), black-box recorder, brownout guard, PCIe AER monitor, telemetry failover (services installed; Iridium/router idle without hardware), and the btrfs data partition (loop-file mode, 200 GB). The MAVLink watchdog is installed but disabled until a flight controller is attached (`systemctl enable --now jetson-mavlink-watchdog`). The brownout guard supports `AXELERA_POWER_LIMIT_W=0` = no cap (full Metis power) while keeping the link-down watch. Note: activating tmp.mount wipes the ZED IMU daemon's socket. The installer now restarts the ZED chain automatically (TROUBLESHOOTING H-7).

The components split into two groups:

- **General hardening** (sections 1-8): useful on any embedded Linux deployment, not platform-specific. Watchdog, journald, chrony, SSH/UFW hardening, NVMe SMART.
- **Vision-stack-specific** (sections 9-10): brownout guard, PCIe AER monitor, and the crash/security kernel config that backs them. Section 9 requires the Metis NPU.

Companion docs for the larger Phase 7 pieces: [Black-box recorder]({{ '/BLACKBOX' | relative_url }}), [Data partition]({{ '/DATA_PARTITION' | relative_url }}), and [Telemetry failover]({{ '/TELEMETRY_FAILOVER' | relative_url }}).

## What gets installed

[`scripts/install_uav_phase7.sh`](../scripts/install_uav_phase7.sh) is the single entry point. It runs seven install steps, each pre- and post-verified through `step::run` (see [Verification]({{ '/VERIFICATION' | relative_url }})):

1. [`install_uav_resilience.sh`](../scripts/install_uav_resilience.sh): core hardening plus the power and storage config files (this document and [Fine tuning]({{ '/FINE_TUNING' | relative_url }})).
2. [`install_blackbox.sh`](../scripts/install_blackbox.sh): black-box recorder service. See [Black-box recorder]({{ '/BLACKBOX' | relative_url }}).
3. Brownout guard (inline): installs [`axelera_brownout_guard.sh`](../scripts/axelera_brownout_guard.sh) plus its service.
4. PCIe AER monitor (inline): installs [`jetson_pcie_aer_monitor.sh`](../scripts/jetson_pcie_aer_monitor.sh) plus its service. It forwards correctable, non-fatal, and fatal AER counter increases into the black-box event stream. See [Fine tuning]({{ '/FINE_TUNING' | relative_url }}) section 5.
5. [`install_data_partition.sh`](../scripts/install_data_partition.sh): durable btrfs data partition. See [Data partition]({{ '/DATA_PARTITION' | relative_url }}).
6. [`install_telemetry_failover.sh`](../scripts/install_telemetry_failover.sh): mavlink-router fan-out plus the Iridium failsafe relay. See [Telemetry failover]({{ '/TELEMETRY_FAILOVER' | relative_url }}).
7. MAVLink watchdog (inline): installs [`mavlink_watchdog.sh`](../scripts/mavlink_watchdog.sh) plus its service, which flushes the black box on FCU heartbeat loss.

Marker file: `/etc/jetson-av-resilience-installed`.

## General hardening (sections 1-8)

The installer writes these config files at install time. They are the single source of truth for cross-component coordination (see [Fine tuning]({{ '/FINE_TUNING' | relative_url }})):

- `/etc/jetson-av/power.conf`: NVPMODEL, GPU/EMC caps, fan, Metis power cap.
- `/etc/jetson-av/storage.conf`: NVMe write cache policy.
- `/etc/jetson-av/expectations.conf`: driver-loaded loud-fail set.
- `/etc/jetson-av/blackbox.conf`: recorder cadence and topics.

### 1. Hardware and systemd watchdog

```
/etc/systemd/system.conf.d/10-watchdog.conf
  RuntimeWatchdogSec=30s
  RebootWatchdogSec=2min
```

systemd (pid 1) pets the Tegra hardware watchdog at `/dev/watchdog` every 30 s. If pid 1 stops responding (kernel hang, OOM cascade), the hardware forces a reboot at the 2-minute mark rather than leaving the vehicle in a hung state.

Mission-critical units also set a per-service `WatchdogSec`:

- `jetson-blackbox.service`: `WatchdogSec=120`. The recorder must flush within 2 min or systemd restarts it.

To extend this to your own service, add `WatchdogSec=` to its unit and call `sd_notify(0, "WATCHDOG=1")` periodically.

### 2. Persistent journald

```
/var/log/journal/        (created; was missing, so the journal lived in volatile /run/log/journal)
/etc/systemd/journald.conf.d/10-av.conf
  Storage=persistent
  SystemMaxUse=2G
  SystemKeepFree=4G
  SystemMaxFileSize=128M
```

After this, `journalctl -b -1` shows the previous boot's logs. Without it, every reboot wipes the journal.

### 3. /tmp on tmpfs

Stock Ubuntu places `/tmp` on disk. On an autonomous platform that means continuous writes into the same NVMe sectors, which accelerates wear. The installer enables `tmp.mount` to mount `/tmp` as tmpfs (size=2G, nosuid/nodev/strictatime).

### 4. logrotate AV rules

`/etc/logrotate.d/jetson-av` rotates syslog, auth, and kern logs aggressively (7 days) and gives `/var/log/jetson-av/*.log` longer retention (30 days), since those are the AV-specific logs.

### 5. chrony NTP (and optional PTP)

The stock time source, systemd-timesyncd, is coarse. chrony with `makestep 1.0 3` steps the clock sharply within the first 3 polls if it is off, then disciplines smoothly. Accurate time is required to correlate logs across SLAM, inference, and the black-box recorder.

With a GPS PPS source, hook it via `gpsd` and add to `chrony.conf`:

```
refclock SHM 0 refid GPS precision 1e-1 noselect
refclock PPS /dev/pps0 refid PPS lock GPS prefer
```

### 6. SSH hardening

```
/etc/ssh/sshd_config.d/10-av-hardening.conf
  PasswordAuthentication no
  PermitRootLogin no
  ClientAliveInterval 60
  ClientAliveCountMax 2
```

Push operator public keys into `/home/j/.ssh/authorized_keys` at bake time or through your fleet provisioning workflow. With password auth off, an unprovisioned device on the LAN cannot be reached over SSH, which removes the cleartext-password attack surface.

### 7. UFW firewall

```
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow 7400:7500/udp     # FastDDS multicast (ROS 2)
```

Add deployment-specific rules (GCS port, RTSP, telemetry relay) before flying. The UFW policy persists across reboot.

### 8. NVMe SMART

`smartmontools` is enabled and started so you can poll SSD wear, temperature, and remaining life:

```bash
sudo smartctl -a /dev/nvme0n1
sudo nvme smart-log /dev/nvme0
```

Add a periodic check to your monitoring stack. On this platform the NVMe drive is the single most likely physical-failure point.

## Vision-stack-specific hardening (sections 9-10)

Section 9 depends on the Metis NPU. Do not install the brownout guard unless Phase 5 and the Metis driver are active.

### 9. Brownout guard (Axelera Metis)

The Metis NPU can spike to its datasheet peak of ~23 W (23.1 W verified) under full INT8 load. On battery through a DC-DC converter, those spikes can sag the rail enough to brown out the PCIe link, at which point the device disappears from `lspci` and inference stops.

[`axelera_brownout_guard.sh`](../scripts/axelera_brownout_guard.sh) runs as `jetson-brownout-guard.service`:

1. At start: applies `axdevice --set-power-limit 18` (configurable in `/etc/jetson-av/brownout.conf`).
2. Every 5 s: polls `lspci -d 1f9d:` for the Metis device (Axelera AI vendor `1f9d`, device `1100`).
3. On disappearance: emits a black-box event (`metis_lost`) and writes `1` to `/sys/bus/pci/rescan` to try to retrain the link.

Tune `AXELERA_POWER_LIMIT_W` for your power architecture. 18 W is a carrier brownout-budget ceiling, not the device draw (typical application power is 3.5-9 W); raising the cap toward the ~23 W datasheet peak assumes a supply that can absorb the full spike.

### 10. Kernel CONFIG additions

These are already in the AV defconfig ([`scripts/01_extract_and_patch.sh`](../scripts/01_extract_and_patch.sh)):

```
CONFIG_KEXEC=y                   # kdump capability
CONFIG_KEXEC_FILE=y
CONFIG_CRASH_DUMP=y
CONFIG_PROC_VMCORE=y
CONFIG_SECURITY=y
CONFIG_SECURITY_YAMA=y
CONFIG_SECURITY_LOCKDOWN_LSM=y
CONFIG_LSM="yama,lockdown,integrity"
CONFIG_TCG_TPM=y
CONFIG_TCG_TIS=y
CONFIG_HW_RANDOM_TPM=y
```

They enable kdump (full crash-dump capture with `kdump-tools`), Yama LSM (`ptrace_scope=1` enforced), Lockdown LSM (blocks live kernel patching once active), and the TPM TIS interface for hardware RNG and attestation on carriers that have a TPM.

## Verification on a flashed device

```bash
# All Phase 7 services present?
systemctl --no-pager --type=service \
    list-unit-files 'jetson-*.service' tmp.mount

# Watchdog active?
systemctl status systemd                # look for "Runtime watchdog: 30s"
ls /dev/watchdog*

# Persistent journal?
ls /var/log/journal/                    # populated, not empty
journalctl --disk-usage

# Time sync?
chronyc sources                         # shows ^* on the primary source
chronyc tracking                        # offset typically <100 ms

# Firewall?
sudo ufw status verbose

# Marker?
cat /etc/jetson-av-resilience-installed
```

`make verify` runs the full post-flash gauntlet ([`scripts/05_post_flash_validate.sh`](../scripts/05_post_flash_validate.sh)) over SSH, which covers these checks. A return code of 0 means the gauntlet passed. Note: if the device's first boot ran offline, `/opt/av-env` is not yet provisioned and the gauntlet's venv-import step fails. The first-boot service re-runs each boot and completes provisioning once the device gets a network connection; until then, expect that step to fail.

## Disabling components

Each piece is independently controllable through systemd:

```bash
# Disable the brownout guard (for example, on a wall-powered dev unit)
sudo systemctl disable --now jetson-brownout-guard.service

# Lower the journald cap (for example, on a small SSD)
sudo sed -i 's/SystemMaxUse=2G/SystemMaxUse=512M/' \
    /etc/systemd/journald.conf.d/10-av.conf
sudo systemctl restart systemd-journald
```

To skip Phase 7 at first boot (for example, while debugging):

```bash
SKIP_PHASE7=1 sudo /home/j/jetson_first_boot.sh
```

Note: [`jetson_first_boot.sh`](../scripts/jetson_first_boot.sh) does not yet honor `SKIP_PHASE7`. Add the check before relying on it.

## Verify framework

Every Phase 7 install step runs through `step::run` (see [Verification]({{ '/VERIFICATION' | relative_url }})). A full installer run produces a manifest like this:

```
[2026-05-06T18:32:01]  Install platform resilience  PASS  62s
[2026-05-06T18:33:03]  Install black-box recorder   PASS  18s
[2026-05-06T18:33:21]  Install brownout guard       PASS  8s
```

Per-step logs land in `logs/`. To bundle them for support, run `make logs`.
