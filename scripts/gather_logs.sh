#!/bin/bash
# =============================================================================
# scripts/gather_logs.sh   bundle every log into a single .tar.gz for support
# =============================================================================
# Captures: BUILD_LOG.md, FLASH_LOG.txt, IGNITION_*.log, EXPECTED_VERMAGIC,
# defconfig (staged), extlinux.conf (staged), and (if reachable) recent
# journalctl/dmesg from the target.
#
# Output: support-bundle-YYYYMMDD-HHMMSS.tar.gz at REPO_ROOT.
# =============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/config.sh"
. "$HERE/lib/log.sh"

STAMP="$(date +%Y%m%d-%H%M%S)"
WORK="$(mktemp -d -t support-bundle-XXXXXX)"
DEST="$WORK/support-bundle-$STAMP"
mkdir -p "$DEST"

log::section "Gather Logs"
log::info "Working dir: $DEST"

# --- Local artifacts --------------------------------------------------------
log::step "Local artifacts"
copy_if() {
    if [ -e "$1" ]; then
        cp -r "$1" "$DEST/" 2>/dev/null && log::pass "$(basename "$1")"
    fi
}
copy_if "$REPO_ROOT/BUILD_LOG.md"
copy_if "$REPO_ROOT/FLASH_LOG.txt"
for f in "$REPO_ROOT"/IGNITION_*.log; do copy_if "$f"; done
copy_if "$EXPECTED_VERMAGIC_FILE"
copy_if "$BUILD_MANIFEST"
copy_if "$DEFCONFIG_PATH"
copy_if "$EXTLINUX_CONF"

# --- Vermagic verification snapshot ----------------------------------------
log::step "Vermagic snapshot"
if [ -x "$HERE/verify_vermagic.sh" ]; then
    NO_EXIT=1 "$HERE/verify_vermagic.sh" --rootfs > "$DEST/vermagic-rootfs.txt" 2>&1 \
        && log::pass "vermagic-rootfs.txt"
fi

# --- Target-side logs (best-effort) -----------------------------------------
log::step "Target logs (best-effort SSH)"
if ping -c 1 -W 2 "$TARGET_USB_IP" >/dev/null 2>&1 \
   && ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new \
          -o UserKnownHostsFile=/tmp/jetson_known_hosts \
          "${TARGET_USER}@${TARGET_USB_IP}" "true" 2>/dev/null; then

    SSH_CMD=(ssh -o ConnectTimeout=3
                 -o StrictHostKeyChecking=accept-new
                 -o UserKnownHostsFile=/tmp/jetson_known_hosts
                 "${TARGET_USER}@${TARGET_USB_IP}")

    "${SSH_CMD[@]}" "uname -a; cat /proc/cmdline; cat /proc/version" \
        > "$DEST/target-uname.txt" 2>&1 && log::pass "target-uname.txt"

    "${SSH_CMD[@]}" "sudo dmesg --level=err,warn,crit,alert,emerg" \
        > "$DEST/target-dmesg-err.txt" 2>&1 && log::pass "target-dmesg-err.txt"

    "${SSH_CMD[@]}" "sudo journalctl -b 0 -u jetson-first-boot.service --no-pager" \
        > "$DEST/target-journal-first-boot.txt" 2>&1 && log::pass "target-journal-first-boot.txt"

    "${SSH_CMD[@]}" "sudo journalctl -b 0 -u jetson-rt-tune.service --no-pager" \
        > "$DEST/target-journal-rt-tune.txt" 2>&1 && log::pass "target-journal-rt-tune.txt"

    "${SSH_CMD[@]}" "lsmod; lspci -tv; ls /dev/dma_heap; ls /dev/video* 2>/dev/null" \
        > "$DEST/target-hardware.txt" 2>&1 && log::pass "target-hardware.txt"

    "${SSH_CMD[@]}" "for ko in /lib/modules/\$(uname -r)/kernel/drivers/media/i2c/zedx/*.ko \
                                /lib/modules/\$(uname -r)/kernel/drivers/misc/axelera/*.ko 2>/dev/null; do
                         [ -f \"\$ko\" ] && modinfo \"\$ko\" | grep '^vermagic:'
                     done" \
        > "$DEST/target-vermagic.txt" 2>&1 && log::pass "target-vermagic.txt"
else
    log::warn "Target unreachable   skipping remote logs"
fi

# --- Tarball ---------------------------------------------------------------
log::step "Packaging..."
OUT="$REPO_ROOT/support-bundle-$STAMP.tar.gz"
( cd "$WORK" && tar czf "$OUT" "support-bundle-$STAMP" )
rm -rf "$WORK"

log::ok "Wrote $OUT  ($(du -h "$OUT" | awk '{print $1}'))"
echo
echo "Attach this file to support requests."
