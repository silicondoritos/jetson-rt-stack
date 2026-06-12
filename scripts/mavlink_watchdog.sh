#!/bin/bash
# =============================================================================
# scripts/mavlink_watchdog.sh   flight controller heartbeat monitor
# =============================================================================
# Subscribes to MAVROS /mavros/state and watches for HEARTBEAT loss. On
# loss, emits a black-box event and (optionally) triggers a flush of the
# black-box recorder (kill -USR1) so the last seconds before link loss are
# definitely on disk. Does NOT command the FCU   the autopilot has its own
# RTH/RTL failsafe.
#
# Configuration: /etc/jetson-av/mavlink-watchdog.conf
#   HEARTBEAT_TIMEOUT=5            seconds without HEARTBEAT before alarm
#   POLL_INTERVAL=1
#   FLUSH_BLACKBOX_ON_LOSS=1
# =============================================================================
set -u

CONF=/etc/jetson-av/mavlink-watchdog.conf
EVENT_PIPE=/var/run/jetson-av-events
HEARTBEAT_TIMEOUT=5
POLL_INTERVAL=1
FLUSH_BLACKBOX_ON_LOSS=1
[ -f "$CONF" ] && . "$CONF"

emit() {
    [ -p "$EVENT_PIPE" ] || return 0
    echo "{\"src\":\"mavlink_wd\",\"e\":\"$1\",\"v\":\"$2\"}" > "$EVENT_PIPE" 2>/dev/null || true
}

log() { echo "[mavlink_wd] $*"; logger -t jetson-av-mavlink-watchdog "$*" 2>/dev/null || true; }

# Wait for ROS 2 + MAVROS to be available.
wait_for_mavros() {
    local i=0
    while [ "$i" -lt 60 ]; do
        if command -v ros2 >/dev/null 2>&1; then
            if ros2 topic list 2>/dev/null | grep -q '^/mavros/state'; then
                return 0
            fi
        fi
        sleep 2; i=$((i+2))
    done
    return 1
}

if ! wait_for_mavros; then
    log "MAVROS topics never appeared   exiting (will be restarted by systemd)"
    emit "mavros_missing" "1"
    exit 1
fi

log "Watching /mavros/state (timeout ${HEARTBEAT_TIMEOUT}s)"
emit "watchdog_start" "1"

LAST_HEARTBEAT="$(date +%s)"
ALARM_FIRED=0

# Stream state messages in the background; bump LAST_HEARTBEAT on every msg.
( ros2 topic echo /mavros/state std_msgs/msg/String --no-arr 2>/dev/null ) | \
while IFS= read -r line; do
    case "$line" in
        *connected:*true*)
            LAST_HEARTBEAT="$(date +%s)"
            if [ "$ALARM_FIRED" = "1" ]; then
                log "FCU heartbeat recovered"
                emit "heartbeat_recovered" "1"
                ALARM_FIRED=0
            fi
            ;;
    esac

    NOW="$(date +%s)"
    DELTA=$(( NOW - LAST_HEARTBEAT ))
    if [ "$DELTA" -ge "$HEARTBEAT_TIMEOUT" ] && [ "$ALARM_FIRED" = "0" ]; then
        log "ALARM: no FCU heartbeat for ${DELTA}s"
        emit "heartbeat_lost" "$DELTA"
        ALARM_FIRED=1
        if [ "$FLUSH_BLACKBOX_ON_LOSS" = "1" ]; then
            BB_PID="$(systemctl show jetson-blackbox.service -p MainPID --value 2>/dev/null)"
            if [ -n "$BB_PID" ] && [ "$BB_PID" != "0" ]; then
                kill -USR1 "$BB_PID" 2>/dev/null || true
                log "Flushed black-box (PID $BB_PID)"
            fi
        fi
    fi
done

# Should never reach here unless ros2 echo died.
log "ros2 echo exited   restarting via systemd"
emit "watchdog_died" "1"
exit 1
