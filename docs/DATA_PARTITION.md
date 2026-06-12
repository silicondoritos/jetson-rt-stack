---
title: Data Partition
layout: default
description: "Single-NVMe btrfs data partition with zstd:3 compression, weekly scrub timer, and snapshot strategy for data integrity."
nav_order: 22
---

# Durable Data Partition

## Purpose

Flight recordings, ROS bags, and event logs need integrity guarantees that a plain
ext4 partition does not provide. A single flipped bit in a 50 GB bag makes the bag
worthless, and ext4 will not tell you it happened.

This partition uses btrfs on a single NVMe to deliver four properties:

- **Bit-rot detection**: block-level checksums turn silent corruption into a hard I/O error.
- **Compression**: `zstd:3` typically halves the size of bags and JSONL logs.
- **Atomic snapshots**: a flight's state can be captured in constant time, no copy.
- **Periodic scrub**: a weekly timer reads every block and reports bad ones before a mission relies on them.

It is installed by [scripts/install_data_partition.sh](../scripts/install_data_partition.sh)
as part of Phase 7 ([UAV_RESILIENCE.md](UAV_RESILIENCE.md)); the black-box recorder
([BLACKBOX.md](BLACKBOX.md)) is its main tenant. The script is idempotent:
re-running it no-ops any step already done.

**Status (2026-06-11)**: installed and verified live on the reference device in
loop-file mode: the rootfs spans the NVMe, so the installer created the 200 GB
sparse `/opt/jetson-av-data.btrfs`, mounted it at `/var/log/jetson-av/data`
(zstd:3, noatime), migrated `flights/`, installed the weekly scrub timer, and
passed the synthetic write/snapshot/restore probe (8/8 steps). Two installer
bugs were found and fixed in the process: the free-space probe read the last
free region's END OFFSET instead of its SIZE (reporting ~1.9 TB free on a full
disk) and rendered large values in scientific notation that bash arithmetic
rejects; and device-node pre-checks used `[ -f ]`, which is false for block
devices (now `check::blockdev_exists`).

