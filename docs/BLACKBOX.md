---
title: Black-Box
layout: default
description: "Hash-chained per-flight event log and ROS 2 bag recorder for post-flight forensics and incident correlation."
nav_order: 21
---

# Black-Box Recorder

The black-box recorder captures every flight as a forensic trail so you can reconstruct sensor data and system decisions leading up to an incident. Each flight produces three artifacts in its own directory:

- a ROS 2 bag of the configured topics (camera, IMU, GPS, MAVLink, TF),
- a hash-chained JSON event log that makes tampering detectable, and
- per-flight metadata (build, host, kernel, configuration).

The recorder runs as [jetson-blackbox.service](../scripts/jetson_blackbox.sh), installed by [install_blackbox.sh](../scripts/install_blackbox.sh) as part of Phase 7 ([UAV_RESILIENCE.md](UAV_RESILIENCE.md)). It buffers writes through the ROS 2 bag cache and `sync`s to disk periodically, and it flushes immediately on a `SIGUSR1` signal so the seconds before a link loss or crash reach disk.

Status (2026-06-11): installed and running on the reference device (`jetson-blackbox.service` active; flight data lands on the btrfs data partition at `/var/log/jetson-av/data`, see [DATA_PARTITION.md](DATA_PARTITION.md)). Recording with a real mission graph + FCU events remains to be exercised in the field.

## Layout on disk

```
/var/log/jetson-av/flights/<YYYYMMDD-HHMMSS>/
├── flight-meta.json        ← static metadata (build, host, kernel, config)
├── events.jsonl            ← append-only structured event log
├── events.sha256           ← hash-chain for tamper evidence
└── bag/                    ← ros2 bag recording (mcap or sqlite3)
    └── flight_<n>.mcap
```

The service creates a new directory every time it starts. When a flight exceeds `MAX_FLIGHT_SIZE` (default `2G`), the daemon emits a `blackbox.rotate` event and restarts itself into a fresh subdirectory.

## Event log structure

`events.jsonl` is one JSON object per line:

```jsonl
{"t":"2026-05-06T18:01:23Z","k":"blackbox.start","prev":"GENESIS","p":{"version":"1"}}
{"t":"2026-05-06T18:01:23Z","k":"ros2_bag.start","prev":"a3f9...","p":{"pid":1234,"topics":"/zed/zed_node/rgb ..."}}
{"t":"2026-05-06T18:14:07Z","k":"external","prev":"b210...","p":{"src":"mavlink_wd","e":"heartbeat_lost","v":"7"}}
{"t":"2026-05-06T18:14:07Z","k":"blackbox.flush","prev":"c994...","p":{"reason":"signal"}}
```

- `t`: UTC ISO 8601 timestamp.
- `k`: kind. The daemon emits `blackbox.start`, `blackbox.flush`, `blackbox.rotate`, `blackbox.stop`, `ros2_bag.start`, and `ros2_bag.skipped`. External services emit `external`.
- `prev`: the sha256 of the previous event line, taken from the last line of `events.sha256` (or `GENESIS` for the first event).
- `p`: payload. Its schema depends on `k`.

`events.sha256` mirrors the log: line N is the sha256 of line N of `events.jsonl`, computed over the exact JSON text with no trailing newline (`printf '%s' "$line" | sha256sum`). Because each event embeds the previous line's hash in its `prev` field, altering any past event changes its hash and breaks every hash after it.

To verify a flight's chain, recompute each hash and confirm it matches both the recorded hash and the next line's `prev` field:

```bash
flight=/var/log/jetson-av/flights/20260506-180123
python3 - "$flight" <<'PY'
import hashlib, json, sys, pathlib
flight = pathlib.Path(sys.argv[1])
lines  = flight.joinpath("events.jsonl").read_text().splitlines()
hashes = flight.joinpath("events.sha256").read_text().splitlines()
prev = "GENESIS"
for i, (line, recorded) in enumerate(zip(lines, hashes)):
    got = hashlib.sha256(line.encode()).hexdigest()
    obj = json.loads(line)
    if got != recorded:
        sys.exit(f"line {i}: hash mismatch (recorded {recorded}, got {got})")
    if obj["prev"] != prev:
        sys.exit(f"line {i}: prev mismatch (expected {prev}, got {obj['prev']})")
    prev = got
if len(lines) != len(hashes):
    sys.exit(f"length mismatch: {len(lines)} events, {len(hashes)} hashes")
print(f"OK: {len(lines)} events, chain intact")
PY
```

A `scripts/verify_blackbox_chain.py` helper may ship later; until then, the snippet above is self-contained.

## Configuration

[install_blackbox.sh](../scripts/install_blackbox.sh) writes `/etc/jetson-av/blackbox.conf` with empty topics by default, so the recorder logs events but records no bag until you configure topics:

```sh
# Space-separated ROS 2 topics to record. Empty = no ROS bag (event log only).
ROS_TOPICS=""

# Where to write per-flight directories.
FLIGHT_DIR=/var/log/jetson-av/flights

# Ring buffer length in seconds. Recorded in flight metadata; reserved for
# future use by the bag cache.
RING_SECONDS=120

# Periodic flush interval to disk (seconds).
FLUSH_INTERVAL=30

# Max bytes per flight before rotating to a new subdir.
MAX_FLIGHT_SIZE=2G
```

A typical topic set for the ZED + MAVROS stack:

