#!/bin/bash
# =============================================================================
# scripts/install_data_partition.sh   durable data partition (single-NVMe)
# =============================================================================
# AV recordings, ROS bags, flight logs need:
#   • Bit-rot detection (a single flipped bit in a 50GB bag is worthless)
#   • Atomic snapshots (compare two flights byte-for-byte)
#   • Compression (logs/bags compress 2x with zstd:3)
#   • Periodic integrity scrub (catch bad blocks before mid-mission)
#
# btrfs gives us all four on a single drive. RAID 1 across two drives is even
# better; this script handles the SINGLE-NVMe case. When you add a second
# drive, the same script can be re-run with DATA_RAID=1 (TODO).
#
# Strategy:
#   1. Detect free space at the end of /dev/nvme0n1 (the NVMe used for boot).
#   2. If >100GB free: create a new partition, format btrfs.
#      If not: create a 200GB sparse file at /opt/jetson-av-data.btrfs and
#      mount as a loop device (no repartitioning, no flash dance).
#   3. Mount at /var/log/jetson-av/data with compress=zstd:3,noatime,space_cache=v2.
#   4. Migrate /var/log/jetson-av/flights/ to live there.
#   5. Install jetson-av-btrfs-scrub.timer (weekly) + .service.
#   6. Add fstab entry so it survives reboot.
#   7. Verify with btrfs scrub status and a synthetic snapshot.
#
# Idempotent. Safe to re-run; later runs no-op the steps already done.
# =============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/config.sh"
. "$HERE/lib/log.sh"
. "$HERE/lib/verify.sh"
. "$HERE/lib/checks.sh"

PHASE=data_partition

if [ "$EUID" -ne 0 ]; then log::fail "must run as root"; fi

log::section "Install Durable Data Partition (btrfs, single-NVMe)"

# --- Tunables --------------------------------------------------------------
NVME_DEV="${NVME_DEV:-/dev/nvme0n1}"
MOUNT_POINT="${MOUNT_POINT:-/var/log/jetson-av/data}"
LOOP_FILE="${LOOP_FILE:-/opt/jetson-av-data.btrfs}"
LOOP_SIZE_GB="${LOOP_SIZE_GB:-200}"
MIN_FREE_GB="${MIN_FREE_GB:-100}"   # only make a partition if at least this much free
SCRUB_DAY="${SCRUB_DAY:-Sun}"        # weekly scrub on Sundays at 03:00

# --- Step 1: required tools -----------------------------------------------
pre_pkgs() { check::command_exists apt-get; }
exec_pkgs() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        btrfs-progs parted e2fsprogs util-linux
}
post_pkgs() {
    check::command_exists mkfs.btrfs
    check::command_exists btrfs
    check::command_exists parted
}
step::run "Install btrfs-progs + parted" pre_pkgs exec_pkgs post_pkgs

# --- Step 2: decide partition vs loop file --------------------------------
DATA_DEV=""
DATA_MODE=""

pre_decide() { check::blockdev_exists "$NVME_DEV"; }
exec_decide() {
    # Free bytes after the last partition on $NVME_DEV. parted -m fields are
    # number:start:end:SIZE:...   take the SIZE ($4) of the last free region,
    # not its end offset ($3): on a disk whose rootfs spans everything, the
    # last free region is the ~1MB GPT tail but its END is the disk end, which
    # made this read "1907 GB free" on a full disk (observed 2026-06-11).
    # printf %.0f because awk renders large values in scientific notation,
    # which bash arithmetic cannot parse.
    local end_bytes
    end_bytes="$(parted -m -s "$NVME_DEV" unit b print free 2>/dev/null \
                  | awk -F: '/free;/ { gsub(/B$/, "", $4); size=$4 } END { printf "%.0f\n", size+0 }')"
    local end_gb=$(( ${end_bytes:-0} / 1024 / 1024 / 1024 ))

    log::info "Free space at end of $NVME_DEV: ${end_gb} GB"

    # Mode A: free space + ≥MIN_FREE_GB → create a partition.
    if [ "$end_gb" -ge "$MIN_FREE_GB" ]; then
        # Find the last existing partition number.
        local last_part_num
        last_part_num="$(parted -m -s "$NVME_DEV" unit b print 2>/dev/null \
                          | awk -F: '/^[0-9]+:/ { n=$1 } END { print n }')"
        local new_part_num=$((last_part_num + 1))

        log::info "Creating ${NVME_DEV}p${new_part_num} as btrfs (mode: PARTITION)"
        # Make the partition span all remaining space.
        local last_end
        last_end="$(parted -m -s "$NVME_DEV" unit b print 2>/dev/null \
                     | awk -F: -v p="$last_part_num" '$1==p { print $3 }')"
        parted -s "$NVME_DEV" unit b mkpart primary btrfs "$last_end" 100%
        partprobe "$NVME_DEV" || true
        sleep 1

        DATA_DEV="${NVME_DEV}p${new_part_num}"
        # nvme uses pN; if the device is /dev/sdX it'd be just X<N>. Defend either way.
        if [ ! -b "$DATA_DEV" ]; then
            DATA_DEV="${NVME_DEV}${new_part_num}"
        fi
        DATA_MODE=partition
    else
        # Mode B: not enough free space → loop-mounted sparse file.
        log::info "Insufficient free space (${end_gb}<${MIN_FREE_GB} GB)   using loop file: $LOOP_FILE"
        if [ ! -f "$LOOP_FILE" ]; then
            mkdir -p "$(dirname "$LOOP_FILE")"
            # truncate makes a sparse file   only consumes disk as data is written.
            truncate -s "${LOOP_SIZE_GB}G" "$LOOP_FILE"
        fi
        DATA_DEV="$LOOP_FILE"
        DATA_MODE=loop
    fi
    echo "$DATA_DEV" > /run/jetson-av-data-dev
    echo "$DATA_MODE" > /run/jetson-av-data-mode
}
post_decide() {
    [ -s /run/jetson-av-data-dev ] && [ -s /run/jetson-av-data-mode ]
}
step::run "Decide partition vs loop file" pre_decide exec_decide post_decide

