#!/bin/bash
set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/config.sh"
. "$HERE/lib/log.sh"

log::section "Pre-Flash Audit: Kernel Integrity"

# --- 1. Kernel Image Vitals ---
log::step "Kernel Image: $KERNEL_IMAGE"

if [ ! -f "$KERNEL_IMAGE" ]; then
    log::fail "Image not found   run 'make build' first"
fi

# Version string must contain -tegra
VERSTRING=$(strings "$KERNEL_IMAGE" | grep "Linux version" | head -1 | awk '{print $3}')
if [[ "$VERSTRING" == *"-tegra"* ]]; then
    log::pass "Version string ($VERSTRING)"
else
    log::xfail "Version string" "$VERSTRING is stock   expected *-tegra*"
    GATE_FAILED=1
fi

# PREEMPT_RT   only required when CONFIG_KERNEL_PREEMPT_RT=y
if [ "${CONFIG_KERNEL_PREEMPT_RT:-y}" = "y" ]; then
    if strings "$KERNEL_IMAGE" | grep -q "PREEMPT_RT"; then
        log::pass "Real-time core (PREEMPT_RT present)"
    else
        log::xfail "Real-time core" "PREEMPT_RT not in Image   expected when CONFIG_KERNEL_PREEMPT_RT=y"
        GATE_FAILED=1
    fi
else
    log::info "PREEMPT_RT check skipped (CONFIG_KERNEL_PREEMPT_RT != y)"
fi

# DMABUF heaps   check Image strings then fall back to defconfig
if strings "$KERNEL_IMAGE" | grep -q "CONFIG_DMABUF_HEAPS" \
   || grep -q "CONFIG_DMABUF_HEAPS=y" "$DEFCONFIG_PATH" 2>/dev/null; then
    log::pass "DMABUF heaps"
else
    log::xfail "DMABUF heaps" "CONFIG_DMABUF_HEAPS not found"
    GATE_FAILED=1
fi

# PCIe retries   read actual value and compare to config expectation
EXPECTED_RETRIES="${CONFIG_PCIE_LINK_WAIT_MAX_RETRIES:-200}"
if [ -f "$PCIE_DESIGNWARE_H" ]; then
    ACTUAL_RETRIES=$(grep "LINK_WAIT_MAX_RETRIES" "$PCIE_DESIGNWARE_H" | awk '{print $3}' | tr -d '\r')
    if [ "$ACTUAL_RETRIES" = "$EXPECTED_RETRIES" ]; then
        log::pass "PCIe retries (LINK_WAIT_MAX_RETRIES=$ACTUAL_RETRIES)"
    else
        log::xfail "PCIe retries" "got $ACTUAL_RETRIES, expected $EXPECTED_RETRIES"
        GATE_FAILED=1
    fi
else
    log::warn "PCIe retries: source header missing   cannot verify"
fi

# Recency
LAST_MOD=$(stat -c %y "$KERNEL_IMAGE" | cut -d'.' -f1)
log::kv "Image last modified" "$LAST_MOD"

# --- 2. Bootloader Config ---
log::step "Bootloader config: $EXTLINUX_CONF"

if [ ! -f "$EXTLINUX_CONF" ]; then
    log::fail "extlinux.conf not found   run 'make bake' first"
fi

# CPU isolation + tickless   only required when LOW_JITTER + PREEMPT_RT
if [ "${CONFIG_LOW_JITTER:-y}" = "y" ] && [ "${CONFIG_KERNEL_PREEMPT_RT:-y}" = "y" ]; then
    CORES="${CONFIG_ISOLATED_CORE_RANGE:-1-5}"

    if grep -q "isolcpus=${CORES}" "$EXTLINUX_CONF"; then
        log::pass "CPU isolation (isolcpus=${CORES})"
    else
        log::xfail "CPU isolation" "isolcpus=${CORES} missing from extlinux.conf"
        GATE_FAILED=1
    fi

    if grep -q "nohz_full=${CORES}" "$EXTLINUX_CONF"; then
        log::pass "Tickless mode (nohz_full=${CORES})"
    else
        log::xfail "Tickless mode" "nohz_full=${CORES} missing from extlinux.conf"
        GATE_FAILED=1
    fi