```sh
ROS_TOPICS="/zed/zed_node/rgb/color/rect/image /zed/zed_node/imu/data /mavros/global_position/raw /mavros/state /tf /tf_static"
```

The daemon records each bag with a 200 MB cache (`--max-cache-size`) and splits the bag at 500 MB (`--max-bag-size`). The config file is written only if absent, so edits survive reinstall. Apply changes with `sudo systemctl restart jetson-blackbox.service`.

`/etc/jetson-av/bag-qos.yaml` defines QoS overrides per topic. The
defaults match the typical ZED + MAVROS setup; tune for your stack:

```yaml
/zed/zed_node/rgb/color/rect/image:
  reliability: best_effort
  history: keep_last
  depth: 1
/mavros/state:
  reliability: reliable
  history: keep_last
  depth: 5
```

## NVENC video encoding

The recorder does not encode video itself. It stores whatever the camera node publishes, so to cut disk I/O on high-rate camera topics, have the upstream node publish pre-encoded H.264. The ZED SDK can encode on the GPU via NVENC and publish compressed frames directly. Configure `zed_camera.launch.py`:

```python
parameters=[{
    "general.svo_compression": 4,        # H.264 GPU encode
    "video.publish_compressed": True
}]
```

Then record the compressed topic instead of the raw one in `ROS_TOPICS`:

```sh
ROS_TOPICS="/zed/zed_node/rgb/color/rect/image/h264 ..."
```

Recording H.264 frames rather than raw images reduces bag write volume by roughly an order of magnitude. NVENC hardware encoding is verified live on this platform: the C++ fusion sample records annotated H.264 through NVENC via its `--record` flag (see [ZEDX_METIS_CPP.md](ZEDX_METIS_CPP.md)). The ROS `publish_compressed` path shown above has not yet been exercised in the reference mission graph, so validate that pipeline end to end on your stack and confirm the bandwidth with `ros2 topic bw <topic>`.

## Runtime control

The black-box runs as `jetson-blackbox.service`:

```bash
# Status
systemctl status jetson-blackbox.service

# Force an immediate disk flush (e.g., before powering off)
sudo kill -USR1 $(systemctl show jetson-blackbox -p MainPID --value)

# Restart (starts a new flight directory)
sudo systemctl restart jetson-blackbox.service

# View live events
tail -f /var/log/jetson-av/flights/$(ls -t /var/log/jetson-av/flights | head -1)/events.jsonl
```

When `FLUSH_BLACKBOX_ON_LOSS=1`, the MAVLink watchdog sends `SIGUSR1` to this service the moment the FCU heartbeat times out, so the seconds before link loss reach disk. Both services install together in Phase 7, [install_uav_phase7.sh](../scripts/install_uav_phase7.sh).

## Other services emitting events

Any service can drop events into the chain by writing one JSON object per line to the named pipe `/var/run/jetson-av-events`:

```bash
echo '{"src":"my_service","e":"sensor_dropout","v":"imu_x"}' \
    > /var/run/jetson-av-events
```

The daemon drains the pipe in the background. Each entry becomes an `external` event whose payload is the JSON you wrote. Non-JSON input is wrapped as `{"raw": "..."}`. Services shipped in this repo that are wired to emit events:

- [axelera_brownout_guard.sh](../scripts/axelera_brownout_guard.sh), `src: "brownout"`: `metis_lost`, `metis_recovered`, `power_cap_set`, `metis_rescan_ok`.
- [mavlink_watchdog.sh](../scripts/mavlink_watchdog.sh), `src: "mavlink_wd"`: `heartbeat_lost`, `heartbeat_recovered`, `mavros_missing`, `watchdog_died`.
- The telemetry failover daemons ([TELEMETRY_FAILOVER.md](TELEMETRY_FAILOVER.md)), `src: "link_monitor"` (`primary_lost`, `primary_recovered`) and `src: "iridium_relay"` (`sbd_sent` and SDK/send errors).

## Retention

Flights are append-only by design, so `logrotate` does not manage them. Implement retention at a higher level to match your operational needs. The example below archives flights older than 30 days and deletes archives older than 90:

```bash
# /etc/cron.daily/jetson-av-flight-retention
#!/bin/sh
find /var/log/jetson-av/flights -mindepth 1 -maxdepth 1 -mtime +30 \
    -exec tar czf {}.tar.gz {} \; -exec rm -rf {} \;
find /var/log/jetson-av/flights -name '*.tar.gz' -mtime +90 -delete
```

## Bundling a flight for incident analysis

```bash
# Single flight
tar czf flight-20260506-180123.tar.gz -C /var/log/jetson-av/flights 20260506-180123

# Latest flight + system logs + manifests
make logs   # produces support-bundle-*.tar.gz at the repo root
```

## Verification

```bash
# Service alive?
systemctl is-active jetson-blackbox.service

# Recent events present in the newest flight?
ls -lh /var/log/jetson-av/flights/$(ls -t /var/log/jetson-av/flights | head -1)/

# Newest flight directory holds events.jsonl, events.sha256, and flight-meta.json
latest=/var/log/jetson-av/flights/$(ls -t /var/log/jetson-av/flights | head -1)
ls "$latest"/events.jsonl "$latest"/events.sha256 "$latest"/flight-meta.json
```

Verify the integrity of a flight's hash chain with the Python snippet in [Event log structure](#event-log-structure).
