#!/bin/bash
# =============================================================================
#  IGNITE_JETSON_AV.SH - The "0 to Hero" Orchestrator
# =============================================================================
#  Purpose: Deterministic execution of the entire Jetson AV pipeline.
#  Stages: Extraction -> Patching -> Compilation (Docker) -> Baking -> Flash.
#  Mandate: Silicon Dominance for Autonomous Vehicle Operations.
# =============================================================================

set -e

# --- Configuration & Paths ---
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$PROJECT_DIR/IGNITION_$(date +%Y%m%d_%H%M%S).log"
BSP_ARCHIVE="Jetson_Linux_r36.4.3_aarch64.tbz2"
ROOTFS_ARCHIVE="Tegra_Linux_Sample-Root-Filesystem_r36.4.3_aarch64.tbz2"
SOURCE_ARCHIVE="public_sources.tbz2"

# --- God-Mind Banner ---
cat << "EOF"
  _________________________________________________________________
 /                                                                 \
|   IGNITE JETSON AV: AXELERA METIS + STEREOLABS ZED X ORCHESTRATOR  |
|   Version: 1.0.0 (God-Mind Edition)                                |
 \_________________________________________________________________/
EOF

echo "[*] Mission Log: $LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

# --- 1. Tactical Reconnaissance (Prerequisites) ---
echo -e "\n[*] PHASE 0: Tactical Reconnaissance..."

check_file() {
    if [ ! -f "$PROJECT_DIR/$1" ]; then
        echo -e "\n[!] CRITICAL ERROR: Missing archive: $1"
        echo "    Download from NVIDIA (R36.4.3) and place in $PROJECT_DIR"
        exit 1
    fi
}

check_file "$BSP_ARCHIVE"
check_file "$ROOTFS_ARCHIVE"
check_file "$SOURCE_ARCHIVE"

# --- 2. Host Hardening (Check Dependencies) ---
echo "[*] Verifying Host Environment..."

# Verify Docker
if ! command -v docker &> /dev/null; then
    echo "[!] ERROR: Docker not found. Install it first: sudo apt install -y docker.io"
    exit 1
fi

# Verify NFS (soft check)
if ! systemctl is-active --quiet nfs-kernel-server; then
    echo "[WARN] NFS server is not active. Flashing might fail."
fi

# We assume sudo is handled by the environment or the user is running the script with sudo
# We avoid 'sudo -v' to prevent hanging on a password prompt in non-interactive shells.

# --- 3. Phase 1: Extraction & Surgery (Host) ---
echo -e "\n[*] PHASE 1: Extraction & Source Surgery..."
./scripts/01_extract_and_patch.sh

# Special Manual Step for RootFS (must be sudo)
L4T_ROOTFS="$PROJECT_DIR/latest_jetson/Linux_for_Tegra/rootfs"
if [ ! -d "$L4T_ROOTFS/usr" ]; then
    echo "[*] Unpacking RootFS (requires sudo)..."
    sudo tar xpf "$PROJECT_DIR/$ROOTFS_ARCHIVE" -C "$L4T_ROOTFS"
fi

# Apply Binaries
echo "[*] Fusing NVIDIA Silicon DNA into RootFS..."
cd "$PROJECT_DIR/latest_jetson/Linux_for_Tegra"
sudo ./apply_binaries.sh
cd "$PROJECT_DIR"

# --- 4. Phase 2: The Forge (Docker Compilation) ---
echo -e "\n[*] PHASE 2: Igniting The Forge (Compilation)..."

# Build the container if it doesn't exist
if [[ "$(docker images -q jetson-av-builder:latest 2> /dev/null)" == "" ]]; then
    echo "[*] Building Docker Forge Image..."
    docker build -t jetson-av-builder .
fi

# Run the build inside the forge
echo "[*] Executing Kernel Surgery inside Docker..."
docker run --rm \
    -v "$PROJECT_DIR":/home/j/dev/custom_kernel \
    -w /home/j/dev/custom_kernel \
    --user $(id -u):$(id -g) \
    --env HOME=/home/j \
    jetson-av-builder bash ./scripts/02_build_kernel.sh

# --- 5. Phase 3: Payload Baking (Host) ---
echo -e "\n[*] PHASE 3: Baking Payload into RootFS..."
./scripts/03_bake_rootfs.sh

# --- 6. Phase 4: Final Ignition (Flash) ---
echo -e "\n[*] PHASE 4: Final Ignition (Physical Flash)..."

# Recovery Mode Check Loop
echo -e "\n[!] ACTION REQUIRED: Put Jetson in FORCE RECOVERY MODE."
echo "    1. Connect USB-C to the REAR Motherboard port."
echo "    2. Short REC and GND pins."
echo "    3. Power on."
echo "    Checking for device ID 0955:7323 (APX)..."

until lsusb | grep -q "0955:7323"; do
    echo -n "."
    sleep 2
done

echo -e "\n[OK] Jetson Detected in Recovery Mode."

if [[ "$1" != "--yes" ]]; then
    read -p ">>> Ready to erase NVMe and Flash? [y/N]: " confirm
    if [[ $confirm != [yY] ]]; then
        echo "[!] Aborted by user."
        exit 0
    fi
fi

# Final Flashing
./scripts/04_flash_nvme.sh

echo -e "\n================================================================="
echo "  MISSION ACCOMPLISHED: GOLDEN IMAGE DEPLOYED"
echo "================================================================="
echo "  1. Unplug REC/GND short."
echo "  2. Power cycle the Jetson."
echo "  3. Wait for first-boot automation to complete."
echo "  4. REBOOT the Jetson to activate RT/CMA/SUPER-MODE."
echo "================================================================="
