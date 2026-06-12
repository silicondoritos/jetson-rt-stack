#!/bin/bash
# fix_snapd_jetson.sh   make snaps (Chromium/Chrome, etc.) installable and
# runnable on this Jetson image. Idempotent; safe to run on every boot.
#
# Root cause on this image: snap-confine requires the AppArmor LSM. The
# kernel-hardening fragment originally set CONFIG_LSM without apparmor, which
# silently dropped CONFIG_SECURITY_APPARMOR from the build entirely, so every
# snap fails to install or launch. The kernel side is fixed in the build
# fragment (CONFIG_SECURITY_APPARMOR=y + apparmor in CONFIG_LSM); this script
# handles the userspace side and verifies the kernel side, degrading loudly
# (not fatally) when running on a kernel without AppArmor.
set -u

log() { echo "[snapd-fix] $*"; }

if [ "$EUID" -ne 0 ]; then
    echo "[snapd-fix] must run as root" >&2
    exit 1
fi

# --- 1. Kernel-side check -----------------------------------------------------
LSM_ACTIVE="$(cat /sys/kernel/security/lsm 2>/dev/null || echo unknown)"
if echo "$LSM_ACTIVE" | grep -q apparmor; then
    log "kernel AppArmor: ACTIVE ($LSM_ACTIVE)"
    KERNEL_OK=1
else
    log "kernel AppArmor: MISSING (active LSMs: $LSM_ACTIVE)"
    log "snaps cannot be confined on this kernel; userspace will be prepared"
    log "but snap apps need the AppArmor-enabled kernel build to work."
    KERNEL_OK=0
fi

# --- 2. Userspace: apparmor + snapd packages ----------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get install -y apparmor apparmor-utils snapd squashfs-tools >/dev/null 2>&1 \
    && log "packages: apparmor + snapd present" \
    || log "WARN: apt install failed (offline?); continuing with what exists"

# --- 3. Services: apparmor profiles + snapd socket + snapd's apparmor unit ----
systemctl enable --now apparmor.service >/dev/null 2>&1 || true
systemctl enable --now snapd.socket >/dev/null 2>&1 || true
systemctl enable --now snapd.apparmor.service >/dev/null 2>&1 || true
systemctl restart snapd.service >/dev/null 2>&1 || true
log "services: apparmor + snapd(.socket) + snapd.apparmor enabled"

# --- 4. /snap symlink (snapd on Debian-layout systems needs it) ----------------
[ -e /snap ] || ln -s /var/lib/snapd/snap /snap 2>/dev/null || true

# --- 5. Wait for snapd seeding (the classic 'snap install hangs' on Jetson) ---
if command -v snap >/dev/null 2>&1; then
    timeout 120 snap wait system seed.loaded 2>/dev/null \
        && log "snapd: seeded" \
        || log "WARN: snapd seeding did not finish in 120s (needs internet once)"
fi

# --- 6. Verdict ----------------------------------------------------------------
if [ "$KERNEL_OK" = "1" ]; then
    log "READY: snaps should install and run (test: snap install hello-world)"
else
    log "PREPARED: userspace ready; kernel without AppArmor still blocks snap"
    log "apps. Flash the AppArmor-enabled kernel build to complete the fix."
fi
exit 0
