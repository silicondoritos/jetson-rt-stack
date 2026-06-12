---
title: Telemetry Failover
layout: default
description: "Doodle Labs primary + RockBLOCK 9704 Iridium IMT secondary failover wired through mavlink-router with automatic switchover."
nav_order: 23
---

# Telemetry Failover: Doodle Labs Primary + Iridium IMT Failsafe

## Purpose

Keep a telemetry link to the ground control station (GCS) when the primary radio drops. The Doodle Labs Helix mesh radio is the high-bandwidth primary. The RockBLOCK 9704 Iridium IMT modem is the low-bandwidth failsafe over satellite, independent of line of sight to the GCS.

This stack is pure userspace. The only kernel dependency is `CONFIG_USB_SERIAL_FTDI_SIO=m`, set in the AV defconfig (see [01_extract_and_patch.sh:258](../scripts/01_extract_and_patch.sh#L258)), so the RockBLOCK 9704 enumerates as `/dev/ttyUSB0` over FTDI USB-serial. The installer is [install_telemetry_failover.sh](../scripts/install_telemetry_failover.sh), run as part of Phase 7 ([install_uav_phase7.sh](../scripts/install_uav_phase7.sh); see [UAV_RESILIENCE.md](UAV_RESILIENCE.md)).

Status (2026-06-11): the installer has run on the reference device: `jetson-av-mavlink-router.service` and `jetson-av-iridium-relay.service` are installed and correctly idle (no Doodle Labs radio, RockBLOCK modem, or flight controller attached; the operator plans a Pixhawk). End-to-end failover remains unverified until that hardware arrives. The sections below describe what the installer sets up and how the stack behaves on hardware.

## Architecture

```
                    ┌────────────┐
   FCU (Pixhawk 6X) │ TELEM UART │  /dev/ttyTHS1  @ 921600
                    └─────┬──────┘
                          │
                          ▼
              ┌────────────────────────┐
              │    mavlink-router      │  /etc/jetson-av/mavlink-router.conf
              │  (fan-out daemon)      │
              └────┬───────┬────────┬──┘
                   │       │        │
        ┌──────────┘       │        └─────────────┐
        ▼                  ▼                      ▼
   UDP :14550        TCP :5760             UDP :14540 (local)
   ┌───────────┐    ┌──────────┐          ┌───────────┐
   │ Doodle    │    │ Iridium  │          │  MAVROS   │
   │ Labs      │    │ IMT      │          │  (ROS 2)  │
   │ Helix     │    │ relay    │          └───────────┘
   │ → GCS     │    │ → modem  │
   └───────────┘    └──────────┘
                           │
                           ▼
                    /dev/ttyUSB0
                    RockBLOCK 9704
                    (Iridium IMT)
                           │
                           ▼
                  Iridium constellation
                           │
                           ▼
                  GCS via Rock7 webhook
```

mavlink-router takes one input (the FCU UART) and fans out to multiple endpoints. Each endpoint is independent by design: if the Doodle Labs link goes down, the Iridium relay continues to read from the same local TCP server. This switchover path has not been exercised on the current device.

## Components installed by the script

| Component | Path | What it does |
|---|---|---|
| `mavlink-router` | `/usr/bin/mavlink-routerd` | Fan-out daemon |
| Router config template | `/etc/jetson-av/mavlink-router.conf` | Endpoints (FCU UART + GCS UDP + local TCP/UDP) |
| Main config | `/etc/jetson-av/telemetry-failover.conf` | Tunables |
| Iridium relay | `/usr/local/bin/jetson-av-iridium-relay` | Pulls from TCP :5760, sends IMT packet via JSPR JSON to `/dev/ttyUSB0` |
| Link monitor | `/usr/local/bin/jetson-av-link-monitor` | Watches GCS heartbeat, flips `/run/jetson-av-link-state` |
| Router service | `jetson-av-mavlink-router.service` | systemd unit; restart=always |
| Iridium service | `jetson-av-iridium-relay.service` | systemd unit; depends on router + monitor |
| Link monitor service | `jetson-av-link-monitor.service` | systemd unit |

## Configuration (the only file you typically edit)

`/etc/jetson-av/telemetry-failover.conf`:

```sh
FCU_TTY=/dev/ttyTHS1          # Pixhawk TELEM2 to Jetson UART1; verify with: dmesg | grep tty
FCU_BAUD=921600
PRIMARY_GCS_HOST=192.168.10.1 # GCS reachable via Doodle Labs Helix
PRIMARY_GCS_PORT=14550
IRIDIUM_MODEL=9704            # 9704 (current); 9603/9602 legacy AT path also supported
IRIDIUM_TTY=/dev/ttyUSB0      # RockBLOCK 9704 (FTDI USB-serial)
IRIDIUM_BAUD=230400           # 230400 for the 9704; 19200 for the 9602/9603
SBD_INTERVAL_NORMAL=60        # cadence when primary is healthy
SBD_INTERVAL_DEGRADED=15      # cadence when primary is down
PRIMARY_TIMEOUT=10            # seconds without GCS heartbeat before degraded
```

`/dev/ttyTHS0` is the debug console: do not use it for MAVLink. Confirm the FCU UART mapping on the actual carrier with `dmesg | grep tty` before a mission.

After edits:

```bash
sudo systemctl restart jetson-av-mavlink-router.service \
                       jetson-av-link-monitor.service \
                       jetson-av-iridium-relay.service
```

## Cadence and packet contents

The Iridium relay sends a binary packet every `SBD_INTERVAL_NORMAL` seconds (default 60s) when the primary link is healthy, and every `SBD_INTERVAL_DEGRADED` seconds (default 15s) when degraded.

The payload is a fixed 38-byte little-endian struct (`struct.pack("<IiiifffffH", ...)`). The fields, in order:

| Field | Type | Source MAVLink message |
|---|---|---|
| timestamp_unix | uint32 | `time.time()` |
| latitude_e7 | int32 | `GLOBAL_POSITION_INT.lat` |
| longitude_e7 | int32 | `GLOBAL_POSITION_INT.lon` |
| altitude_mm | int32 | `GLOBAL_POSITION_INT.alt` |
| roll_rad | float32 | `ATTITUDE.roll` |
| pitch_rad | float32 | `ATTITUDE.pitch` |
| yaw_rad | float32 | `ATTITUDE.yaw` |
| voltage_v | float32 | `SYS_STATUS.voltage_battery / 1000` |
| current_a | float32 | `SYS_STATUS.current_battery / 100` |
| throttle | uint16 | `RC_CHANNELS.chan3_raw` |

Iridium IMT billing depends on the active plan. Mobile-originated traffic is metered per message, so cadence drives cost directly. A 30-minute flight at the 60s normal cadence sends about 30 packets; at the 15s degraded cadence it sends about 120. Set `SBD_INTERVAL_NORMAL` and `SBD_INTERVAL_DEGRADED` to match your plan and budget, and confirm current per-message pricing with your IMT provider.

To extend the packet (for example airspeed, GPS satellite count, or flight mode), edit [jetson-av-iridium-relay](../scripts/install_telemetry_failover.sh): the `struct.pack(...)` call in `pack_payload()` is the only place to change.

## Verify on the device

These checks apply once [install_uav_phase7.sh](../scripts/install_uav_phase7.sh) has been run on the device. On the reference device the installer has run and the services are in place; without the radio, modem, and FCU attached they sit idle, so the link-state and SBD checks below only become meaningful once that hardware is connected.

```bash
# Services healthy?
systemctl is-active jetson-av-mavlink-router.service \
                    jetson-av-link-monitor.service \
                    jetson-av-iridium-relay.service

# Router stats
journalctl -u jetson-av-mavlink-router.service -f

# Current link state (ok | degraded)
cat /run/jetson-av-link-state

# See SBD packets being sent (relay emits an "sbd_sent" event per packet)
journalctl -u jetson-av-iridium-relay.service -f

# Talk to the FCU directly via the local TCP server
nc 127.0.0.1 5760 | xxd | head     # raw mavlink stream
```

## Black-box integration

Both daemons emit events into `/var/run/jetson-av-events`. The
black-box recorder, when installed, drains the pipe into the per-flight `events.jsonl`:

```jsonl
{"src":"link_monitor","e":"primary_lost","v":"15"}
{"src":"iridium_relay","e":"sbd_sent","v":38}
{"src":"link_monitor","e":"primary_recovered","v":"1"}
```

A post-flight forensic review can therefore correlate exactly when the link dropped, when failover started, and which telemetry packets made it out over Iridium. See [BLACKBOX.md](BLACKBOX.md) for the recorder.

## Troubleshoot

### "no /dev/ttyUSB0" at install time

The 9704 uses FTDI USB-serial and needs `CONFIG_USB_SERIAL_FTDI_SIO=m`. Confirm the kernel config and the device:

```bash
zcat /proc/config.gz | grep CONFIG_USB_SERIAL_FTDI_SIO
# expect: CONFIG_USB_SERIAL_FTDI_SIO=m
modprobe ftdi_sio 2>&1
lsusb | grep FTDI
```

The config ships in the AV defconfig (see [01_extract_and_patch.sh:258](../scripts/01_extract_and_patch.sh#L258)). If it is missing, add it to the defconfig and rebuild the kernel.

### Iridium relay cannot connect to mavlink-router

The relay retries every 5s. Confirm the router is up with `systemctl status jetson-av-mavlink-router.service`, then check `/var/log/jetson-av/mavlink-router.log` for FCU UART errors.

### RockBLOCK 9704 SDK not found

The relay loads the Rock7 RockBLOCK-9704 Python SDK lazily. If the SDK is absent, the relay logs the install instruction, emits an `sdk_missing` event, and exits so systemd holds it in restart back-off. Install the SDK on the device:

```bash
pip install rockblock9704   # Rock7 SDK; JSPR JSON protocol
```

### Iridium link is up but the GCS receives no packets

Verify the IMT account is active and the modem has a clear sky view of the antenna. Check for send errors with `journalctl -u jetson-av-iridium-relay.service`.

### Cost runs hot

The default `SBD_INTERVAL_NORMAL=60` is conservative. Raise it to `300` (5 minutes) for slow-changing missions. `SBD_INTERVAL_DEGRADED=15` is aggressive: `30` halves the message rate during degraded periods. Edit `/etc/jetson-av/telemetry-failover.conf` and restart the services.

### Doodle Labs link goes flaky without fully dropping

`PRIMARY_TIMEOUT=10` can flap between ok and degraded. Increase it to `30` to dampen the state change.

## Not yet implemented

- Cellular failsafe (M.2 LTE/5G modem). The kernel already has `CONFIG_USB_USBNET=m` and `CONFIG_USB_NET_RNDIS_HOST=m` (see [01_extract_and_patch.sh:261](../scripts/01_extract_and_patch.sh#L261)), but the systemd-networkd config is not automated. Configure it manually by dropping `/etc/systemd/network/30-cellular.network` per the modem vendor.
- MAVLink over MQTT for IoT-style telemetry tunneling. Stretch goal.
- Bidirectional GCS commands over Iridium mobile-terminated (MT) traffic. The current relay is mobile-originated only. The RockBLOCK supports MT, but this script does not yet wire it in.
- Adaptive cadence based on flight phase. Cadence is fixed by config today. A future version could derive it from `MISSION_CURRENT` or `EXTENDED_SYS_STATE` to send aggressively only during cruise.
