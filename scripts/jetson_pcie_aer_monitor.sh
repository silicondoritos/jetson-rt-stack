#!/bin/bash
# =============================================================================
# /usr/local/bin/jetson-av-pcie-aer-monitor   PCIe Advanced Error Reporting
# =============================================================================
# Polls /sys/bus/pci/devices/*/aer_dev_{correctable,fatal,nonfatal} every N
# seconds. On any counter increase, emits a black-box event with the device
# vendor:device, the error class, and the delta. Per-flight forensic review
# can then correlate "Metis disappeared" with "AER correctable spike at T-2s"
# back to the actual electrical event.
#
# Designed to run as jetson-av-pcie-aer-monitor.service. Restart=always; a
# single missed poll is harmless (counters are cumulative).
# =============================================================================
set -u

EVENT_PIPE=/var/run/jetson-av-events
INTERVAL="${AER_POLL_INTERVAL:-5}"
STATE_DIR=/run/jetson-av-aer
mkdir -p "$STATE_DIR"

emit() {
    local kind="$1" payload="$2"
    [ -p "$EVENT_PIPE" ] || return 0
    echo "{\"src\":\"pcie_aer\",\"e\":\"$kind\",\"v\":$payload}" \
        > "$EVENT_PIPE" 2>/dev/null || true
}

log() { echo "[pcie-aer] $*"; logger -t jetson-av-pcie-aer "$*" 2>/dev/null || true; }

# Prefer aer-stats from pciutils if present; fall back to /sys.
read_counter() {
    local dev="$1" kind="$2"   # kind: correctable | fatal | nonfatal
    local f="/sys/bus/pci/devices/$dev/aer_dev_$kind"
    [ -r "$f" ] || return 1
    # The file lists each error type with TOTAL_ERR_COR / TOTAL_ERR_FATAL etc.
    awk '/^TOTAL_/ {print $2; exit}' "$f" 2>/dev/null || echo 0
}

# Identify a device by vendor:device for human readability.
identify() {
    local dev="$1"
    local vid did
    vid=$(cat /sys/bus/pci/devices/$dev/vendor 2>/dev/null | tr -d 0x)
    did=$(cat /sys/bus/pci/devices/$dev/device 2>/dev/null | tr -d 0x)
    printf '%s [%s:%s]' "$dev" "$vid" "$did"
}

# Initialize per-device state files with current counter values.
log "starting; interval=${INTERVAL}s"
emit "monitor_start" "1"

declare -A LAST
trap 'log "stopping"; emit "monitor_stop" "1"; exit 0' INT TERM

while true; do
    for dev_path in /sys/bus/pci/devices/*; do
        dev=$(basename "$dev_path")
        # Skip devices without AER capability   most edge devices don't
        # implement the capability and the file simply won't exist.
        [ -e "$dev_path/aer_dev_correctable" ] || continue

        for kind in correctable fatal nonfatal; do
            cur=$(read_counter "$dev" "$kind" 2>/dev/null || echo 0)
            cur=${cur:-0}
            key="$dev:$kind"
            prev=${LAST[$key]:-}
            if [ -z "$prev" ]; then
                LAST[$key]=$cur
                continue
            fi
            if [ "$cur" -gt "$prev" ]; then
                delta=$((cur - prev))
                ident=$(identify "$dev")
                log "$ident $kind +$delta (total $cur)"
                # Severity → black-box event kind.
                case "$kind" in
                    correctable) ek="aer_correctable" ;;
                    nonfatal)    ek="aer_nonfatal"    ;;
                    fatal)       ek="aer_fatal"       ;;
                esac
                emit "$ek" "{\"dev\":\"$dev\",\"vendor_device\":\"$(cat $dev_path/vendor):$(cat $dev_path/device)\",\"delta\":$delta,\"total\":$cur}"
                LAST[$key]=$cur
            fi
        done
    done
    sleep "$INTERVAL"
done
