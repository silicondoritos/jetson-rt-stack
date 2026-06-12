#!/bin/bash
# =============================================================================
#  CHECK_KERNEL_TUNING.SH - Surgical Tuning Verification
# =============================================================================
#  Purpose: Strictly verify kernel-level real-time and memory tuning.
# =============================================================================

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
L4T="$PROJECT_DIR/latest_jetson/Linux_for_Tegra"
JETSON_IP="192.168.55.1"

BLUE='\033[0;34m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}--- KERNEL TUNING SITREP ---${NC}"

# Remote check via SSH
if ping -c 1 -W 1 "$JETSON_IP" &> /dev/null; then
    ssh -o ConnectTimeout=2 j@"$JETSON_IP" << 'EOF'
        echo -n "[*] RT Kernel: "
        uname -v | grep -q "PREEMPT RT" && echo -ne "\033[0;32mPASS\033[0m " || echo -ne "\033[0;31mFAIL\033[0m "
        uname -r

        echo -n "[*] CPU Isolation: "
        ISOL=$(cat /sys/devices/system/cpu/isolated)
        [ "$ISOL" == "1-5" ] && echo -e "\033[0;32mPASS\033[0m ($ISOL)" || echo -e "\033[0;31mFAIL\033[0m ($ISOL)"

        echo -n "[*] Tickless Mode: "
        grep -q "nohz_full=1-5" /proc/cmdline && echo -e "\033[0;32mPASS\033[0m" || echo -e "\033[0;31mFAIL\033[0m"

        echo -n "[*] CMA Reservation: "
        CMA=$(grep CmaTotal /proc/meminfo | awk '{print $2}')
        [ "$CMA" -gt 1900000 ] && echo -e "\033[0;32mPASS\033[0m (~2GB)" || echo -e "\033[0;31mFAIL\033[0m ($CMA KB)"

        echo -n "[*] Governor: "
        GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
        [ "$GOV" == "performance" ] && echo -e "\033[0;32mPASS\033[0m" || echo -e "\033[0;31mFAIL\033[0m ($GOV)"
EOF
else
    echo -e "${RED}[OFFLINE]${NC} Cannot reach Jetson at $JETSON_IP to verify tuning."
fi