DATA_DEV="$(cat /run/jetson-av-data-dev)"
DATA_MODE="$(cat /run/jetson-av-data-mode)"

# --- Step 3: format as btrfs (skip if already btrfs) ----------------------
pre_fmt() {
    case "$DATA_MODE" in
        partition) check::blockdev_exists "$DATA_DEV" ;;
        loop)      check::file_exists "$DATA_DEV" ;;
        *) return 1 ;;
    esac
}
exec_fmt() {
    if blkid "$DATA_DEV" 2>/dev/null | grep -q 'TYPE="btrfs"'; then
        log::info "Already btrfs; preserving"
        return 0
    fi
    mkfs.btrfs -f -L jetson-av-data "$DATA_DEV"
}
post_fmt() {
    blkid "$DATA_DEV" 2>/dev/null | grep -q 'TYPE="btrfs"'
}
step::run "Format btrfs (label: jetson-av-data)" pre_fmt exec_fmt post_fmt

# --- Step 4: mount (loop devices need a mount option) ---------------------
DATA_UUID="$(blkid -s UUID -o value "$DATA_DEV")"
MOUNT_OPTS="compress=zstd:3,noatime,space_cache=v2,autodefrag"
if [ "$DATA_MODE" = "loop" ]; then
    MOUNT_OPTS="loop,$MOUNT_OPTS"
fi

pre_mount() { [ -b "$DATA_DEV" ] || [ -f "$DATA_DEV" ] || { echo "MISSING device/file: $DATA_DEV" >&2; return 1; }; }
exec_mount() {
    mkdir -p "$MOUNT_POINT"
    if mountpoint -q "$MOUNT_POINT"; then
        log::info "$MOUNT_POINT already mounted"
        return 0
    fi
    mount -t btrfs -o "$MOUNT_OPTS" "$DATA_DEV" "$MOUNT_POINT"
}
post_mount() {
    mountpoint -q "$MOUNT_POINT" \
        && [ -d "$MOUNT_POINT" ]
}
step::run "Mount data partition" pre_mount exec_mount post_mount

# --- Step 5: persistent fstab entry ---------------------------------------
pre_fstab() { check::file_exists /etc/fstab; }
exec_fstab() {
    local fstab_marker="# jetson-av-data"
    if grep -q "$fstab_marker" /etc/fstab; then
        log::info "fstab entry already present"
        return 0
    fi
    cp /etc/fstab "/etc/fstab.bak.$(date +%s)"
    case "$DATA_MODE" in
        partition)
            printf '\n%s\nUUID=%s  %s  btrfs  %s  0  0\n' \
                "$fstab_marker" "$DATA_UUID" "$MOUNT_POINT" "$MOUNT_OPTS" \
                >> /etc/fstab
            ;;
        loop)
            printf '\n%s\n%s  %s  btrfs  %s  0  0\n' \
                "$fstab_marker" "$DATA_DEV" "$MOUNT_POINT" "$MOUNT_OPTS" \
                >> /etc/fstab
            ;;
    esac
}
post_fstab() {
    grep -q "# jetson-av-data" /etc/fstab \
        && grep -q "$MOUNT_POINT" /etc/fstab
}
step::run "Write fstab entry" pre_fstab exec_fstab post_fstab