else
    log::info "CPU isolation/tickless checks skipped (LOW_JITTER or PREEMPT_RT disabled)"
fi

# CMA policy: there must be NO cma= on the cmdline. A cmdline cma= bypasses
# the device tree's linux,cma pool, and large values (2048M) fail to reserve
# on Orin NX entirely -- zero CMA, which breaks nvgpu's contiguous comptag
# alloc at poweron (GR falcon / CUDA / nvpmodel all collapse). The DT pool
# (256MB) is the correct, stock-proven source. See TROUBLESHOOTING F-8.
if grep -qE "cma=[0-9]" "$EXTLINUX_CONF" 2>/dev/null; then
    log::xfail "CMA policy" "cma= found in extlinux.conf; it bypasses the DT linux,cma pool and 2048M fails to reserve (GPU breaks). Remove it."
    GATE_FAILED=1
else
    log::pass "CMA policy (no cmdline cma=; DT linux,cma pool in effect)"
fi

# ZED X overlay   only required when a ZED X camera is configured
if [ "${CONFIG_CAMERA_ZEDX_MONO:-n}" = "y" ] || [ "${CONFIG_CAMERA_ZEDX_DUO:-n}" = "y" ]; then
    DTBO_NAME="${CONFIG_ZEDX_DTBO_NAME:-$ZED_DTBO_NAME}"
    if grep -q "OVERLAYS" "$EXTLINUX_CONF"; then
        OVERLAY_PATH=$(grep "OVERLAYS" "$EXTLINUX_CONF" | head -1 | awk '{print $2}')
        if [ -f "$ROOTFS/$OVERLAY_PATH" ]; then
            log::pass "ZED X overlay ($(basename "$OVERLAY_PATH"))"
        else
            log::xfail "ZED X overlay" "DTBO declared in extlinux.conf but missing from rootfs: $OVERLAY_PATH"
            GATE_FAILED=1
        fi
    else
        log::xfail "ZED X overlay" "OVERLAYS line missing from extlinux.conf   run 'make bake'"
        GATE_FAILED=1
    fi
else
    log::info "ZED X overlay check skipped (CAMERA_NONE configured)"
fi

# --- 3. Vermagic Consistency ---
log::step "Module vermagic consistency"
VERIFIER="$REPO_ROOT/scripts/verify_vermagic.sh"
if [ -x "$VERIFIER" ]; then
    if L4T="$L4T_DIR" bash "$VERIFIER" --rootfs >/tmp/vermagic_audit.log 2>&1; then
        MATCHED=$(grep -oE 'match: [0-9]+' /tmp/vermagic_audit.log | head -1 | awk '{print $2}')
        log::pass "Module vermagic (${MATCHED:-?} modules consistent)"
    else
        log::xfail "Module vermagic" "mismatch detected   see /tmp/vermagic_audit.log"
        GATE_FAILED=1
    fi
else
    log::warn "verify_vermagic.sh not found   skipping vermagic gate"
fi

# --- 4. BUILD_MANIFEST present ---
log::step "Build manifest"
if [ -f "$BUILD_MANIFEST" ]; then
    log::pass "BUILD_MANIFEST.json present"
    log::kv "  kernel_release" "$(python3 -c "import json,sys; d=json.load(open('$BUILD_MANIFEST')); print(d.get('kernel_release','?'))" 2>/dev/null || echo '?')"
    log::kv "  git_state" "$(python3 -c "import json,sys; d=json.load(open('$BUILD_MANIFEST')); print(d.get('git_state','?'))" 2>/dev/null || echo '?')"
else
    log::warn "BUILD_MANIFEST.json missing   run 'make build'"
fi

# --- 5. Result ---
echo ""
if [ -z "${GATE_FAILED:-}" ]; then
    log::ok "READY FOR DEPLOYMENT   all gates green."
    exit 0
else
    log::fail "DO NOT FLASH   integrity checks failed. Review FAIL items above."
fi
