#!/bin/bash
# =============================================================================
# scripts/install_uav_resilience.sh   Operational hardening (target-side)
# =============================================================================
# Runs from jetson_first_boot.sh (or manually). Sets up everything that keeps
# the vehicle operational under fault conditions:
#
#   • systemd watchdog (RuntimeWatchdogSec=30s + per-service WatchdogSec)
#   • persistent journald with size cap (/var/log/journal)
#   • aggressive logrotate (so /var doesn't fill up after weeks of flight)
#   • /tmp on tmpfs (prevent SSD wear)
#   • chrony NTP (and optional ptp4l for hardware time sync)
#   • SSH hardening (key-only, no root login)
#   • UFW firewall with safe defaults
#   • smartmontools for NVMe health
#   • Marker file at /etc/jetson-av-resilience-installed
#
# Idempotent   every step is guarded.
# =============================================================================
set -e

if [ "$EUID" -ne 0 ]; then echo "[!] must run as root" >&2; exit 1; fi

MARKER=/etc/jetson-av-resilience-installed
echo "==========================================="
echo " Platform Resilience Hardening"
echo "==========================================="

# ------ 1. Required packages -----------------------------------------------
need_pkgs() {
    local missing=()
    for p in "$@"; do
        dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "[*] Installing: ${missing[*]}"
        apt-get update -qq
        apt-get install -y "${missing[@]}"
    fi
}
need_pkgs chrony ufw logrotate smartmontools nvme-cli systemd-timesyncd

# ------ 0. Coordinated power policy (Gap 6+9 fix) -------------------------
# Single source of truth for the JETSON+METIS power budget. Read by both
# jetson_rt_tune.sh (GPU/CPU/EMC clocks, fan) AND axelera_brownout_guard.sh
# (Metis power cap). Default values target a typical 19V/4A (76 W) power supply
# rail with margin: Jetson MAXN ≤ ~25 W + Metis ≤ 18 W = ~43 W.
mkdir -p /etc/jetson-av
if [ ! -f /etc/jetson-av/power.conf ]; then
    cat > /etc/jetson-av/power.conf <<'EOF'
# Coordinated power budget for the AV platform.
# Total budget MUST stay below your DC-DC + battery sustained capability.
#
# nvpmodel mode (4=MAXN_SUPER/40W, 0=MAXN/25W, 1=15W, 2=10W on Orin NX 16GB).
NVPMODEL_MODE=4

# Optional GPU clock cap (Hz). Empty = use hardware max.
# Set this when EMC bandwidth contention with Metis is observed (cuVSLAM
# saturating LPDDR5 stalls Metis inference). Typical Orin NX GA10B max is
# 918 MHz; cap to 800 MHz with: GPU_MAX_FREQ_HZ=800000000
GPU_MAX_FREQ_HZ=

# Optional EMC frequency override (Hz). Empty = use hardware max.
EMC_FREQ_HZ=

# CPU frequency governor.
LOCK_CPU_GOV=performance

# Fan PWM 0-255 (255=100%).
FAN_PWM=255

# Axelera Metis power cap in watts. Below ~23 W peak datasheet limit;
# 18 W gives PSU rail headroom for camera + GPU + SoC under load.
AXELERA_POWER_LIMIT_W=18
EOF
fi

# ------ 2. Persistent journald with size cap -------------------------------
echo "[*] Configuring persistent journald..."
mkdir -p /var/log/journal
systemd-tmpfiles --create --prefix /var/log/journal
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/10-av.conf <<'EOF'
# Platform resilience: persistent journal capped at 2 GB so weeks of flight
# logs survive reboot but don't fill the SSD.
[Journal]
Storage=persistent
SystemMaxUse=2G
SystemKeepFree=4G
SystemMaxFileSize=128M
ForwardToSyslog=no
EOF
systemctl restart systemd-journald

# ------ 3. systemd watchdog -------------------------------------------------
echo "[*] Configuring systemd watchdog..."
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/10-watchdog.conf <<'EOF'
# Platform resilience: pet the hardware watchdog every 30s, force reboot if pid1
# stops responding. Hardware watchdog is exposed by the Tegra HW IP block
# at /dev/watchdog.
[Manager]
RuntimeWatchdogSec=30s
RebootWatchdogSec=2min
ShutdownWatchdogSec=2min
EOF
systemctl daemon-reexec || true

# ------ 4. /tmp on tmpfs (avoid SSD wear) ----------------------------------
echo "[*] Mounting /tmp on tmpfs..."
if ! systemctl is-enabled tmp.mount >/dev/null 2>&1; then
    cp /usr/share/systemd/tmp.mount /etc/systemd/system/tmp.mount 2>/dev/null \
       || cat > /etc/systemd/system/tmp.mount <<'EOF'
[Unit]
Description=Temporary Directory /tmp
ConditionPathIsSymbolicLink=!/tmp
DefaultDependencies=no
Conflicts=umount.target
Before=local-fs.target umount.target

[Mount]
What=tmpfs
Where=/tmp
Type=tmpfs
Options=mode=1777,strictatime,nosuid,nodev,size=2G

[Install]
WantedBy=local-fs.target
EOF
    systemctl enable tmp.mount
fi

