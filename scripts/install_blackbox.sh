#!/bin/bash
# =============================================================================
# scripts/install_blackbox.sh   install jetson_blackbox.sh as a systemd service
# =============================================================================
# Wires up:
#   • /etc/jetson-av/blackbox.conf              (operator-editable config)
#   • /etc/jetson-av/bag-qos.yaml               (rosbag QoS overrides)
#   • /var/log/jetson-av/flights/               (per-flight directory tree)
#   • /usr/local/bin/jetson_blackbox.sh         (the recorder daemon)
#   • /etc/systemd/system/jetson-blackbox.service (run on boot, restart on fail)
#
# After install: `systemctl status jetson-blackbox.service`
# Force a flush:  `kill -USR1 $(systemctl show jetson-blackbox -p MainPID --value)`
# =============================================================================
set -e
if [ "$EUID" -ne 0 ]; then echo "[!] must run as root" >&2; exit 1; fi

CONF_DIR=/etc/jetson-av
LOG_DIR=/var/log/jetson-av
mkdir -p "$CONF_DIR" "$LOG_DIR/flights"

# --- Config (only write if not present   operator may have customized) ----
if [ ! -f "$CONF_DIR/blackbox.conf" ]; then
    cat > "$CONF_DIR/blackbox.conf" <<'EOF'
# Black-box recorder configuration.
# Edit, then: systemctl restart jetson-blackbox.service

# Space-separated ROS 2 topics to record. Empty = no ROS bag (event log only).
ROS_TOPICS=""

# Where to write per-flight directories.
FLIGHT_DIR=/var/log/jetson-av/flights

# In-memory ring buffer length before flushing to disk (seconds).
RING_SECONDS=120

# Periodic flush interval (seconds).
FLUSH_INTERVAL=30

# Max bytes per flight before auto-rotating to a new subdir.
MAX_FLIGHT_SIZE=2G
EOF
fi

# --- Bag QoS overrides (sensible defaults) --------------------------------
if [ ! -f "$CONF_DIR/bag-qos.yaml" ]; then
    cat > "$CONF_DIR/bag-qos.yaml" <<'EOF'
# QoS overrides for ros2 bag record. Best-effort + small queue for high-rate
# camera topics; reliable + small queue for low-rate state.
/zed/zed_node/rgb/color/rect/image:
  reliability: best_effort
  history: keep_last
  depth: 1
/mavros/state:
  reliability: reliable
  history: keep_last
  depth: 5
EOF
fi

# --- Install daemon -------------------------------------------------------
install -m 0755 "$(dirname "$0")/jetson_blackbox.sh" /usr/local/bin/jetson_blackbox.sh

# --- systemd unit ---------------------------------------------------------
cat > /etc/systemd/system/jetson-blackbox.service <<'EOF'
[Unit]
Description=Jetson AV Black-Box Recorder (ROS bag + event log + ring buffer)
Documentation=file:///opt/docs/BLACKBOX.md
After=network.target multi-user.target
Wants=network.target
StartLimitIntervalSec=120
StartLimitBurst=5

[Service]
Type=simple
ExecStart=/usr/local/bin/jetson_blackbox.sh
Restart=always
RestartSec=5
TimeoutStopSec=15
KillMode=mixed
KillSignal=SIGINT
WatchdogSec=120
# A SIGUSR1 forces an immediate disk flush (used by mavlink_watchdog on
# safe-mode trigger or by an operator reaching for the "snapshot now" knob).
NotifyAccess=all

# Resource accounting so the recorder can't accidentally swallow the FS.
LimitNOFILE=8192
Nice=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable jetson-blackbox.service
systemctl restart jetson-blackbox.service || true

echo "Installed jetson-blackbox.service"
echo "  Config:  $CONF_DIR/blackbox.conf"
echo "  Logs:    $LOG_DIR/flights/"
echo "  Status:  systemctl status jetson-blackbox.service"
