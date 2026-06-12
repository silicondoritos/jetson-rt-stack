---
title: Fleet Manufacturing
layout: default
description: "Phase 6 fleet manufacturing: release tarball generation, batch flash pipeline, per-unit identity injection, and audit trail."
nav_order: 30
---

# Fleet Manufacturing, Producing N Identical Jetsons

One audited build produces N units, each with a unique identity, full provenance, and an audit trail. This page is for build-host and flash-station operators. See also: [Runbook]({{ '/RUNBOOK' | relative_url }}), [Build: Reproducibility]({{ '/BUILD#reproducibility' | relative_url }}), and [Golden Image]({{ '/GOLDEN_IMAGE' | relative_url }}) (clone a fully customized unit instead of flashing base firmware).

Status: the fleet tooling on this page (release packaging, batch flash, per-unit identity, audit trail) is provided by the repo and has not yet been verified end to end on a device batch. The single-device path it is built from is live-verified on the reference unit (2026-06-11): flash, boot, RT kernel, Metis inference, and ZED X camera, with measured throughput in [Benchmarks]({{ '/BENCHMARKS' | relative_url }}).

## Big picture

```
        ┌──────────────────────────┐
        │ make all && make audit   │   on a build host (once per release)
        └────────────┬─────────────┘
                     │
        ┌────────────▼─────────────┐
        │ make release VERSION=…   │   produces release-vX.Y.Z.tar.gz
        └────────────┬─────────────┘
                     │ distribute to flash stations
                     ▼
        ┌──────────────────────────────────────┐
        │ tar xzf release-vX.Y.Z.tar.gz        │
        │ ./scripts/flash_release.sh           │  one device at a time
        │   OR                                 │
        │ make flash-batch FLEET=fleet.csv     │  loop over manifest
        └──────────────┬───────────────────────┘
                       │
        ┌──────────────▼─────────────────────────┐
        │ Per-device first-boot:                 │
        │  • personalize_first_boot.sh           │  unique hostname + SSH keys
        │  • install Phase 7 (if staged)         │  watchdog, blackbox, etc.
        │  • install Phase 5 (if staged)         │  OpenCV-CUDA, ROS, Nav2…
        │  • record /etc/jetson-av-build.json    │  on-device provenance
        └──────────────┬─────────────────────────┘
                       │
        ┌──────────────▼─────────────────────────┐
        │ make verify  (SSH, post-flash gauntlet)│
        │ → fleet_log.csv row  PASS/FAIL         │
        └────────────────────────────────────────┘
```

Note on the first-boot box: the Phase 5 and Phase 7 installers run only
if they were staged at bake time, and the `/opt/av-env` Python
environment is provisioned only when the device has internet access.
The first-boot service re-runs on each boot and completes provisioning
once the device has a network. Both stacks are installed and verified
live on the reference device; see [AV Stack]({{ '/AV_STACK' | relative_url }})
and [UAV Resilience]({{ '/UAV_RESILIENCE' | relative_url }}).

## Step 1, Build & audit ONCE

On the build host:

```bash
make doctor             # preflight
make all                # extract -> build -> bake (60 to 90 min)
make audit              # gate; refuses if vermagic / RT / DTBO drift
```

The build is reproducible (`SOURCE_DATE_EPOCH` plus a locked toolchain, see
[Build: Reproducibility]({{ '/BUILD#reproducibility' | relative_url }})). Capture a checksum to use as the fleet ground truth:

```bash
sha256sum latest_jetson/Linux_for_Tegra/kernel/Image \
          latest_jetson/Linux_for_Tegra/staging/kernel-headers/*.deb \
          latest_jetson/Linux_for_Tegra/kernel/dtb/*.dtbo \
          > batch-anchor.sha256
```

## Step 2, Package as a release

```bash
make release VERSION=v1.0.0
# Produces:
#   releases/release-v1.0.0.tar.gz
#   releases/release-v1.0.0.sha256
#   releases/release-v1.0.0.manifest.json
#   releases/release-v1.0.0.sig          (only if GPG_KEY set)
```

Optional GPG signature:

```bash
GPG_KEY=YOUR_KEY_ID make release VERSION=v1.0.0
```

Each step in `release.sh` is pre/post-verified; logs land in `logs/`.

The release tarball is self-contained: it does not need the source
repo, Docker, or the Bootlin toolchain. A flash station only needs:

- Linux x86_64 with sudo, USB, and an NFS server.
- The release tarball.

## Step 3, Author your fleet manifest

Create `fleet.csv` (or seed from the example: `make fleet-init`):

