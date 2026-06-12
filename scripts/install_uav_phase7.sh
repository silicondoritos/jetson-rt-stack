#!/bin/bash
# =============================================================================
# scripts/install_uav_phase7.sh   Phase 7 (Platform Hardening) installer
# =============================================================================
# Orchestrates everything Phase 7 ships, with pre/post checks per step:
#
#   1. install_uav_resilience.sh    watchdog, journald, tmpfs, chrony, ufw, ssh
#   2. install_blackbox.sh          black-box recorder service
#   3. axelera_brownout_guard.sh    installed as service
#   4. mavlink_watchdog.sh          installed as service (skipped if no MAVROS)
#
# Idempotent. Run from jetson_first_boot.sh OR manually.
# =============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/config.sh"
. "$HERE/lib/log.sh"
. "$HERE/lib/verify.sh"
. "$HERE/lib/checks.sh"

PHASE=resilience

if [ "$EUID" -ne 0 ]; then
    log::fail "Must run as root"
fi

log::section "Phase 7: Platform Hardening"

# --- Step 1: core resilience hardening --------------------------------------
pre_resil()  { check::file_exists "$HERE/install_uav_resilience.sh"; }
exec_resil() { bash "$HERE/install_uav_resilience.sh"; }
post_resil() {
    check::file_exists /etc/jetson-av-resilience-installed
    check::file_exists /etc/systemd/system.conf.d/10-watchdog.conf
    check::file_exists /etc/systemd/journald.conf.d/10-av.conf
    check::file_exists /etc/ssh/sshd_config.d/10-av-hardening.conf
}
step::run "Install platform resilience" pre_resil exec_resil post_resil

# --- Step 2: black-box recorder service ------------------------------------
pre_bb()  { check::file_exists "$HERE/install_blackbox.sh"; }
exec_bb() { bash "$HERE/install_blackbox.sh"; }
post_bb() {
    check::file_exists /etc/systemd/system/jetson-blackbox.service
    check::file_exists /etc/jetson-av/blackbox.conf
    check::file_exists /usr/local/bin/jetson_blackbox.sh
}
step::run "Install black-box recorder" pre_bb exec_bb post_bb

# --- Step 3: brownout guard service ---------------------------------------
pre_bo()  { check::file_exists "$HERE/axelera_brownout_guard.sh"; }
exec_bo() {
    install -m 0755 "$HERE/axelera_brownout_guard.sh" /usr/local/bin/axelera_brownout_guard.sh
    mkdir -p /etc/jetson-av
    if [ ! -f /etc/jetson-av/brownout.conf ]; then
        cat > /etc/jetson-av/brownout.conf <<'EOF'
# Power cap for the Axelera Metis NPU (watts).
# Stock peak is ~20W; capping at 18W gives the PSU rail headroom for
# camera + GPU + SoC under load. Adjust per your DC-DC and battery.
AXELERA_POWER_LIMIT_W=18
# Axelera AI vendor:device ID per PCI ID DB + Axelera community confirmation:
# 1f9d:1100. The earlier "1d60" we used was wrong.
PCIE_VENDOR_ID=1f9d
PCIE_DEVICE_ID=1100
POLL_INTERVAL=5
EOF
    fi
    cat > /etc/systemd/system/jetson-brownout-guard.service <<'EOF'
[Unit]
Description=Axelera Metis brownout / PCIe link-down guard
Documentation=file:///opt/docs/UAV_RESILIENCE.md
After=multi-user.target
Wants=multi-user.target

[Service]
Type=simple
ExecStart=/usr/local/bin/axelera_brownout_guard.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable jetson-brownout-guard.service
    systemctl restart jetson-brownout-guard.service || true
}
post_bo() {
    check::file_exists /etc/systemd/system/jetson-brownout-guard.service
    check::file_exists /etc/jetson-av/brownout.conf
    check::file_exists /usr/local/bin/axelera_brownout_guard.sh
}
step::run "Install brownout guard" pre_bo exec_bo post_bo

