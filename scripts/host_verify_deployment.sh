#!/bin/bash
# =============================================================================
#  HOST_VERIFY_DEPLOYMENT.SH - Deployment Integrity Watchtower
# =============================================================================
#  Purpose: Remote and local validation of the Jetson AV stack from the host.
# =============================================================================

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
L4T="$PROJECT_DIR/latest_jetson/Linux_for_Tegra"
ROOTFS="$L4T/rootfs"
JETSON_IP="192.168.55.1" # Default Ethernet-over-USB IP

BLUE='\033[0;34m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}=================================================================${NC}"
echo -e "         JETSON AV: HOST-SIDE INTEGRITY WATCHTOWER               ${NC}"
echo -e "${BLUE}=================================================================${NC}"

# --- 1. Pre-Flash Local Integrity ---
echo "[*] Phase A: Local Build Integrity (Pre-Flash)"

# Kernel Image Check
echo -n "    - Local Kernel Image Verstring: "
if [ -f "$L4T/kernel/Image" ]; then
    VERSTRING=$(strings "$L4T/kernel/Image" | grep "Linux version" | head -1 | awk '{print $3}')
    if [[ "$VERSTRING" == *"-tegra"* ]]; then
        echo -e "${GREEN}PASS${NC} ($VERSTRING)"
    else
        echo -e "${RED}FAIL${NC} ($VERSTRING is not RT)"
    fi
else
    echo -e "${RED}MISSING${NC} (No Image found at $L4T/kernel/Image)"
fi

# Bootloader Config Check
echo -n "    - RootFS Boot Parameters: "
EXTLINUX="$ROOTFS/boot/extlinux/extlinux.conf"
if [ -f "$EXTLINUX" ]; then
    if grep -q "isolcpus=1-5" "$EXTLINUX"; then
        echo -e "${GREEN}PASS${NC} (isolcpus=1-5 detected)"
    else
        echo -e "${RED}FAIL${NC} (No isolation in rootfs config)"
    fi
else
    echo -e "${YELLOW}PENDING${NC} (RootFS not yet baked or flashed)"
fi

# --- 2. Post-Flash Remote Verification ---
echo -e "\n[*] Phase B: Remote Target Verification (Post-Flash)"
echo -e "    Checking connectivity to $JETSON_IP... "

if ping -c 1 -W 2 "$JETSON_IP" &> /dev/null; then
    echo -e "    ${GREEN}[CONNECTED]${NC} Jetson is alive on the USB link."
    echo -e "    Executing Remote Gauntlet...\n"
    
    # Run the target-side gauntlet via SSH
    ssh -o ConnectTimeout=5 -t j@"$JETSON_IP" "sudo /home/j/verify_tuning.sh"
else
    echo -e "    ${RED}[OFFLINE]${NC} Jetson not detected at $JETSON_IP."
    echo -e "    Ensure the Jetson has finished its first boot and you are connected via USB."
fi

echo -e "${BLUE}=================================================================${NC}"