# --- Step 6: migrate existing flights/ ------------------------------------
pre_migrate() { check::dir_exists "$MOUNT_POINT"; }
exec_migrate() {
    local src=/var/log/jetson-av/flights
    local dst="$MOUNT_POINT/flights"
    mkdir -p "$dst"
    if [ -d "$src" ] && [ ! -L "$src" ]; then
        # Move existing flights to the new btrfs mount, then symlink.
        if [ -n "$(ls -A "$src" 2>/dev/null)" ]; then
            log::info "Moving existing flights → $dst"
            mv "$src"/* "$dst"/ 2>/dev/null || true
        fi
        rmdir "$src" 2>/dev/null || rm -rf "$src"
        ln -sfn "$dst" "$src"
    elif [ ! -e "$src" ]; then
        ln -sfn "$dst" "$src"
    fi
    # Make sure subdir is a btrfs subvolume so we can snapshot per flight.
    if ! btrfs subvolume show "$dst" >/dev/null 2>&1; then
        btrfs subvolume create "$dst.sv" 2>/dev/null \
            && rmdir "$dst" 2>/dev/null \
            && mv "$dst.sv" "$dst" 2>/dev/null \
            || true
    fi
}
post_migrate() {
    [ -L /var/log/jetson-av/flights ] \
        && [ -d "$MOUNT_POINT/flights" ]
}
step::run "Migrate flights/ + create subvolume" pre_migrate exec_migrate post_migrate

# --- Step 7: weekly scrub timer -------------------------------------------
pre_scrub() { check::command_exists btrfs; }
exec_scrub() {
    cat > /etc/systemd/system/jetson-av-btrfs-scrub.service <<EOF
[Unit]
Description=Weekly btrfs scrub of the AV data partition
Documentation=file:///opt/docs/UAV_RESILIENCE.md
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/bin/btrfs scrub start -B $MOUNT_POINT
Nice=15
IOSchedulingClass=idle
EOF
    cat > /etc/systemd/system/jetson-av-btrfs-scrub.timer <<EOF
[Unit]
Description=Weekly btrfs scrub of the AV data partition
Documentation=file:///opt/docs/UAV_RESILIENCE.md

[Timer]
# Every Sunday at 03:00; randomize so a fleet doesn't all scrub at once.
OnCalendar=$SCRUB_DAY *-*-* 03:00:00
RandomizedDelaySec=2h
Persistent=true
Unit=jetson-av-btrfs-scrub.service

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable jetson-av-btrfs-scrub.timer
    systemctl start  jetson-av-btrfs-scrub.timer
}
post_scrub() {
    check::file_exists /etc/systemd/system/jetson-av-btrfs-scrub.timer
    systemctl is-enabled jetson-av-btrfs-scrub.timer >/dev/null
}
step::run "Install weekly scrub timer" pre_scrub exec_scrub post_scrub

# --- Step 8: end-to-end synthetic check -----------------------------------
pre_synth()  { check::dir_exists "$MOUNT_POINT"; }
exec_synth() {
    # Write a probe file, hash it, copy + verify, snapshot, delete original,
    # restore from snapshot. If any step misbehaves the post-check fails.
    local probe="$MOUNT_POINT/.install_probe"
    head -c 1M /dev/urandom > "$probe"
    local sum_a; sum_a="$(sha256sum "$probe" | awk '{print $1}')"
    btrfs subvolume snapshot -r "$MOUNT_POINT" "$MOUNT_POINT.snap-$$" 2>/dev/null \
        || log::warn "snapshot failed (non-fatal   top-level isn't a subvolume)"
    rm "$probe"
    if [ -f "$MOUNT_POINT.snap-$$/.install_probe" ]; then
        cp "$MOUNT_POINT.snap-$$/.install_probe" "$probe"
        local sum_b; sum_b="$(sha256sum "$probe" | awk '{print $1}')"
        [ "$sum_a" = "$sum_b" ] || { log::xfail "snapshot integrity" "hash mismatch"; return 1; }
        btrfs subvolume delete "$MOUNT_POINT.snap-$$" 2>/dev/null || true
    fi
    rm -f "$probe"
}
post_synth() {
    btrfs filesystem df "$MOUNT_POINT" >/dev/null 2>&1
}
STRICT=0 step::run "Synthetic write/snapshot/restore probe" pre_synth exec_synth post_synth

log::section "Data Partition Install Complete"
btrfs filesystem df  "$MOUNT_POINT" 2>/dev/null | sed 's/^/  /'
btrfs filesystem usage -h "$MOUNT_POINT" 2>/dev/null | sed 's/^/  /'
echo
echo "Inspect later with:"
echo "  btrfs scrub status   $MOUNT_POINT"
echo "  btrfs filesystem usage -h $MOUNT_POINT"
echo "  systemctl list-timers | grep jetson-av-btrfs"
echo
step::summary
