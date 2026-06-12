#!/bin/bash
# One-time post-flash initialization.
# Runs via jetson-first-boot.service on first boot only.
# Guarded by ConditionPathExists=!/home/j/.jetson_initialized
set -e

echo "==========================================="
echo " Jetson Orin NX: First-Boot Initialization"
echo "   Layer 1 (baseline): kernel lock, Voyager SDK, RT boot args"
echo "   Layer 2 (optional): ZED SDK, Phase 7 hardening, Phase 5 AV stack"
echo "==========================================="

if [ "$EUID" -ne 0 ]; then
    echo "[!] Must run as root. Use: sudo $0"
    exit 1
fi

# --- Per-device personalization (FIRST   before any service starts) ---
# Gives this device a unique hostname + SSH host keys + optional static IP
# from /etc/jetson-av-fleet/device.conf (or MAC-derived if no config).
# Without this, every flashed Jetson is identical → SSH host-key collisions
# the moment two are on the same network.
if [ -x /home/j/personalize_first_boot.sh ]; then
    echo "[*] Running personalize_first_boot.sh..."
    /home/j/personalize_first_boot.sh
fi

# --- Kernel APT Hold (must be first   prevent OTA wipe) ---
echo "[*] Locking kernel packages against OTA updates..."
apt-mark hold \
    nvidia-l4t-kernel \
    nvidia-l4t-kernel-dtbs \
    nvidia-l4t-kernel-headers \
    nvidia-l4t-bootloader \
    nvidia-l4t-init \
    nvidia-l4t-xusb-firmware
echo "   -> Kernel locked. Verify: apt-mark showhold"

# --- Belt-and-suspenders: APT pin to forbid these packages outright ---
# `apt-mark hold` is a soft block   anyone who runs `apt install <pkg>=<ver>`
# can override it. A Pin-Priority: -1 in /etc/apt/preferences.d/ rejects the
# package entirely; even explicit version requests fail.
cat > /etc/apt/preferences.d/99-jetson-av-kernel-lock <<'EOF'
# Jetson AV firmware: forbid stock NVIDIA kernel packages.
# These would overwrite the custom -tegra kernel and break vermagic.
Package: nvidia-l4t-kernel nvidia-l4t-kernel-dtbs nvidia-l4t-kernel-headers
Pin: release *
Pin-Priority: -1

Package: nvidia-l4t-bootloader nvidia-l4t-init nvidia-l4t-xusb-firmware
Pin: release *
Pin-Priority: -1
EOF
chmod 644 /etc/apt/preferences.d/99-jetson-av-kernel-lock
echo "   -> apt preferences hardened (Pin-Priority: -1)."

# --- Install our linux-headers-*.deb (vermagic-aligned for DKMS) ---
# This must run BEFORE any third-party installer (ZED SDK, Voyager driver)
# tries to compile kernel modules. The .deb extracts to
# /usr/src/linux-headers-$(uname -r)/ which is where DKMS looks by default.
echo "[*] Installing vermagic-aligned linux-headers .deb..."
HEADERS_DEB=$(ls /opt/kernel-headers/linux-headers-*.deb 2>/dev/null | head -1)
if [ -n "$HEADERS_DEB" ]; then
    # --force-overwrite: nvidia-l4t-kernel-headers also owns
    # /lib/modules/<rel>/build; without the force this dpkg fails and leaves a
    # dangling build symlink (DKMS broken). We then repoint the symlink.
    if dpkg -i --force-overwrite "$HEADERS_DEB"; then
        ln -sfn "/usr/src/linux-headers-$(uname -r)" "/lib/modules/$(uname -r)/build"
        echo "   -> Headers installed: $(basename $HEADERS_DEB)"
        echo "   -> /usr/src/linux-headers-$(uname -r)/ now available to DKMS."
    else
        echo "   [WARN] dpkg -i failed for $HEADERS_DEB   DKMS rebuilds will fail"
    fi