```csv
device_label,hostname,static_ip,notes
av-01,node-01,192.168.10.11,prototype unit
av-02,node-02,192.168.10.12,
av-03,node-03,,DHCP only
av-04,node-04,192.168.10.14,returned from field
```

Schema:

| Column | Required | Effect |
|---|---|---|
| `device_label` | yes | Recorded in `fleet_log.csv` and embedded in the on-device personalization marker |
| `hostname` | no | Sets the device's hostname at first boot. If empty, derived from MAC (`jetson-XXXXXX`) |
| `static_ip` | no | Configures systemd-networkd with this `/24`. Empty = DHCP |
| `notes` | no | Free text; preserved in the per-device config and fleet log |

## Step 4, Flash, one or many

### Single device

```bash
DEVICE=av-07 make flash-one
```

Equivalent to:

```bash
./scripts/flash_one.sh av-07
```

This runs:

1. `pre_flash_audit.sh` (gate)
2. `04_flash_nvme.sh` (auto-detects APX with 60s timeout, falls back to
   prompt)
3. Wait up to 120s for `192.168.55.1` to come up
4. Sleep 90s for first-boot service to complete + reboot
5. `05_post_flash_validate.sh` (full gauntlet)
6. Append result to `fleet_log.csv`

### Batch

```bash
make flash-batch FLEET=fleet.csv
```

For every row in the CSV, the operator is prompted to put the next
device into recovery mode. Press ENTER to flash; type `skip` to skip
that row. The `flash_batch.sh` script:

- Stages per-device personalization config in
  `latest_jetson/Linux_for_Tegra/rootfs/etc/jetson-av-fleet/device.conf`
  before each flash. This is what the on-device
  `personalize_first_boot.sh` reads.
- Continues past failures (`STRICT=0`) so one bad device doesn't kill
  the batch.
- Prints a per-device PASS/FAIL summary at the end.
- Appends every result to `fleet_log.csv`.

### Distributable workflow (release tarball, no source repo)

On a flash station:

```bash
tar xzf release-v1.0.0.tar.gz
cd release-v1.0.0
DEVICE=av-07 ./scripts/flash_release.sh
```

The release script does a strict subset of `flash_one.sh` (no Docker, no
audit-gate against the source, the audit was already done at release
time, captured in `manifest.json`).

## Step 5, Per-device identity (automatic)

Every flashed device runs `personalize_first_boot.sh` as the FIRST
action in `jetson_first_boot.sh`. It:

1. Reads `/etc/jetson-av-fleet/device.conf` (staged by `flash_batch.sh`).
   If missing, derives a unique hostname from the MAC (last 6 hex chars).
2. Sets the hostname (`hostnamectl set-hostname …`) and updates
   `/etc/hosts`.
3. Regenerates SSH host keys. Without this, every device boots with the
   keys baked into the rootfs tarball, and SSH "host key changed"
   warnings cascade across the fleet.
4. If `STATIC_IP` was specified, writes a systemd-networkd file pinning
   the wired interface to that address.
5. Touches `/etc/jetson-av-personalized` (marker so re-runs no-op).

To inspect a device's identity:

```bash
ssh j@node-07 jetson-av-version
# or:
ssh j@node-07 jetson-av-version --json   # for scripts
```

This prints the kernel release, vermagic, the full BUILD_MANIFEST.json (commit,
toolchain, defconfig sha), and the personalization details. This is the
on-device provenance record: every device answers "what build are you?" over SSH.

## Step 6, Validate every device before declaring batch done

`flash_one.sh` (and therefore `flash_batch.sh`) ends with
`05_post_flash_validate.sh`, which:

- Pings `192.168.55.1`, opens SSH
- Runs the on-target `verify_tuning.sh` gauntlet (RT kernel, isolated
  cores, CMA, vermagic of `sl_zedx`/`metis`/`max9296`, cyclictest,
  MAXN_SUPER power mode (mode 0 in the super conf table), hardware
  presence)
- Confirms `/usr/src/linux-headers-$(uname -r)/` is present (DKMS ready)
- Probes `/opt/av-env` and attempts the `torch` (CUDA) import. This
  step fails until `/opt/av-env` has been provisioned, which the
  first-boot service does only when the device has internet access; it
  re-runs each boot and completes provisioning once a network is
  available. The `axelera.runtime` (Voyager) and `pyzed.sl` (ZED SDK)
  imports are reported as expected-fail when their userspace is not yet
  installed. On the provisioned reference device the venv-import step
  passes.

Exit 0 means the device passed the full gauntlet and gets `PASS` in
`fleet_log.csv`. Any other exit code records `VALIDATION_FAIL`.

## Step 7, Audit trail

Two append-only files capture the entire fleet history:

