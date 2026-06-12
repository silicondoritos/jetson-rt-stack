#!/bin/bash
# =============================================================================
#  VERIFY_TUNING.SH - Jetson AV Performance Gauntlet
# =============================================================================
#  Mandate: Rapid validation of real-time and silicon-level tuning.
#  Usage: Run on the Jetson after the second boot (post-initialization).
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=================================================================${NC}"
echo -e "${BLUE}         JETSON AV TUNING VERIFICATION GAUNTLET                  ${NC}"
echo -e "${BLUE}=================================================================${NC}"

# --- 1. Kernel Identity ---
echo -n "[*] Verifying Kernel Identity... "
KERNEL_VER=$(uname -r)
if [[ "$KERNEL_VER" == *"-tegra"* ]]; then
    echo -e "${GREEN}PASS${NC} ($KERNEL_VER)"
else
    echo -e "${RED}FAIL${NC} ($KERNEL_VER is not the RT kernel)"
fi

# --- 2. Silicon Sovereignty (Cores 1-5) ---
echo -n "[*] Verifying CPU Isolation (isolcpus=1-5)... "
ISOLATED=$(cat /sys/devices/system/cpu/isolated)
if [ "$ISOLATED" == "1-5" ]; then
    echo -e "${GREEN}PASS${NC} ($ISOLATED)"
else
    echo -e "${RED}FAIL${NC} (Got '$ISOLATED', expected '1-5')"
fi

echo -n "[*] Verifying Tickless Cores (nohz_full=1-5)... "
if grep -q "nohz_full=1-5" /proc/cmdline; then
    echo -e "${GREEN}PASS${NC}"
else
    echo -e "${RED}FAIL${NC} (Check /boot/extlinux/extlinux.conf)"
fi

# --- 3. Memory Highway (CMA from the DT linux,cma pool) ---
# No cma= boot arg is passed: cmdline cma= bypasses the DT pool and cma=2048M
# fails to reserve on Orin NX entirely (zero CMA, which kills nvgpu comptag
# allocation, CUDA, and nvpmodel; see docs/TROUBLESHOOTING.md F-8). The DT
# pool provides 256MB; the GPU needs ~64MB contiguous at poweron, so the
# healthy floor here is >=200MB AND zero is an automatic fail.
echo -n "[*] Verifying CMA Reservation (DT pool, >=200MB)... "
CMA_TOTAL=$(grep CmaTotal /proc/meminfo | awk '{print $2}')
if [ "$CMA_TOTAL" -gt 200000 ]; then
    echo -e "${GREEN}PASS${NC} (~$(($CMA_TOTAL / 1024)) MB)"
else
    echo -e "${RED}FAIL${NC} ($(($CMA_TOTAL / 1024)) MB; zero means a cma= boot arg broke the DT pool, see TROUBLESHOOTING F-8)"
fi

# --- 4. Hardware Presence ---
echo -e "\n[*] Probing Hardware Linkages:"

# Axelera Metis. Match on vendor (1f9d:) only, not 1f9d:1100: rev-02 boards are
# 1f9d:1100 but rev-01 boards enumerate as 1f9d:11aa. (The older "1d60" was wrong.)
echo -n "    - Axelera Metis (PCIe): "
if lspci -d 1f9d: 2>/dev/null | grep -q . || lspci 2>/dev/null | grep -qi "Axelera"; then
    LINK_STA=$(sudo lspci -vvv -d 1f9d: 2>/dev/null | grep "LnkSta:" | head -1 | xargs)
    echo -e "${GREEN}DETECTED${NC} ($LINK_STA)"
else
    echo -e "${RED}GHOST${NC} (Check physical connection and 100-retry patch)"
fi

# ZED X
echo -n "    - ZED X Driver (sl_zedx): "
if lsmod | grep -q "sl_zedx"; then
    echo -e "${GREEN}LOADED${NC}"
else
    echo -e "${YELLOW}MISSING${NC} (Modprobe failed or driver not built)"
fi

# Metis Driver
echo -n "    - Metis Driver (metis): "
if lsmod | grep -q "metis"; then
    echo -e "${GREEN}LOADED${NC}"
else
    echo -e "${YELLOW}MISSING${NC}"
fi

# --- Per-target expectations ----------------------------------------------
# Mission profile decides which drivers MUST be present. Read from
# /etc/jetson-av/expectations.conf if it exists, otherwise default to
# "expect everything" (the default for the full-payload configuration).
EXPECT_FILE=/etc/jetson-av/expectations.conf
EXPECT_ZED_X="${EXPECT_ZED_X:-1}"
EXPECT_METIS="${EXPECT_METIS:-1}"
EXPECT_MAX9296="${EXPECT_MAX9296:-$EXPECT_ZED_X}"   # implied by ZED X
if [ -f "$EXPECT_FILE" ]; then
    # shellcheck disable=SC1090
    . "$EXPECT_FILE"
fi
GAUNTLET_FAILED=0