RAID 1 across two drives is the next step up and self-heals on scrub. Single-drive is
what ships today; the RAID path is a TODO gated on a second NVMe (see [Upgrade path](#upgrade-path-add-a-second-drive)).

## What a single NVMe gives you

| Property | Mechanism |
|---|---|
| Bit-rot detection | btrfs block-level CRC32C on data and metadata; a mismatch is an I/O error, not silent corruption |
| Compression | `compress=zstd:3` mount option, typically 2x on ROS bags, JSONL event logs, and dmesg |
| Atomic snapshots | btrfs subvolume snapshot captures a flight's state in constant time with no copy |
| Periodic scrub | systemd timer `jetson-av-btrfs-scrub.timer` runs `btrfs scrub start` every Sunday at 03:00, with a randomized delay |
| No-atime | logs do not bump access timestamps, reducing write amplification on the SSD |

What you **do not** get is redundancy across drives. A bad block on a single drive is
still data loss for that block. Two drives with `DATA_RAID=1` give btrfs raid1, which
mirrors data and metadata and self-heals on scrub. That is a TODO once a second NVMe is added.

## Layout

```
/var/log/jetson-av/
├── data/                                # btrfs mount (subvolume capable)
│   └── flights/                         # subvolume; per-flight subdirs
│       ├── 20260506-180123/
│       │   ├── flight-meta.json
│       │   ├── events.jsonl
│       │   ├── events.sha256
│       │   └── bag/flight_0.mcap
│       └── 20260506-191040/
└── flights -> data/flights              # symlink (compat with jetson_blackbox.sh)
```

The installer migrates any existing `/var/log/jetson-av/flights/` onto the new mount,
then replaces it with the symlink shown above so [scripts/jetson_blackbox.sh](../scripts/jetson_blackbox.sh)
keeps working unchanged.

## Two install modes

[install_data_partition.sh](../scripts/install_data_partition.sh) chooses the mode
automatically based on free space at the end of `/dev/nvme0n1`.

### Mode A: partition (preferred)

If at least `MIN_FREE_GB` (default 100 GB) of free space exists at the tail of `/dev/nvme0n1`:

1. `parted` adds a primary partition spanning the remaining space.
2. `mkfs.btrfs -L jetson-av-data /dev/nvme0n1pN`.
3. Mount at `/var/log/jetson-av/data` with `compress=zstd:3,noatime,space_cache=v2,autodefrag`.
4. fstab entry by UUID.

This is the right choice when the L4T flash did not fill the whole SSD.

### Mode B: loop file (fallback)

If the SSD is fully consumed by other partitions:

1. `truncate -s 200G /opt/jetson-av-data.btrfs` (sparse, consumes disk only as data is written).
2. `mkfs.btrfs -L jetson-av-data /opt/jetson-av-data.btrfs`.
3. Mount with `loop,compress=zstd:3,...` at the same mount point.
4. fstab entry by file path.

A loop file is slightly slower than a real partition. For the write-heavy sequential
workloads here (ROS bags, JSONL) the difference is typically under 5% and below
black-box throughput requirements; measure on the target device before a mission
depends on it.

## Tunables (environment variables)

```bash
NVME_DEV=/dev/nvme0n1            # drive to operate on
MOUNT_POINT=/var/log/jetson-av/data
LOOP_FILE=/opt/jetson-av-data.btrfs
LOOP_SIZE_GB=200
MIN_FREE_GB=100                 # threshold above which a partition is created
SCRUB_DAY=Sun                   # weekly scrub day
```

Override at install time:

```bash
sudo MIN_FREE_GB=50 LOOP_SIZE_GB=100 ./scripts/install_data_partition.sh
```

## Verify

```bash
# Filesystem level
btrfs filesystem df /var/log/jetson-av/data
btrfs filesystem usage -h /var/log/jetson-av/data

# Mount options actually applied
findmnt /var/log/jetson-av/data

# Scrub state
btrfs scrub status /var/log/jetson-av/data
systemctl list-timers | grep jetson-av-btrfs

# Snapshot a flight on demand (flights/ is the subvolume)
sudo btrfs subvolume snapshot -r \
    /var/log/jetson-av/data/flights/<id> \
    /var/log/jetson-av/data/flights/<id>.snap
```

A clean install ends with `btrfs filesystem df` reporting the new mount, the timer
listed by `systemctl list-timers`, and `findmnt` showing `compress=zstd:3` in the
options column.

## Upgrade path: add a second drive

Once a second NVMe is wired, the plan is for a future revision of the script to support `DATA_RAID=1`:

```bash
sudo NVME_DEV2=/dev/nvme1n1 DATA_RAID=1 \
     ./scripts/install_data_partition.sh
```

The planned steps:

1. Add the second drive as a btrfs device: `btrfs device add /dev/nvme1n1 ...`.
2. Convert data and metadata to raid1: `btrfs balance start -dconvert=raid1 -mconvert=raid1 ...`.
3. Verify via a scrub; corrupt blocks then self-heal from the mirror.

The conversion is designed to run in place and preserve existing data.

> This path is not yet implemented. Confirm it has landed in the script before relying on it.

## What lives where

| Path | What | Backed up by |
|---|---|---|
| `/var/log/jetson-av/data/flights/` | Per-flight forensic dirs | btrfs snapshot, scrub |
| `/var/log/jetson-av/*.log` (above the mount) | Service logs | logrotate |
| `/var/log/journal/` | systemd journal | journald `SystemMaxUse=2G` |
| `/etc/jetson-av/` | Configuration | static; restored at next bake |
| `/opt/av-env/` | Python venv | first-boot recreates once the device has internet |

## Troubleshoot

### "btrfs: bdev ... errs: ..."

btrfs detected bit-rot. Mid-flight, the read is a hard I/O error, so the data is not
silently corrupt. Post-flight, `btrfs scrub status` shows the error count. Replace the
SSD before the next mission.

### Mount point gone after reboot

The fstab entry is missing or the device UUID changed. Re-run the installer:

```bash
sudo ./scripts/install_data_partition.sh
```

It detects the existing btrfs and rewrites the fstab entry.

### Scrub takes too long

The scrub service runs with `Nice=15` and `IOSchedulingClass=idle`, so it yields to
flight workloads. On a packed SSD a full scrub can still take hours. Move it to monthly:

```bash
sudo sed -i 's|OnCalendar=.*|OnCalendar=monthly|' \
    /etc/systemd/system/jetson-av-btrfs-scrub.timer
sudo systemctl daemon-reload
```
