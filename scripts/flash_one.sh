#!/bin/bash
# =============================================================================
# scripts/flash_one.sh   flash a single device with full pre/post verify
# =============================================================================
# Combines: detect recovery → flash → wait for first-boot → validate.
#
# Usage:
#   ./scripts/flash_one.sh <device-label>
#   make flash-one DEVICE=av-07
#
# Difference from flash_release.sh:
#   - Runs from the source repo (uses latest_jetson/), not a release tarball.
#   - Calls 05_post_flash_validate.sh after a 90s settle.
#   - Records PASS/FAIL into fleet_log.csv based on validation outcome,
#     not just "flashed".
# =============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/config.sh"
. "$HERE/lib/log.sh"
. "$HERE/lib/verify.sh"
. "$HERE/lib/checks.sh"

PHASE=fleet
DEVICE="${1:-${DEVICE:-}}"
if [ -z "$DEVICE" ]; then
    log::fail "Usage: $0 <device-label>   (or DEVICE=label make flash-one)"
fi

log::section "Flash + Validate one device   label: $DEVICE"

# --- Step 1: pre-flash audit must be green ----------------------------------
pre_audit()  { check::executable "$HERE/pre_flash_audit.sh"; }
exec_audit() { "$HERE/pre_flash_audit.sh"; }
post_audit() { return 0; }
step::run "Pre-flash audit" pre_audit exec_audit post_audit

# --- Step 2: invoke the existing flash script -------------------------------
pre_flash()  { check::executable "$HERE/04_flash_nvme.sh"; }
exec_flash() { "$HERE/04_flash_nvme.sh"; }
post_flash() {
    # After flash, the Jetson must reboot into the new image and bring up
    # the USB-Ethernet link. Wait up to 120s for it to appear at TARGET_USB_IP.
    log::info "Waiting up to 120s for $TARGET_USB_IP to come up..."
    local i=0
    while [ "$i" -lt 120 ]; do
        if ping -c 1 -W 1 "$TARGET_USB_IP" >/dev/null 2>&1; then
            log::ok "$TARGET_USB_IP responds"
            return 0
        fi
        sleep 1; i=$((i+1))
    done
    return 1
}
step::run "Flash NVMe + reboot to first boot" pre_flash exec_flash post_flash

# --- Step 3: settle for first-boot service ----------------------------------
pre_settle()  { return 0; }
exec_settle() {
    log::info "Sleeping 90s for jetson-first-boot.service to complete + reboot..."
    sleep 90
}
post_settle() { check::host_pingable "$TARGET_USB_IP" 5; }
step::run "Settle for first-boot" pre_settle exec_settle post_settle

# --- Step 4: post-flash validation -----------------------------------------
RESULT="UNKNOWN"
pre_validate()  { check::executable "$HERE/05_post_flash_validate.sh"; }
exec_validate() { "$HERE/05_post_flash_validate.sh"; }
post_validate() { return 0; }
if STRICT=0 step::run "Full post-flash validation" pre_validate exec_validate post_validate; then
    RESULT="PASS"
else
    RESULT="VALIDATION_FAIL"
fi

# --- Step 5: record result into fleet_log.csv ------------------------------
FLEET_LOG="$REPO_ROOT/fleet_log.csv"
pre_log()  { return 0; }
exec_log() {
    if [ ! -f "$FLEET_LOG" ]; then
        printf 'timestamp,operator,device_label,build_sha256,kernel_release,vermagic,result\n' > "$FLEET_LOG"
    fi
    local sha; sha="$(sha256sum "$KERNEL_IMAGE" 2>/dev/null | awk '{print $1}')"
    local krel="" vm=""
    if [ -f "$L4T_DIR/BUILD_MANIFEST.json" ]; then
        krel="$(grep -oE '"kernel_release": *"[^"]*"' "$L4T_DIR/BUILD_MANIFEST.json" \
                 | sed 's/.*"kernel_release": *"\([^"]*\)".*/\1/')"
    fi
    [ -f "$EXPECTED_VERMAGIC_FILE" ] && vm="$(cat "$EXPECTED_VERMAGIC_FILE")"
    printf '%s,%s,%s,%s,%s,"%s",%s\n' \
        "$(date -u -Iseconds)" "$(id -un)" "$DEVICE" "$sha" "$krel" "$vm" "$RESULT" \
        >> "$FLEET_LOG"
    log::ok "fleet_log.csv updated → $RESULT"
}
post_log() { check::file_exists "$FLEET_LOG"; }
STRICT=0 step::run "Append fleet_log.csv" pre_log exec_log post_log

# --- Final summary ---------------------------------------------------------
log::section "Device $DEVICE   $RESULT"
step::summary
[ "$RESULT" = "PASS" ] || exit 1