# ------ 5. logrotate AV rules ----------------------------------------------
echo "[*] Configuring aggressive logrotate..."
cat > /etc/logrotate.d/jetson-av <<'EOF'
# Keep system logs small; flight logs get separate retention.
/var/log/syslog
/var/log/auth.log
/var/log/kern.log
{
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    sharedscripts
    postrotate
        /usr/lib/rsyslog/rsyslog-rotate 2>/dev/null || true
    endscript
}

/var/log/jetson-av/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
}
EOF
mkdir -p /var/log/jetson-av

# ------ 6. Time sync (chrony with NTP fallback) ----------------------------
echo "[*] Configuring chrony NTP..."
cat > /etc/chrony/chrony.conf <<'EOF'
# Time sync   talk to public pools, fall back to GPS PPS if the FC
# exposes one (hook up via gpsd later).
pool 0.pool.ntp.org iburst
pool 1.pool.ntp.org iburst
pool 2.pool.ntp.org iburst
makestep 1.0 3
rtcsync
driftfile /var/lib/chrony/chrony.drift
logdir /var/log/chrony
EOF
systemctl enable chrony
systemctl restart chrony

# ------ 7. SSH hardening ----------------------------------------------------
echo "[*] Hardening SSH..."
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-av-hardening.conf <<'EOF'
# Platform resilience: key-only auth, no root login, fast disconnect on idle.
PasswordAuthentication no
PermitRootLogin no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
ClientAliveInterval 60
ClientAliveCountMax 2
EOF
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true

# ------ 8. Firewall (UFW) ---------------------------------------------------
echo "[*] Configuring UFW firewall..."
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
# ROS 2 DDS multicast port range (FastDDS default).
ufw allow 7400:7500/udp
# MAVLink (FCU bridge default).
ufw allow 14550/udp
ufw --force enable

# ------ 9. NVMe SMART monitoring + write-cache policy ----------------------
echo "[*] Enabling SMART monitoring for NVMe..."
systemctl enable smartmontools
systemctl restart smartmontools

# NVMe Volatile Write Cache (VWC). For Black-box durability we want this
# OFF so that data on disk is data on flash   no in-flight buffer to lose
# on a sudden power-cut. Trade-off: ~2x sequential write throughput hit.
# Tunable via /etc/jetson-av/storage.conf:
#   NVME_VWC=off   ← default (data integrity > throughput)
#   NVME_VWC=on    ← only if you measure write throughput as a bottleneck
#   NVME_VWC=skip  ← don't touch the device default
NVME_VWC_DEFAULT=off
mkdir -p /etc/jetson-av
if [ ! -f /etc/jetson-av/storage.conf ]; then
    cat > /etc/jetson-av/storage.conf <<EOF
# AV NVMe storage policy.
# NVME_VWC: off | on | skip   (volatile write cache; off=durable, on=fast)
NVME_VWC=$NVME_VWC_DEFAULT
EOF
fi
# shellcheck disable=SC1091
. /etc/jetson-av/storage.conf
case "${NVME_VWC:-skip}" in
    off)
        if command -v nvme >/dev/null 2>&1 && [ -e /dev/nvme0 ]; then
            nvme set-feature /dev/nvme0 -f 6 -v 0 2>/dev/null \
                && echo "   → NVMe volatile write cache: OFF (durable)" \
                || echo "   → NVMe VWC set-feature failed (drive may not support 0x06)"
        fi
        ;;
    on)
        nvme set-feature /dev/nvme0 -f 6 -v 1 2>/dev/null \
            && echo "   → NVMe volatile write cache: ON (faster, less durable)"
        ;;
    skip|*)
        echo "   → NVMe VWC: leaving at device default"
        ;;
esac

# Persist VWC setting across reboot via udev rule (NVMe loses set-feature on
# power-cycle).
cat > /etc/udev/rules.d/65-jetson-av-nvme.rules <<'EOF'
# Apply AV NVMe write-cache policy on every NVMe enumeration.
ACTION=="add", SUBSYSTEM=="nvme", KERNEL=="nvme0", \
    RUN+="/bin/sh -c '[ -f /etc/jetson-av/storage.conf ] && . /etc/jetson-av/storage.conf; \
                       case \"$NVME_VWC\" in off) /usr/sbin/nvme set-feature /dev/nvme0 -f 6 -v 0 ;; \
                                              on)  /usr/sbin/nvme set-feature /dev/nvme0 -f 6 -v 1 ;; esac' "
EOF
udevadm control --reload-rules 2>/dev/null || true

# ------ 10. Marker ---------------------------------------------------------
{
    echo "installed_at=$(date -u -Iseconds)"
    echo "host=$(hostname)"
} > "$MARKER"

# The tmp.mount activation wipes /tmp, which deletes the ZED IMU_Daemon's
# unix socket (/tmp/imu_daemon.sock) while the daemon stays "active"   the
# SDK then fails with "Failed to connect to daemon socket" (observed live
# 2026-06-11). Restart the chain if it is installed.
if systemctl is-enabled IMU_Daemon.service >/dev/null 2>&1; then
    echo "[*] Restarting ZED daemon chain (tmp.mount wiped its socket)..."
    systemctl restart driver_zed_loader.service 2>/dev/null || true
    sleep 3
    systemctl restart zed_x_daemon.service IMU_Daemon.service 2>/dev/null || true
fi

echo "==========================================="
echo " Platform Resilience installed."
echo " Reboot once to fully activate watchdog + tmp.mount."
echo "==========================================="