- **`fleet_log.csv`**: every flash event:

  ```csv
  timestamp,operator,device_label,build_sha256,kernel_release,vermagic,result
  2026-05-06T17:45:00Z,j,av-01,abc123…,5.15.148-tegra,"… SMP preempt_rt …",PASS
  2026-05-06T18:01:33Z,j,av-02,abc123…,5.15.148-tegra,"… SMP preempt_rt …",VALIDATION_FAIL
  ```

- **`logs/STEP_MANIFEST.tsv`**: every pre/post-gated step across every
  invocation. See [Verification]({{ '/VERIFICATION' | relative_url }}).

Quick summary:

```bash
make fleet-status
```

## Operations recipes

### Re-flash a device that came back from the field

```bash
DEVICE=av-07 make flash-one
```

The `personalize_first_boot.sh` runs again at the new first boot
(because the marker was wiped by the flash) and restores hostname /
static IP from the same `device.conf`.

### Audit which devices have which build

```bash
column -t -s, fleet_log.csv | sort -k4 | uniq -f3 -c | sort -rn
# → counts per build_sha256
```

### Find a specific device by hostname

```bash
grep node-07 fleet_log.csv | tail -1
```

### Replay the build that flashed a device

The `BUILD_MANIFEST.json` row in `fleet_log.csv` includes `git_head`.
Check out that commit on the build host and `make all`: the
reproducibility hooks (`SOURCE_DATE_EPOCH`, `LC_ALL=C`) reproduce the
exact same kernel `Image` SHA. Compare to `/etc/jetson-av-build.json` on
the device to confirm.

## Troubleshooting

### `make flash-batch` hangs on first device

The batch script calls `flash_one.sh` which calls `04_flash_nvme.sh`,
which auto-detects APX recovery mode with a 60s timeout. If your wiring is slow,
override:

```bash
APX_TIMEOUT=120 make flash-batch FLEET=fleet.csv
```

### Two devices appear with the same hostname

Either both flashed without `device.conf` AND have the same MAC (very
rare), or `personalize_first_boot.sh` failed. SSH in with the IP:

```bash
ssh j@<ip> 'cat /etc/jetson-av-personalized'
```

If empty, manually re-run:

```bash
ssh j@<ip> 'sudo /home/j/personalize_first_boot.sh && sudo reboot'
```

### Release tarball builds but fails on the flash station

The `release.sh` excludes `source/` and `kernel/kernel-jammy-src/` to
keep size down (~3 GB → ~1 GB). The flash station only needs the
already-compiled kernel + rootfs + bootloader + tools. If a flash-station
script needs something from `source/`, it's a bug, file a report and
include the `release-vX.Y.Z.manifest.json`.

### A device in the batch fails, what stays consistent?

The batch continues with the next device (`STRICT=0`). The failed
device:

- Has its row in `fleet_log.csv` with `VALIDATION_FAIL`
- Has per-step logs under `logs/<timestamp>_*.log`
- Was attempted to flash; the partition write may or may not have
  succeeded. Re-flash the same device label after fixing the issue:
  `DEVICE=av-07 make flash-one`

### How do I sign releases for chain-of-custody?

```bash
GPG_KEY=YOUR_KEY make release VERSION=v1.0.0
```

Produces `releases/release-v1.0.0.sig` (detached ASCII-armored). Verify
on the flash station:

```bash
gpg --verify release-v1.0.0.sig release-v1.0.0.tar.gz
```

The sha256 + signature + `manifest.json` together form your provenance
chain: signed manifest → tarball → kernel Image SHA → flashed device.

## Files this phase introduces

| Path | Purpose |
|---|---|
| `versions.env` (existing) | Pinned versions consumed by every script |
| `fleet.csv.example` | Template for `fleet.csv` |
| `fleet.csv` (gitignored) | Operator's fleet manifest |
| `fleet_log.csv` (gitignored) | Append-only flash history |
| `releases/` (gitignored) | Output of `make release` |
| `logs/` (gitignored) | Per-step logs + `STEP_MANIFEST.tsv` |
| `scripts/release.sh` | Build → tarball + sha + manifest + (optional sig) |
| `scripts/flash_release.sh` | Flash from a release tarball without source repo |
| `scripts/flash_one.sh` | Single-device flash + verify + log |
| `scripts/flash_batch.sh` | Loop over `fleet.csv` |
| `scripts/personalize_first_boot.sh` | Per-device hostname + SSH keys + static IP |
| `scripts/jetson-av-version` | On-target identity probe |
| `Makefile` targets `release / flash-one / flash-batch / fleet-status / fleet-init` | Operator interface |