else
    echo "   [WARN] No linux-headers .deb found in /opt/kernel-headers/"
    echo "          DKMS-based installers (ZED SDK, Voyager) will fail."
fi

# --- OpenCV header symlink (Voyager SDK requirement) ---
echo "[*] Fixing OpenCV headers for Voyager SDK..."
if [ ! -d "/usr/include/opencv2" ]; then
    ln -s /usr/include/opencv4/opencv2 /usr/include/opencv2
    echo "   -> Symlink created: /usr/include/opencv2"
else
    echo "   -> Already exists."
fi

# --- Voyager SDK 1.6 (pip wheels   NOT install.sh) ---
echo "[*] Installing baseline packages and Voyager SDK..."
# packagekitd (the desktop updater) races this script for the apt lock and
# killed provisioning on a live boot. Stop it for the run and give every
# apt/dpkg call a lock timeout instead of failing instantly.
systemctl stop packagekit 2>/dev/null || true
APT="apt-get -o DPkg::Lock::Timeout=600"
$APT update
$APT install -y python3-pip python3-venv rt-tests pciutils curl

# Axelera device access: the shipped 72-axelera.rules references this group.
groupadd -f axelera
usermod -aG axelera j 2>/dev/null || true

# --- snapd fix (Chromium/Chrome and other snaps on Jetson) ---
# Repairs the snap stack (AppArmor service, snapd socket+seeding, /snap
# symlink) and verifies the kernel has the AppArmor LSM active. Non-fatal:
# degrades loudly on kernels without AppArmor. See scripts/fix_snapd_jetson.sh.
if [ -x /home/j/fix_snapd_jetson.sh ]; then
    echo "[*] Running snapd/AppArmor fix..."
    /home/j/fix_snapd_jetson.sh || echo "[WARN] snapd fix reported issues (see log above)"
fi

# Create the AV Python environment
python3 -m venv /opt/av-env
source /opt/av-env/bin/activate

pip install --upgrade pip

