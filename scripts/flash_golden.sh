#!/bin/bash
# =============================================================================
# scripts/flash_golden.sh   flash a saved golden image to a target Jetson
# =============================================================================
# Pair to clone_golden.sh. Takes a golden directory under golden-images/,
# verifies its checksums + (if present) GPG signature, then flashes it to a
# Jetson in recovery mode using the same NVIDIA `l4t_initrd_flash.sh`
# infrastructure as `make flash`.
#
# After the flash completes and the receiving Jetson boots, its
# personalize_first_boot.sh runs and gives it a unique hostname + SSH host
# keys + optional static IP from /etc/jetson-av-fleet/device.conf   so each
# clone of the golden ends up with its own identity even though the bytes
# are bit-identical at flash time.
#
# Usage:
#   ./scripts/flash_golden.sh <golden_name> [--device <label>]
#
#   <golden_name>   directory name under golden-images/, e.g.
#                   "golden-v1.0-bench-validated-20260507-101200"
#   --device LABEL  fleet label for fleet_log.csv (default: "unnamed")
#
# Env:
#   APX_TIMEOUT     seconds to wait for APX (default 60)
#   GPG_VERIFY=0    skip signature verification (default: verify if .sig exists)
# =============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/config.sh"
. "$HERE/lib/log.sh"
. "$HERE/lib/verify.sh"
. "$HERE/lib/checks.sh"

PHASE=golden_flash

GOLDEN_NAME="${1:-}"
DEVICE_LABEL="unnamed"
shift || true
while [ $# -gt 0 ]; do
    case "$1" in
        --device) DEVICE_LABEL="$2"; shift 2 ;;
        --help|-h)
            sed -n '/^# =============/,/^# =============$/p' "$0" | sed 's/^# //'
            exit 0 ;;
        *) log::warn "unknown arg: $1"; shift ;;
    esac
done
[ -n "$GOLDEN_NAME" ] || log::fail "Usage: $0 <golden_name> [--device <label>]"

GOLDEN_DIR="${GOLDEN_DIR:-$REPO_ROOT/golden-images}"
SRC="$GOLDEN_DIR/$GOLDEN_NAME"
[ -d "$SRC" ] || log::fail "golden not found: $SRC"

log::section "Flash Golden   $GOLDEN_NAME → device $DEVICE_LABEL"

# -----------------------------------------------------------------------
# Step 1   verify integrity (checksums + optional GPG)
# -----------------------------------------------------------------------
pre_verify()  { check::file_exists "$SRC/golden.manifest.json"; }
exec_verify() {
    if [ -f "$SRC/CHECKSUMS.sha256" ]; then
        ( cd "$SRC" && sha256sum -c CHECKSUMS.sha256 --quiet ) \
            || { echo "checksum failure" >&2; return 1; }
        log::ok "all checksums match"
    else
        log::warn "no CHECKSUMS.sha256   skipping integrity check"
    fi
    if [ "${GPG_VERIFY:-1}" = "1" ] && [ -f "$SRC/golden.manifest.sig" ]; then
        if command -v gpg >/dev/null 2>&1; then
            gpg --verify "$SRC/golden.manifest.sig" "$SRC/golden.manifest.json" \
                && log::ok "GPG signature valid" \
                || { echo "GPG signature INVALID" >&2; return 1; }
        else
            log::warn "gpg missing   skipping signature verification"
        fi
    fi
    log::info "Manifest:"
    sed 's/^/    /' "$SRC/golden.manifest.json"
}
post_verify() { return 0; }
step::run "Verify golden integrity" pre_verify exec_verify post_verify

# -----------------------------------------------------------------------
# Step 2   staged-rootfs path or partition-image path?
# -----------------------------------------------------------------------
MODE="$(grep -oE '"capture_mode": *"[^"]+"' "$SRC/golden.manifest.json" \
        | sed 's/.*"\([^"]*\)"/\1/')"
log::info "Capture mode: $MODE"

