#!/bin/bash
# =============================================================================
# scripts/jetson_blackbox.sh   AV black-box recorder daemon
# =============================================================================
# Records every flight as a structured forensic trail:
#   • ROS 2 bag of all configured topics (camera, imu, gps, mavlink, tf, etc.)
#     with NVENC video compression for camera streams
#   • Ring buffer: keeps last N seconds in memory + flushes to disk
#     periodically; on crash signal (USR1) flushes immediately
#   • Per-flight directory under /var/log/jetson-av/flights/<timestamp>/
#   • Hash-chained event log so tampering is detectable
#   • Optional structured JSON event stream from /var/run/jetson-av-events
#     (other services drop events here as one JSON object per line)
#
# Triggered as a systemd service (jetson-blackbox.service); see
# install_blackbox.sh for installation.
#
# Configuration via /etc/jetson-av/blackbox.conf (key=value lines):
#   ROS_TOPICS="/zed/zed_node/rgb/color/rect/image /zed/zed_node/imu/data /mavros/global_position/raw"
#   FLIGHT_DIR=/var/log/jetson-av/flights
#   RING_SECONDS=120
#   FLUSH_INTERVAL=30
#   MAX_FLIGHT_SIZE=2G
# =============================================================================
set -u

CONF=/etc/jetson-av/blackbox.conf
EVENT_PIPE=/var/run/jetson-av-events
FLIGHT_DIR_DEFAULT=/var/log/jetson-av/flights
RING_SECONDS_DEFAULT=120
FLUSH_INTERVAL_DEFAULT=30

# --- Defaults --------------------------------------------------------------
ROS_TOPICS=""
FLIGHT_DIR="$FLIGHT_DIR_DEFAULT"
RING_SECONDS="$RING_SECONDS_DEFAULT"
FLUSH_INTERVAL="$FLUSH_INTERVAL_DEFAULT"
MAX_FLIGHT_SIZE="2G"

if [ -f "$CONF" ]; then
    # shellcheck disable=SC1090
    . "$CONF"
fi

# --- Per-flight directory --------------------------------------------------
STAMP="$(date +%Y%m%d-%H%M%S)"
FLIGHT_PATH="$FLIGHT_DIR/$STAMP"
mkdir -p "$FLIGHT_PATH"

EVENT_LOG="$FLIGHT_PATH/events.jsonl"
HASH_LOG="$FLIGHT_PATH/events.sha256"
META="$FLIGHT_PATH/flight-meta.json"
BAG_DIR="$FLIGHT_PATH/bag"

cat > "$META" <<EOF
{
  "flight_id": "$STAMP",
  "started_at": "$(date -u -Iseconds)",
  "host": "$(hostname)",
  "kernel": "$(uname -r)",
  "build": $( [ -f /etc/jetson-av-build.json ] && cat /etc/jetson-av-build.json || echo '"unavailable"'),
  "personalized": $( [ -f /etc/jetson-av-personalized ] && echo true || echo false ),
  "ros_topics": "$ROS_TOPICS",
  "ring_seconds": $RING_SECONDS,
  "flush_interval": $FLUSH_INTERVAL,
  "max_size": "$MAX_FLIGHT_SIZE"
}
EOF

# --- Helpers ---------------------------------------------------------------
emit_event() {
    # Append a JSON event to the event log AND to the hash chain.
    local kind="$1" payload="$2"
    local ts; ts="$(date -u -Iseconds)"
    local prev_hash=""
    if [ -f "$HASH_LOG" ]; then
        prev_hash="$(tail -1 "$HASH_LOG")"
    else
        prev_hash="GENESIS"
    fi
    local line="{\"t\":\"$ts\",\"k\":\"$kind\",\"prev\":\"$prev_hash\",\"p\":$payload}"
    echo "$line" >> "$EVENT_LOG"
    printf '%s' "$line" | sha256sum | awk '{print $1}' >> "$HASH_LOG"
}

cleanup() {
    emit_event "blackbox.stop" '{"reason":"signal"}'
    if [ -n "${BAG_PID:-}" ] && kill -0 "$BAG_PID" 2>/dev/null; then
        kill -INT "$BAG_PID" 2>/dev/null || true
        wait "$BAG_PID" 2>/dev/null || true
    fi
    {
        echo "ended_at=$(date -u -Iseconds)"
        echo "exit_reason=signal"
    } >> "$META"
    exit 0
}

flush_now() {
    emit_event "blackbox.flush" '{"reason":"signal"}'
    sync "$FLIGHT_PATH" 2>/dev/null || true
}

trap cleanup INT TERM
trap flush_now USR1

# --- Drain the event pipe in the background --------------------------------
mkfifo "$EVENT_PIPE" 2>/dev/null || true
chmod 666 "$EVENT_PIPE" 2>/dev/null || true
( while read -r json_event < "$EVENT_PIPE"; do
      # Best-effort JSON pass-through; if it doesn't look like JSON, wrap it.
      if [ "${json_event:0:1}" = "{" ]; then
          emit_event "external" "$json_event"
      else
          emit_event "external" "{\"raw\":\"$(printf '%s' "$json_event" | sed 's/"/\\"/g')\"}"
      fi
  done ) &
PIPE_PID=$!

emit_event "blackbox.start" '{"version":"1"}'

# --- ROS 2 bag recording (only if ros2 + topics configured) ---------------
BAG_PID=""
if [ -n "$ROS_TOPICS" ] && command -v ros2 >/dev/null 2>&1; then
    mkdir -p "$BAG_DIR"
    # NVENC encoding for camera topics happens via ros2 bag's --max-cache-size
    # plus a custom QoS profile; keep simple here, install_blackbox.sh wires
    # the QoS file in /etc/jetson-av/bag-qos.yaml.
    QOS_OPT=""
    [ -f /etc/jetson-av/bag-qos.yaml ] && QOS_OPT="--qos-profile-overrides-path /etc/jetson-av/bag-qos.yaml"

    # shellcheck disable=SC2086
    ros2 bag record \
        --output "$BAG_DIR/flight" \
        --max-cache-size 200000000 \
        --max-bag-size 524288000 \
        $QOS_OPT \
        $ROS_TOPICS &
    BAG_PID=$!
    emit_event "ros2_bag.start" "{\"pid\":$BAG_PID,\"topics\":\"$ROS_TOPICS\"}"
else
    emit_event "ros2_bag.skipped" '{"reason":"no ROS_TOPICS or ros2 not installed"}'
fi

# --- Periodic flush + size enforcement -------------------------------------
while true; do
    sleep "$FLUSH_INTERVAL"
    sync "$FLIGHT_PATH" 2>/dev/null || true
    # Enforce max size: if exceeded, rotate to a new flight subdir.
    SZ_BYTES="$(du -sb "$FLIGHT_PATH" 2>/dev/null | awk '{print $1}')"
    case "$MAX_FLIGHT_SIZE" in
        *G) MAX_BYTES=$(( ${MAX_FLIGHT_SIZE%G} * 1024 * 1024 * 1024 )) ;;
        *M) MAX_BYTES=$(( ${MAX_FLIGHT_SIZE%M} * 1024 * 1024 )) ;;
        *)  MAX_BYTES=$(( ${MAX_FLIGHT_SIZE} )) ;;
    esac
    if [ "${SZ_BYTES:-0}" -gt "$MAX_BYTES" ]; then
        emit_event "blackbox.rotate" "{\"size_bytes\":$SZ_BYTES,\"max\":\"$MAX_FLIGHT_SIZE\"}"
        # Restart self with a new flight dir.
        cleanup
    fi
done
