#!/bin/bash
# =============================================================================
# scripts/05_post_flash_validate.sh   post-flash deployment validator
# =============================================================================
# Walks every check that the platform docs say "you must verify after flash":
#   • SSH reachability on $TARGET_USB_IP
#   • RT kernel version, isolated cores, CMA size
#   • Hardware: Axelera Metis (lspci+lsmod), ZED X (lsmod+v4l2), DMA heaps
#   • Vermagic of mission-critical modules (sl_zedx, metis, max9296)
#   • Cyclictest jitter check (10s, on isolated core 1)
#   • ZED SDK / Voyager runtime importability inside /opt/av-env
#
# Runs from the host. The script SSHes to the target as $TARGET_USER@$TARGET_USB_IP
# and executes verify_tuning.sh remotely (already baked into the rootfs).
#
# Exits 0 only if every check passes.
# =============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/config.sh"
. "$HERE/lib/log.sh"

TARGET="${TARGET_USER}@${TARGET_USB_IP}"
SSH_OPTS=(-o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
          -o UserKnownHostsFile=/tmp/jetson_known_hosts)

log::section "Post-Flash Deployment Validation"
log::info "Target: $TARGET"

# --- 1. Connectivity ---------------------------------------------------------
log::step "Probing target..."
if ping -c 1 -W 2 "$TARGET_USB_IP" >/dev/null 2>&1; then
    log::pass "ICMP reachable"
else
    log::fail "Target $TARGET_USB_IP not reachable. Is the Jetson booted? USB-Ethernet up?"
fi

if ssh "${SSH_OPTS[@]}" "$TARGET" "true" 2>/dev/null; then
    log::pass "SSH reachable"
else
    log::fail "SSH to $TARGET failed. Check user '$TARGET_USER' and credentials."
fi

# --- 2. Run on-target verify_tuning.sh ---------------------------------------
log::step "Running on-target verification gauntlet..."
echo
ssh "${SSH_OPTS[@]}" "$TARGET" "sudo /home/$TARGET_USER/verify_tuning.sh" \
    || log::fail "verify_tuning.sh on target reported failures"
echo

# --- 3. Headers .deb installed (DKMS readiness) ------------------------------
log::step "Confirming linux-headers .deb is in place..."
if ssh "${SSH_OPTS[@]}" "$TARGET" \
       "test -d /usr/src/linux-headers-\$(uname -r) && echo OK" 2>/dev/null \
       | grep -q OK; then
    log::pass "/usr/src/linux-headers-\$(uname -r) present"
else
    log::xfail "kernel headers" "DKMS-based installers (ZED SDK / Voyager) will fail"
fi

# --- 4. AV Python env -------------------------------------------------------
log::step "Probing /opt/av-env..."
if ssh "${SSH_OPTS[@]}" "$TARGET" "test -x /opt/av-env/bin/python && echo OK" \
       2>/dev/null | grep -q OK; then
    log::pass "/opt/av-env venv present"

    # Voyager runtime importable
    if ssh "${SSH_OPTS[@]}" "$TARGET" \
           "/opt/av-env/bin/python -c 'import axelera.runtime' 2>&1" \
           | grep -qv 'Error\|Traceback'; then
        log::pass "axelera.runtime importable"
    else
        log::xfail "axelera.runtime" "venv built but Voyager wheels not installed"
    fi

    # PyTorch importable & CUDA visible
    if ssh "${SSH_OPTS[@]}" "$TARGET" \
           "/opt/av-env/bin/python -c 'import torch; print(torch.cuda.is_available())' 2>&1" \
           | grep -q True; then
        log::pass "torch + CUDA usable"
    else
        log::xfail "torch CUDA" "PyTorch wheel mismatch or CUDA driver issue"
    fi
else
    log::xfail "/opt/av-env" "first-boot script did not run or failed"
fi

# --- 4b. Power profile + thermal headroom ----------------------------------
# Confirm MAXN is actually the active profile (not just configured) and that
# no thermal zone is currently throttling. A quietly-throttling Jetson at
# idle is a "we never got the power-budget we paid for" signal.
log::step "Probing power profile + thermal..."
NVPMODEL_OUT="$(ssh "${SSH_OPTS[@]}" "$TARGET" "nvpmodel -q 2>&1" 2>/dev/null || echo unknown)"
if echo "$NVPMODEL_OUT" | grep -qE "MAXN|MODE_25W|^NV Power Mode: ?MAXN"; then
    log::pass "nvpmodel: MAXN active"
elif echo "$NVPMODEL_OUT" | grep -qE "^.*ID:[[:space:]]*0"; then
    log::pass "nvpmodel: mode 0 (MAXN equivalent)"
else
    log::xfail "nvpmodel" "not MAXN   see below"
    echo "$NVPMODEL_OUT" | sed 's/^/      /'
fi

# Check thermal zones   any cooling_device cur_state > 0 means we're already
# throttling at idle, which is a hardware/cooling problem to solve before
# expecting deterministic latency under inference load.
THERM=$(ssh "${SSH_OPTS[@]}" "$TARGET" \
    'for z in /sys/class/thermal/thermal_zone*/temp; do
         t=$(cat $z 2>/dev/null);
         [ -n "$t" ] && printf "%s=%d " "$(basename $(dirname $z))" "$((t/1000))";
       done; echo;
       for c in /sys/class/thermal/cooling_device*/cur_state; do
         s=$(cat $c 2>/dev/null);
         [ "${s:-0}" -gt 0 ] && echo "ACTIVE_COOLING:$(basename $(dirname $c))=$s";
       done' 2>/dev/null)
log::kv "Thermals" "$(echo "$THERM" | head -1)"
if echo "$THERM" | grep -q "ACTIVE_COOLING"; then
    log::xfail "thermal" "cooling device already engaged at idle:"
    echo "$THERM" | grep ACTIVE_COOLING | sed 's/^/      /'
else
    log::pass "no cooling devices engaged at idle"
fi

# --- 5. ZED SDK userspace ---------------------------------------------------
log::step "Probing ZED SDK userspace..."
if ssh "${SSH_OPTS[@]}" "$TARGET" \
       "test -f /usr/local/zed/include/sl/Camera.hpp && echo OK" 2>/dev/null \
       | grep -q OK; then
    log::pass "ZED SDK headers present"
    if ssh "${SSH_OPTS[@]}" "$TARGET" \
           "/opt/av-env/bin/python -c 'import pyzed.sl' 2>&1" \
           | grep -qv 'Error\|Traceback'; then
        log::pass "pyzed importable"
    else
        log::xfail "pyzed" "SDK userspace OK but pyzed bindings missing"
    fi
else
    log::warn "ZED SDK not installed   run /opt/zed-sdk/install_zed_sdk.sh on target"
    GATE_FAILED=${GATE_FAILED:-0}  # warning, not failure
fi

# --- Summary ----------------------------------------------------------------
echo
log::section "Validation Result"
if [ "${GATE_FAILED:-0}" = "0" ]; then
    log::ok "Deployment validated   target is mission-ready."
    exit 0
else
    log::fail "Deployment validation FAILED   see above."
fi