# -----------------------------------------------------------------------
# Step 3   detect Jetson recovery mode
# -----------------------------------------------------------------------
pre_apx()  { check::command_exists lsusb; }
exec_apx() {
    APX_TIMEOUT="${APX_TIMEOUT:-60}"
    log::info "Polling for APX device (USB ID $USB_ID_APX) for ${APX_TIMEOUT}s..."
    local i=0
    while [ "$i" -lt "$APX_TIMEOUT" ]; do
        if lsusb 2>/dev/null | grep -q "$USB_ID_APX"; then
            log::ok "APX detected"
            return 0
        fi
        sleep 1; i=$((i+1)); printf '.'
    done
    echo
    return 1
}
post_apx() { check::usb_device_visible "$USB_ID_APX"; }
step::run "Detect Jetson recovery mode" pre_apx exec_apx post_apx

# -----------------------------------------------------------------------
# Step 4   flash
# -----------------------------------------------------------------------
case "$MODE" in
    recovery)
        pre_flash()  { check::dir_exists "$L4T_DIR/tools/kernel_flash"; }
        exec_flash() {
            cd "$L4T_DIR"
            # Stage the golden's images where l4t_initrd_flash expects them.
            local stage="tools/kernel_flash/images/$TARGET_BOARD"
            sudo mkdir -p "$stage"
            sudo rm -f "$stage"/* 2>/dev/null || true
            log::info "Staging golden images at $stage/"
            sudo cp -r "$SRC"/* "$stage/" 2>/dev/null || true

            log::info "Flashing from staged golden..."
            sudo ./tools/kernel_flash/l4t_initrd_flash.sh \
                --use-backup-image \
                --external-device "$TARGET_STORAGE_DEV" \
                -c "$TARGET_FLASH_XML" \
                -p "-c $TARGET_QSPI_XML" \
                --showlogs --network usb0 \
                "$TARGET_BOARD" internal
        }
        post_flash() {
            log::info "Waiting up to 30s for APX to disappear (post-flash reboot)..."
            local i=0
            while [ "$i" -lt 30 ]; do
                lsusb 2>/dev/null | grep -q "$USB_ID_APX" || return 0
                sleep 1; i=$((i+1))
            done
            return 1
        }
        step::run "Flash golden via l4t_initrd_flash --use-backup-image" \
                  pre_flash exec_flash post_flash
        ;;
    staged)
        pre_stage_flash()  { check::file_exists "$SRC/staged-rootfs.tar.gz"; }
        exec_stage_flash() {
            log::info "Restoring staged rootfs into $ROOTFS..."
            sudo rm -rf "$ROOTFS"/* 2>/dev/null || true
            sudo tar -xzf "$SRC/staged-rootfs.tar.gz" -C "$L4T_DIR" --strip-components=0
            # Then run the standard flash path.
            "$HERE/04_flash_nvme.sh"
        }
        post_stage_flash() { return 0; }
        step::run "Restore staged rootfs + flash" pre_stage_flash exec_stage_flash post_stage_flash
        ;;
    *)
        log::fail "unknown capture_mode: $MODE"
        ;;
esac

# -----------------------------------------------------------------------
# Step 5   append to fleet_log.csv
# -----------------------------------------------------------------------
FLEET_LOG="$REPO_ROOT/fleet_log.csv"
pre_log()  { return 0; }
exec_log() {
    if [ ! -f "$FLEET_LOG" ]; then
        printf 'timestamp,operator,device_label,build_sha256,kernel_release,vermagic,result\n' > "$FLEET_LOG"
    fi
    local sha; sha="$(awk -F'"' '/tarball_sha256|build_sha/ {print $4; exit}' \
                       "$SRC/golden.manifest.json" 2>/dev/null)"
    [ -z "$sha" ] && sha="$(sha256sum "$SRC/golden.manifest.json" | awk '{print $1}')"
    printf '%s,%s,%s,%s,golden:%s,"",FLASHED_FROM_GOLDEN\n' \
        "$(date -u -Iseconds)" "$(id -un)" "$DEVICE_LABEL" "$sha" "$GOLDEN_NAME" \
        >> "$FLEET_LOG"
    log::ok "fleet_log.csv updated"
}
post_log() { check::file_exists "$FLEET_LOG"; }
STRICT=0 step::run "Append fleet_log.csv" pre_log exec_log post_log

log::section "Done   golden flashed to $DEVICE_LABEL"
log::info "Wait ~90s for first-boot service (personalization), then run:"
log::info "  ./scripts/05_post_flash_validate.sh"
echo
step::summary