# --- Step 3.4: PCIe AER monitor service (Gap 1 fix) -----------------------
pre_aer()  { check::file_exists "$HERE/jetson_pcie_aer_monitor.sh"; }
exec_aer() {
    install -m 0755 "$HERE/jetson_pcie_aer_monitor.sh" \
        /usr/local/bin/jetson-av-pcie-aer-monitor
    cat > /etc/systemd/system/jetson-av-pcie-aer-monitor.service <<'EOF'
[Unit]
Description=Jetson AV PCIe AER monitor (correctable + non-fatal + fatal counters)
Documentation=file:///opt/docs/UAV_RESILIENCE.md
After=multi-user.target jetson-blackbox.service
Wants=multi-user.target

[Service]
Type=simple
ExecStart=/usr/local/bin/jetson-av-pcie-aer-monitor
Restart=always
RestartSec=5
Nice=10

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable jetson-av-pcie-aer-monitor.service
    systemctl restart jetson-av-pcie-aer-monitor.service || true
}
post_aer() {
    check::file_exists /etc/systemd/system/jetson-av-pcie-aer-monitor.service
    check::executable /usr/local/bin/jetson-av-pcie-aer-monitor
}
step::run "Install PCIe AER monitor" pre_aer exec_aer post_aer

# --- Step 3.5: Durable data partition (btrfs single-drive) ----------------
pre_data() { check::file_exists "$HERE/install_data_partition.sh"; }
exec_data() { bash "$HERE/install_data_partition.sh"; }
post_data() {
    # Either a partition was made or a loop file was set up; either way the
    # mount point should now be a btrfs filesystem.
    findmnt -t btrfs /var/log/jetson-av/data >/dev/null 2>&1
}
STRICT=0 step::run "Install durable data partition" pre_data exec_data post_data

# --- Step 3.6: Telemetry failover (Doodle Labs primary + Iridium SBD) -----
pre_tf()  { check::file_exists "$HERE/install_telemetry_failover.sh"; }
exec_tf() { bash "$HERE/install_telemetry_failover.sh"; }
post_tf() {
    check::file_exists /etc/jetson-av/telemetry-failover.conf
    check::file_exists /etc/systemd/system/jetson-av-mavlink-router.service
}
STRICT=0 step::run "Install telemetry failover" pre_tf exec_tf post_tf

# --- Step 4: MAVLink watchdog service -------------------------------------
pre_mw()  { check::file_exists "$HERE/mavlink_watchdog.sh"; }
exec_mw() {
    install -m 0755 "$HERE/mavlink_watchdog.sh" /usr/local/bin/mavlink_watchdog.sh
    mkdir -p /etc/jetson-av
    if [ ! -f /etc/jetson-av/mavlink-watchdog.conf ]; then
        cat > /etc/jetson-av/mavlink-watchdog.conf <<'EOF'
HEARTBEAT_TIMEOUT=5
POLL_INTERVAL=1
FLUSH_BLACKBOX_ON_LOSS=1
EOF
    fi
    cat > /etc/systemd/system/jetson-mavlink-watchdog.service <<'EOF'
[Unit]
Description=MAVLink heartbeat watchdog (FCU link loss → black-box flush)
Documentation=file:///opt/docs/UAV_RESILIENCE.md
After=multi-user.target jetson-blackbox.service
Wants=multi-user.target

[Service]
Type=simple
ExecStart=/usr/local/bin/mavlink_watchdog.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable jetson-mavlink-watchdog.service
    # Don't fail the install if MAVROS isn't installed yet   service will
    # exit with the "MAVROS missing" message and systemd will keep retrying
    # which is the desired behavior.
    systemctl restart jetson-mavlink-watchdog.service || true
}
post_mw() {
    check::file_exists /etc/systemd/system/jetson-mavlink-watchdog.service
    check::file_exists /usr/local/bin/mavlink_watchdog.sh
}
step::run "Install MAVLink watchdog" pre_mw exec_mw post_mw

log::section "Phase 7 Install Complete"
log::ok "All resilience services installed."
echo
echo "Active services:"
systemctl --no-pager --type=service \
    list-unit-files \
    'jetson-*.service' \
    'tmp.mount' 2>/dev/null | grep -E 'jetson-|tmp.mount' || true
echo
step::summary