# OFFLINE-FIRST: the bake stages a complete aarch64 wheelhouse (torch, voyager
# SDK, numpy/scipy/pillow and all deps) at /opt/av-wheels so a device with NO
# network provisions fully from the bundle. Online indexes are the fallback,
# not the default. (The bundled ZED SDK .run at /opt/zed-sdk is the same idea.)
WHEELHOUSE=/opt/av-wheels
OFFLINE_OK=0
if ls "$WHEELHOUSE"/*.whl >/dev/null 2>&1; then
    echo "[*] Installing AV python stack from bundled wheelhouse (offline)..."
    if pip install --no-index --find-links "$WHEELHOUSE" \
            "numpy<2.0.0" scipy pillow torch torchvision axelera-rt axelera-devkit; then
        OFFLINE_OK=1
        echo "   -> full stack installed offline from /opt/av-wheels"
    else
        echo "   [WARN] wheelhouse install incomplete; falling back to online indexes"
    fi
fi
if [ "$OFFLINE_OK" != "1" ]; then
    # Core AV stack   numpy must be <2.0.0 (Voyager hard requirement)
    pip install "numpy<2.0.0" scipy pillow

    # PyTorch for Jetson: Jetson-specific wheel ONLY, never from generic PyPI.
    # Jetson AI Lab index (pypi.jetson-ai-lab.io). The old .dev host is dead at
    # the DNS level (verified 2026-06-10) so there is no fallback host anymore.
    # The index prunes old wheels (2026-06-10: oldest served is 2.8.0).
    # torchvision and numpy must be constrained here, not left to the resolver:
    # an unpinned torchvision resolves to 0.26.0 and drags in numpy 2.x, which
    # breaks the Voyager pins (axelera-* require numpy<2 and torchvision<0.26;
    # observed live 2026-06-10 during venv repair).
    pip install torch==2.8.0 torchvision==0.23.0 "numpy<2.0.0" \
        --index-url https://pypi.jetson-ai-lab.io/jp6/cu126

    # Voyager SDK 1.6   verified canonical pip extra-index URL (the
    # /api/pypi/.../simple suffix is required for pip's index API).
    # torch==2.8.0 is re-stated as a constraint: without it pip's resolver
    # "upgrades" the cu126 Jetson wheel to PyPI's CPU-only torch (observed
    # live 2026-06-10: 2.8.0 → 2.10.0+cpu, torch.cuda.is_available() False).
    pip install axelera-rt axelera-devkit torch==2.8.0 \
        --extra-index-url https://software.axelera.ai/artifactory/api/pypi/axelera-pypi/simple
fi

# ZED Python bindings (requires ZED SDK to be installed first)
# pip install pyzed   # uncomment after ZED SDK install

# AXELERA_GST_EXPLICIT_PARSE was exported here historically, but FIELD_CONFIRM
# 3.3 (2026-06-11) found zero references to it in the Voyager 1.6.1 source or
# wheels   it is stale and was removed. The decode workaround Jetson actually
# needs is GST_PLUGIN_FEATURE_RANK=nvv4l2decoder:NONE (docs/AV_STACK.md).

deactivate
echo "   -> AV Python environment: /opt/av-env"
echo "   -> Activate with: source /opt/av-env/bin/activate"

# --- extlinux.conf RT boot args ---
# Fallback only (the bake injects these already). Deliberately NO cma= (a
# cmdline cma= bypasses the DT linux,cma pool and 2G fails to reserve: kills
# the GPU, TROUBLESHOOTING F-8) and NO efi=noruntime (blocks EFI variables,
# so boot-success is never acknowledged to the firmware and every power-on
# reboots once mid-sequence).
echo "[*] Injecting RT boot parameters into extlinux.conf..."
EXTLINUX="/boot/extlinux/extlinux.conf"
if ! grep -q "nohz_full" "$EXTLINUX"; then
    sed -i 's/APPEND ${cbootargs} /APPEND ${cbootargs} nohz_full=1-5 isolcpus=1-5 rcu_nocbs=1-5 irqaffinity=0 pcie_aspm=off /g' "$EXTLINUX"
    echo "   -> Boot args injected. Reboot required to activate."
else
    echo "   -> Boot args already present."
fi
# Defuse legacy args if an older bake/first-boot left them behind.
sed -i 's/ efi=noruntime//g; s/ cma=2G//g; s/ cma=2048M//g' "$EXTLINUX"

# --- Panic/watchdog hardening ---
echo "[*] Configuring kernel panic and watchdog..."
sysctl -w kernel.panic=5
sysctl -w kernel.panic_on_oops=1
grep -q "kernel.panic" /etc/sysctl.conf || cat >> /etc/sysctl.conf << 'EOF'
kernel.panic=5
kernel.panic_on_oops=1
EOF

# --- Network buffer tuning (useful for any high-throughput workload; required for ROS 2 DDS) ---
echo "[*] Tuning network socket buffers..."
grep -q "net.core.rmem_max" /etc/sysctl.conf || cat >> /etc/sysctl.conf << 'EOF'
net.core.rmem_max=2147483647
net.core.wmem_max=2147483647
net.core.rmem_default=67108864
net.core.wmem_default=67108864
net.ipv4.udp_mem=67108864 134217728 268435456
EOF
sysctl -p

# --- Memory tuning ---
echo "[*] Configuring memory settings..."
swapoff -a 2>/dev/null || true
sed -i '/swap/s/^/#/' /etc/fstab
grep -q "vm.swappiness" /etc/sysctl.conf || cat >> /etc/sysctl.conf << 'EOF'
vm.dirty_ratio=10
vm.dirty_background_ratio=5
vm.swappiness=0
vm.nr_hugepages=512
EOF
sysctl -p

# --- Pstore mount for black-box crash logging ---
echo "[*] Mounting pstore for crash logging..."
mkdir -p /sys/fs/pstore
mount -t pstore pstore /sys/fs/pstore 2>/dev/null || true
grep -q "pstore" /etc/fstab || echo "pstore /sys/fs/pstore pstore defaults 0 0" >> /etc/fstab

# --- ZED SDK userspace install (skip_drivers   we own sl_zedx.ko) ---
# Runs only if a ZED_SDK_Tegra_*.run file was baked into /opt/zed-sdk by
# Phase 3. Idempotent   re-running is safe but a no-op after the first
# successful install.
if [ -x /opt/zed-sdk/install_zed_sdk.sh ]; then
    echo "[*] Running ZED SDK installer..."
    /opt/zed-sdk/install_zed_sdk.sh || \
        echo "   [WARN] ZED SDK install reported issues   see output above."
fi

# --- ZED X SPSC/IMU modules + vendor daemons (staged by the zedx plugin) ---
# Without these the SDK cannot open a ZED X ("CAMERA MOTION SENSORS NOT
# DETECTED") and the image stays soft (stock libnvisppg). Builds the daemons
# on-device unless prebuilt binaries were staged at /opt/zedx-daemons/cache.
if [ -x /opt/zedx-daemons/install_zedx_daemons.sh ]; then
    echo "[*] Installing ZED X SPSC modules + daemons..."
    /opt/zedx-daemons/install_zedx_daemons.sh || \
        echo "   [WARN] ZED X daemon install reported issues   re-run: sudo /opt/zedx-daemons/install_zedx_daemons.sh"
fi

# =============================================================================
# LAYER 2   RT VISION EXTENSION (optional, independent of each other)
# The baseline image is complete without the steps below. Install these
# only if you have the corresponding hardware (ZED X).
# Scripts are only present if staged by make bake with the vision profile.
# =============================================================================

# --- Phase 7: Production Hardening (optional) ---
# General hardening (watchdog, journald, chrony, SSH, UFW, NVMe SMART) plus
# vision-stack-specific components (brownout guard, black-box, PCIe AER monitor).
# Only runs if install_uav_phase7.sh was staged at bake time.
if [ -x /home/j/phase7/install_uav_phase7.sh ]; then
    echo "[*] Running Phase 7 (resilience) installer..."
    echo "[*] General hardening: watchdog, journald, chrony, SSH, UFW, NVMe SMART"
    echo "[*] Vision-stack:      brownout guard, black-box, PCIe AER monitor"
    /home/j/phase7/install_uav_phase7.sh || \
        echo "   [WARN] Phase 7 install reported issues   see step manifest in /var/log/jetson-av/"
else
    echo "[*] Phase 7 not staged   skipping platform hardening (baseline image is complete)."
fi

# --- Phase 5: AV application stack (optional) ---
# OpenCV-CUDA (~45 min, cached as .deb after first build) + ROS 2 Humble +
# Isaac ROS + Nav2. Requires ZED X for full use.
# Set SKIP_PHASE5=1 to suppress even if the script is present.
if [ -x /home/j/phase5/install_av_phase5.sh ] && [ "${SKIP_PHASE5:-0}" != "1" ]; then
    echo "[*] Running Phase 5 (AV stack   ROS 2 + Isaac ROS + cuVSLAM + nvblox + Nav2)..."
    echo "[*] Requires: ZED X driver. LONG step (~60-90 min)."
    echo "[*] Skip with: SKIP_PHASE5=1 (re-run first-boot or install manually later)."
    /home/j/phase5/install_av_phase5.sh || \
        echo "   [WARN] Phase 5 install reported issues   see step manifest in /var/log/jetson-av/"
else
    echo "[*] Phase 5 not staged or SKIP_PHASE5=1   skipping AV stack (baseline image is complete)."
fi

# --- Completion marker (prevents re-run on next boot) ---
echo "[*] Marking first-boot initialization complete..."
touch /home/j/.jetson_initialized

echo ""
echo "==========================================="
echo " First-Boot Init Complete."
echo " >>> REBOOT THE JETSON NOW <<<"
echo " RT boot args + CMA reservation activate on next boot."
echo "==========================================="