# --- Vermagic check: walk EVERY .ko under /lib/modules/$(uname -r) -------
# Catches partial vermagic drift (e.g. one OOT module slipped in via apt
# while the rest of the tree is correct). Earlier revisions only checked
# 3 mission-critical modules, which let other modules silently mismatch.
echo -e "\n[*] Module Vermagic Sanity (every .ko under /lib/modules/$(uname -r)):"
KREL=$(uname -r)
TOTAL=0; OK=0; MISMATCH=0
MISMATCH_LIST=()
while IFS= read -r ko; do
    [ -f "$ko" ] || continue
    TOTAL=$((TOTAL+1))
    VM=$(modinfo "$ko" 2>/dev/null | awk -F': *' '/^vermagic:/{print $2; exit}')
    if echo "$VM" | grep -q "$KREL"; then
        OK=$((OK+1))
    else
        MISMATCH=$((MISMATCH+1))
        MISMATCH_LIST+=("$ko :: $VM")
    fi
done < <(find "/lib/modules/$KREL" -name '*.ko*' -type f 2>/dev/null)

if [ "$TOTAL" -eq 0 ]; then
    echo -e "    ${RED}FAIL${NC} no modules found under /lib/modules/$KREL"
    GAUNTLET_FAILED=1
elif [ "$MISMATCH" -eq 0 ]; then
    echo -e "    ${GREEN}PASS${NC} all $TOTAL modules carry vermagic for $KREL"
else
    echo -e "    ${RED}FAIL${NC} $MISMATCH of $TOTAL modules have wrong vermagic:"
    for entry in "${MISMATCH_LIST[@]:0:10}"; do
        echo -e "      ${RED}*${NC} $entry"
    done
    [ "${#MISMATCH_LIST[@]}" -gt 10 ] && echo "      … +$((${#MISMATCH_LIST[@]}-10)) more"
    GAUNTLET_FAILED=1
fi

# --- Mission-critical driver loaded checks (LOUD FAIL when expected) ----
# Earlier behavior was YELLOW "MISSING"   that let users miss the fact that
# a flashed device has no functional camera or NPU. Now we hard-fail when
# expectations say the driver should be loaded.
echo -e "\n[*] Mission-critical drivers (loud-fail per expectations.conf):"
check_expected_driver() {
    local label="$1" modname="$2" expect="$3"
    if lsmod | awk '{print $1}' | grep -qx "$modname"; then
        echo -e "    - ${label}: ${GREEN}LOADED${NC}"
        return 0
    fi
    if [ "$expect" = "1" ]; then
        echo -e "    - ${label}: ${RED}MISSING (EXPECTED)${NC}"
        echo -e "      → set ${BLUE}EXPECT_$(echo $modname | tr a-z A-Z)=0${NC} in $EXPECT_FILE if not installed on this airframe"
        GAUNTLET_FAILED=1
    else
        echo -e "    - ${label}: ${YELLOW}not present (not expected)${NC}"
    fi
}
check_expected_driver "Axelera Metis (metis)"         "metis"     "$EXPECT_METIS"
check_expected_driver "Stereolabs ZED X (sl_zedx)"    "sl_zedx"   "$EXPECT_ZED_X"
check_expected_driver "GMSL2 deserializer (max9296)"  "max9296"   "$EXPECT_MAX9296"

# --- 5. Performance Mode ---
echo -n -e "\n[*] Verifying Power Mode (MAXN)... "
# nvpmodel output differs by release: some print "ID: N", R36.4.3 prints the
# bare mode number on the line after "NV Power Mode"   accept both.
POWER_MODE=$(nvpmodel -q 2>/dev/null | grep -oE 'ID: *[0-9]+' | grep -oE '[0-9]+' | head -1)
[ -n "$POWER_MODE" ] || \
    POWER_MODE=$(nvpmodel -q 2>/dev/null | awk '/NV Power Mode/{getline; print $1; exit}')
if [ "$POWER_MODE" == "0" ]; then
    echo -e "${GREEN}PASS${NC}"
else
    echo -e "${RED}FAIL${NC} (Current: $POWER_MODE, Expected: 0)"
fi

# --- 6. Real-Time Jitter Check (10s Burst) ---
echo -e "\n[*] Executing Rapid Jitter Test (10s on Core 1)..."
if command -v cyclictest &> /dev/null; then
    # Run cyclictest on isolated core 1 for 10 seconds.
    # No -n: rt-tests 2.x removed --nanosleep (it is the default mode now);
    # passing it makes cyclictest print usage and exit (observed 2026-06-10).
    sudo cyclictest -m -p 99 -t 1 -a 1 -D 10s --quiet > /tmp/jitter_results
    MAX_LATENCY=$(grep "Max:" /tmp/jitter_results | awk -F 'Max:' '{print $2}' | xargs)
    if [ -n "$MAX_LATENCY" ] && [ "$MAX_LATENCY" -lt 100 ]; then
        echo -e "    -> Max Latency: ${GREEN}${MAX_LATENCY}us${NC} (Deterministic)"
    else
        echo -e "    -> Max Latency: ${RED}${MAX_LATENCY}us${NC} (JITTER DETECTED)"
        GAUNTLET_FAILED=1
    fi
else
    echo -e "    ${YELLOW}WARN: cyclictest not found. Skipping latency check.${NC}"
fi

echo -e "${BLUE}=================================================================${NC}"
if [ "${GAUNTLET_FAILED:-0}" -eq 0 ]; then
    echo -e " ${GREEN}GAUNTLET PASS${NC}"
else
    echo -e " ${RED}GAUNTLET FAIL   investigate FAIL items above before flying${NC}"
fi
echo -e "${BLUE}=================================================================${NC}"
exit "${GAUNTLET_FAILED:-0}"
