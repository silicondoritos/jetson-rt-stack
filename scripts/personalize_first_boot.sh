#!/bin/bash
# =============================================================================
# scripts/personalize_first_boot.sh   per-device identity at first boot
# =============================================================================
# Runs FIRST in jetson_first_boot.sh, before anything writes to /var or starts
# any network-facing service. Ensures every device on the fleet has a unique
# identity even when flashed from the same image.
#
# Operations:
#   1. Read /etc/jetson-av-fleet/device.conf if present (staged by
#      flash_batch.sh). Falls back to MAC-derived name if absent.
#   2. Set hostname.
#   3. Regenerate SSH host keys (delete the stock NVIDIA keys, ssh-keygen new).
#   4. (Optional) Write a static IP via systemd-networkd if STATIC_IP set.
#   5. Touch /etc/jetson-av-personalized so we don't redo it.
#
# Idempotent. Safe to re-run; will skip steps already done.
# =============================================================================
set -e

if [ "$EUID" -ne 0 ]; then
    echo "[!] personalize_first_boot.sh must run as root" >&2
    exit 1
fi

MARKER=/etc/jetson-av-personalized
CONF=/etc/jetson-av-fleet/device.conf

if [ -f "$MARKER" ]; then
    echo "[personalize] already done ($MARKER)   skipping"
    exit 0
fi

# --- 1. Resolve identity ----------------------------------------------------
DEVICE_LABEL=""
NEW_HOSTNAME=""
STATIC_IP=""

if [ -f "$CONF" ]; then
    # shellcheck disable=SC1090
    . "$CONF"
    DEVICE_LABEL="${DEVICE_LABEL:-}"
    NEW_HOSTNAME="${HOSTNAME:-}"
    STATIC_IP="${STATIC_IP:-}"
    echo "[personalize] config: label=$DEVICE_LABEL host=$NEW_HOSTNAME ip=$STATIC_IP"
fi

# Fallback: derive a unique name from the primary NIC's MAC.
if [ -z "$NEW_HOSTNAME" ]; then
    MAC="$(ip -o link show 2>/dev/null \
            | awk '/ether/ && $2 !~ /^lo:/ {print $17; exit}' \
            | tr -d ':')"
    if [ -n "$MAC" ]; then
        NEW_HOSTNAME="jetson-${MAC: -6}"   # last 6 hex chars
    else
        NEW_HOSTNAME="jetson-$(date +%s | tail -c 6)"
    fi
    echo "[personalize] no config   derived hostname: $NEW_HOSTNAME"
fi

# --- 2. Hostname ------------------------------------------------------------
CURRENT_HOST="$(hostname)"
if [ "$CURRENT_HOST" != "$NEW_HOSTNAME" ]; then
    echo "[personalize] hostname: $CURRENT_HOST → $NEW_HOSTNAME"
    hostnamectl set-hostname "$NEW_HOSTNAME"
    # Update /etc/hosts so sudo doesn't complain about resolving the hostname.
    if grep -q "127.0.1.1" /etc/hosts; then
        sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts
    else
        printf '127.0.1.1\t%s\n' "$NEW_HOSTNAME" >> /etc/hosts
    fi
fi

# --- 3. Regenerate SSH host keys -------------------------------------------
# The stock rootfs ships SSH host keys baked into the image   every flashed
# device starts identical, which trips "host key changed" warnings the moment
# two are on the same network. Regenerate per device.
echo "[personalize] regenerating SSH host keys"
rm -f /etc/ssh/ssh_host_*key /etc/ssh/ssh_host_*key.pub
ssh-keygen -A
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true

# --- 4. Optional static IP via systemd-networkd ----------------------------
if [ -n "$STATIC_IP" ]; then
    # Find the wired interface (excludes lo, usb0, tun*, docker*, virbr*).
    IFACE="$(ip -o link show 2>/dev/null \
              | awk -F': ' '/state UP/ && $2 !~ /^(lo|usb|tun|docker|virbr|wlx?)/ \
                            {print $2; exit}' \
              | awk '{print $1}')"
    if [ -n "$IFACE" ]; then
        cat > "/etc/systemd/network/10-jetson-av-${IFACE}.network" <<EOF
[Match]
Name=$IFACE

[Network]
Address=$STATIC_IP/24
DHCP=no
EOF
        echo "[personalize] static IP $STATIC_IP on $IFACE"
        systemctl restart systemd-networkd 2>/dev/null || true
    else
        echo "[personalize] WARN: no wired iface found; skipping static IP"
    fi
fi

# --- 5. Marker --------------------------------------------------------------
{
    echo "device_label=$DEVICE_LABEL"
    echo "hostname=$NEW_HOSTNAME"
    echo "static_ip=$STATIC_IP"
    echo "personalized_at=$(date -u -Iseconds)"
} > "$MARKER"
chmod 644 "$MARKER"

echo "[personalize] done   see $MARKER"
