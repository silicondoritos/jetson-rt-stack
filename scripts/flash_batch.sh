#!/bin/bash
# =============================================================================
# scripts/flash_batch.sh   flash N devices from a fleet manifest CSV
# =============================================================================
# Loops over fleet.csv, flashes each device, validates each, records
# per-device PASS/FAIL into fleet_log.csv, prints a summary at the end.
#
# fleet.csv schema (header required):
#   device_label,hostname,static_ip,notes
# Example:
#   av-07,node-07,192.168.10.7,"prototype unit 7"
#   av-08,node-08,192.168.10.8,
#
# Usage:
#   ./scripts/flash_batch.sh fleet.csv
#   make flash-batch FLEET=fleet.csv
#
# Per device the operator is prompted to swap the Jetson into recovery mode.
# Press ENTER to continue, type 'skip' to skip that row, Ctrl+C to abort.
# =============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/config.sh"
. "$HERE/lib/log.sh"
. "$HERE/lib/verify.sh"
. "$HERE/lib/checks.sh"

PHASE=fleet
FLEET_CSV="${1:-${FLEET:-fleet.csv}}"

if [ ! -f "$FLEET_CSV" ]; then
    log::fail "Fleet CSV not found: $FLEET_CSV"
fi

# --- Parse + validate the CSV ----------------------------------------------
log::section "Fleet Batch Flash"
log::info "Manifest: $FLEET_CSV"

HEADER="$(head -1 "$FLEET_CSV")"
case "$HEADER" in
    device_label,hostname,static_ip,notes*) ;;
    *) log::fail "fleet.csv header must be: device_label,hostname,static_ip,notes" ;;
esac

ROW_COUNT="$(tail -n +2 "$FLEET_CSV" | grep -cv '^$')"
log::info "Devices in manifest: $ROW_COUNT"

# Confirm the audit gate once for the whole batch.
log::step "Running pre-flash audit (once for the batch)..."
if ! "$HERE/pre_flash_audit.sh"; then
    log::fail "Pre-flash audit FAILED   fix and rerun before batch flashing."
fi
log::ok "Audit green   proceeding with batch."

# --- Per-device loop --------------------------------------------------------
declare -a RESULTS=()
declare -a LABELS=()
INDEX=0

while IFS=, read -r device_label hostname static_ip notes; do
    # Strip CR (Windows-edited CSVs).
    device_label="${device_label//$'\r'/}"
    hostname="${hostname//$'\r'/}"
    static_ip="${static_ip//$'\r'/}"
    notes="${notes//$'\r'/}"
    [ -z "$device_label" ] && continue

    INDEX=$((INDEX + 1))
    LABELS+=("$device_label")

    log::section "[$INDEX/$ROW_COUNT] $device_label"
    [ -n "$hostname" ]  && log::info "hostname : $hostname"
    [ -n "$static_ip" ] && log::info "static IP: $static_ip"
    [ -n "$notes" ]     && log::info "notes    : $notes"

    # Stage per-device personalization config that first-boot reads.
    # Bake-time would be cleaner but for fleet workflows we do it here so
    # the same image is reused across N devices.
    if [ -n "$hostname" ] || [ -n "$static_ip" ]; then
        STAGE_DIR="$ROOTFS/etc/jetson-av-fleet"
        sudo mkdir -p "$STAGE_DIR"
        sudo tee "$STAGE_DIR/device.conf" >/dev/null <<EOF
DEVICE_LABEL=$device_label
HOSTNAME=$hostname
STATIC_IP=$static_ip
NOTES=$notes
EOF
        log::ok "Staged $STAGE_DIR/device.conf"
    fi

    # Operator prompt.
    echo
    read -r -p "[$device_label] Put device in recovery mode, then press ENTER (or type 'skip'): " ANSWER
    if [ "$ANSWER" = "skip" ]; then
        log::warn "Skipped $device_label"
        RESULTS+=("SKIPPED")
        continue
    fi

    # Run flash_one for this device. Use STRICT=0 so a failure doesn't kill
    # the entire batch   we want to continue on to the next unit.
    if STRICT=0 DEVICE="$device_label" "$HERE/flash_one.sh" "$device_label"; then
        RESULTS+=("PASS")
        log::ok "[$device_label] PASS"
    else
        RESULTS+=("FAIL")
        log::warn "[$device_label] FAIL   see logs/, continuing with next device"
    fi

done < <(tail -n +2 "$FLEET_CSV")

# --- Summary ----------------------------------------------------------------
log::section "Batch Summary"
PASS=0; FAIL=0; SKIP=0
for i in "${!LABELS[@]}"; do
    case "${RESULTS[$i]}" in
        PASS)    PASS=$((PASS + 1)); printf '  %s%-20s PASS%s\n'    "$_C_GREEN"  "${LABELS[$i]}" "$_C_RESET" ;;
        FAIL)    FAIL=$((FAIL + 1)); printf '  %s%-20s FAIL%s\n'    "$_C_RED"    "${LABELS[$i]}" "$_C_RESET" ;;
        SKIPPED) SKIP=$((SKIP + 1)); printf '  %s%-20s SKIPPED%s\n' "$_C_YELLOW" "${LABELS[$i]}" "$_C_RESET" ;;
    esac
done
echo
echo "  Total: $INDEX   Pass: $PASS   Fail: $FAIL   Skipped: $SKIP"
echo "  Detailed log: $REPO_ROOT/fleet_log.csv"
echo "  Step manifest: $(step::manifest_path)"

[ "$FAIL" -eq 0 ] || exit 1
