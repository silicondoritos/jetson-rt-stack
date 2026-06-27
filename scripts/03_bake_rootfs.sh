#!/bin/bash
set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/config.sh"
. "$HERE/lib/log.sh"
. "$HERE/lib/plugin.sh"

echo "==========================================="
echo " AV Kernel Phase 3: Payload Baking"
echo "==========================================="

ROOTFS="$L4T_DIR/rootfs"
L4T="$L4T_DIR"
TARGET_HOME="$ROOTFS/home/${TARGET_USER:-j}"
SCRIPTS="$REPO_ROOT/scripts"

echo "[*] Creating target home directory..."
sudo mkdir -p "$TARGET_HOME"
sudo chown 1000:1000 "$TARGET_HOME" || true

# =============================================================================
# Linux headers .deb   required for on-target DKMS rebuilds
# The ZED SDK installer and Voyager install.sh both build kernel modules via
# DKMS and look for headers under /usr/src/linux-headers-$(uname -r)/.
# We ship a .deb that extracts to exactly that path, dpkg-installed at
# first-boot before any third-party installer runs.
# =============================================================================
echo "[*] Baking linux-headers .deb (vermagic-aligned)..."
sudo mkdir -p "$ROOTFS/opt/kernel-headers"
if [ -d "$HEADERS_STAGING" ] && ls "$HEADERS_STAGING"/linux-headers-*.deb >/dev/null 2>&1; then
    sudo cp "$HEADERS_STAGING"/linux-headers-*.deb "$ROOTFS/opt/kernel-headers/"
    echo "   -> $(ls "$HEADERS_STAGING" | head -1) baked into /opt/kernel-headers/"
else
    echo "   [WARN] No headers .deb found at $HEADERS_STAGING   DKMS modules"
    echo "          (ZED SDK, Voyager driver) will fail to build on target."
    echo "          Re-run 'make build' to produce the .deb."
fi

# =============================================================================
# Plugin hooks   vendor tree staging (ZED X ISP + SDK, Axelera Voyager + udev)
# Each plugin checks its own CONFIG_ guards internally.
# =============================================================================
load_plugins
run_hook pre_bake

# =============================================================================
# Per-device personalization + CLI tools
# =============================================================================
echo "[*] Baking personalize_first_boot.sh..."
sudo cp "$SCRIPTS/personalize_first_boot.sh" "$TARGET_HOME/personalize_first_boot.sh"
sudo chmod +x "$TARGET_HOME/personalize_first_boot.sh"

echo "[*] Baking jetson-av-version CLI..."
sudo install -m 0755 "$SCRIPTS/jetson-av-version" "$ROOTFS/usr/local/bin/jetson-av-version"

# =============================================================================
# Build manifest   on-device provenance (/etc/jetson-av-build.json)
# =============================================================================
echo "[*] Baking BUILD_MANIFEST.json → /etc/jetson-av-build.json..."
if [ -f "$L4T/BUILD_MANIFEST.json" ]; then
    sudo install -m 0644 "$L4T/BUILD_MANIFEST.json" "$ROOTFS/etc/jetson-av-build.json"
    echo "   -> $(jq -r .kernel_release < "$L4T/BUILD_MANIFEST.json" 2>/dev/null \
              || grep -oE '"kernel_release": *"[^"]*"' "$L4T/BUILD_MANIFEST.json")"
else
    echo "   [WARN] BUILD_MANIFEST.json missing   re-run 'make build'."
fi

# =============================================================================
# First-boot and per-boot scripts
# =============================================================================
echo "[*] Baking first-boot and RT tuning scripts..."
for f in jetson_first_boot.sh jetson_rt_tune.sh fix_snapd_jetson.sh; do
    sudo cp "$SCRIPTS/$f" "$TARGET_HOME/$f"
    sudo chmod +x "$TARGET_HOME/$f"
done

# =============================================================================
# Boot resilience: cap NVIDIA/jetson oneshot services + pre-seed ssh host keys
# =============================================================================
# (a) The L4T boot path runs several Type=oneshot services with NO start
# timeout (oneshot default is infinity), and nvfb.service is ordered
# Before=ssh.service: one wedged probe inside any of them means "no sshd
# forever" while the kernel pings. Cap them so a wedge degrades into a logged
# failure instead of an unreachable device. jetson-first-boot gets a much
# larger cap: when online it legitimately spends minutes installing wheels.
echo "[*] Hardening boot: TimeoutStartSec drop-ins for oneshot boot services..."
for u in nv nvpower nvpmodel nvfb nvfb-early nvfb-udev jetson-rt-tune; do
    sudo mkdir -p "$ROOTFS/etc/systemd/system/${u}.service.d"
    printf '[Service]\nTimeoutStartSec=120\n' \
        | sudo tee "$ROOTFS/etc/systemd/system/${u}.service.d/10-timeout.conf" >/dev/null
done
sudo mkdir -p "$ROOTFS/etc/systemd/system/jetson-first-boot.service.d"
printf '[Service]\nTimeoutStartSec=1800\n' \
    | sudo tee "$ROOTFS/etc/systemd/system/jetson-first-boot.service.d/10-timeout.conf" >/dev/null
# ZRAM is deliberately not built into this kernel (RT memory determinism);
# nvzramconfig.service would fail every boot, so mask it.
sudo ln -sf /dev/null "$ROOTFS/etc/systemd/system/nvzramconfig.service"
# packagekitd races jetson-first-boot for the apt lock (killed provisioning on
# a live boot); an AV appliance does not need the desktop package daemon.
sudo ln -sf /dev/null "$ROOTFS/etc/systemd/system/packagekit.service"

# (b) Pre-seed ssh host keys at bake time. Without them sshd cannot start
# until first-boot generates keys; combined with any boot wedge that means no
# ssh access at all. Dev-fleet tradeoff: images from one bake share host keys;
# regenerate on provisioned devices if that matters for your deployment.
if ! ls "$ROOTFS/etc/ssh/"ssh_host_*_key >/dev/null 2>&1; then
    echo "[*] Pre-seeding ssh host keys into the rootfs..."
    sudo ssh-keygen -A -f "$ROOTFS" >/dev/null
    sudo ls "$ROOTFS/etc/ssh/" | grep -c "ssh_host_.*_key$" \
        | xargs -I{} echo "   -> {} host keys present"
fi

# =============================================================================
# System.map into /boot   on-device depmod -F and debugging need it; the
# flash-time depmod uses the host copy, this one serves the running device.
# =============================================================================
if [ -f "$KERNEL_SRC/System.map" ]; then
    sudo cp "$KERNEL_SRC/System.map" "$ROOTFS/boot/System.map"
    KREL_FOR_MAP="$(cat "$KERNEL_SRC/include/config/kernel.release" 2>/dev/null || echo 5.15.148-tegra)"
    sudo cp "$KERNEL_SRC/System.map" "$ROOTFS/boot/System.map-${KREL_FOR_MAP}"
    echo "[*] System.map staged into /boot"
fi

# =============================================================================
# USB-link internet (host shares its connection over the flashing cable).
# The route is GUARDED: it is applied only when the USB host gateway answers,
# so it can never hijack the default route once a real network exists.
# =============================================================================
echo "[*] Baking usb-inet.service (guarded host-shared internet)..."
sudo tee "$ROOTFS/etc/systemd/system/usb-inet.service" >/dev/null <<'UNIT'
[Unit]
Description=Default route + DNS via USB host link (only when the host answers)
After=nv-l4t-usb-device-mode.service network.target
Wants=network.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'if ping -c1 -W1 192.168.55.100 >/dev/null 2>&1 && ! ip route | grep -q "^default via 192.168."; then ip route replace default via 192.168.55.100; printf "nameserver 8.8.8.8\nnameserver 1.1.1.1\n" > /etc/resolv.conf; fi'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
sudo mkdir -p "$ROOTFS/etc/systemd/system/multi-user.target.wants"
sudo ln -sf /etc/systemd/system/usb-inet.service     "$ROOTFS/etc/systemd/system/multi-user.target.wants/usb-inet.service"

# =============================================================================
# Offline AV wheelhouse   torch + Voyager SDK + deps, so first-boot provisions
# with NO network. Populated on the host with scripts in voyager-sdk/wheels
# (pip download for aarch64/cp310; see docs/AV_STACK.md). Optional: absent
# wheelhouse means first-boot falls back to the online indexes.
# =============================================================================
if ls "$REPO_ROOT/voyager-sdk/wheels/"*.whl >/dev/null 2>&1; then
    echo "[*] Baking offline AV wheelhouse -> /opt/av-wheels..."
    sudo mkdir -p "$ROOTFS/opt/av-wheels"
    sudo cp "$REPO_ROOT/voyager-sdk/wheels/"*.whl "$ROOTFS/opt/av-wheels/"
    echo "   -> $(ls "$REPO_ROOT/voyager-sdk/wheels/"*.whl | wc -l) wheels baked"
else
    echo "   [INFO] no wheelhouse at voyager-sdk/wheels/   first-boot will use online indexes"
fi

# =============================================================================
# Phase 7: Platform resilience scripts
# =============================================================================
echo "[*] Baking Phase 7 (Platform Hardening) scripts..."
sudo install -m 0755 "$SCRIPTS/axrun" "$ROOTFS/usr/local/bin/axrun"
sudo mkdir -p "$TARGET_HOME/phase7"
for f in install_uav_phase7.sh install_uav_resilience.sh \
         install_blackbox.sh jetson_blackbox.sh \
         axelera_brownout_guard.sh mavlink_watchdog.sh \
         jetson_pcie_aer_monitor.sh \
         install_data_partition.sh install_telemetry_failover.sh; do
    if [ -f "$SCRIPTS/$f" ]; then
        sudo cp "$SCRIPTS/$f" "$TARGET_HOME/phase7/$f"
        sudo chmod +x "$TARGET_HOME/phase7/$f"
        echo "   -> phase7/$f"
    fi
done
sudo mkdir -p "$TARGET_HOME/phase7/lib"
sudo cp "$SCRIPTS"/lib/*.sh "$TARGET_HOME/phase7/lib/"

# =============================================================================
# Phase 5: AV application stack scripts
# =============================================================================
echo "[*] Baking Phase 5 (AV stack: OpenCV-CUDA + ROS 2 + Isaac + Nav2 + MAVROS)..."
sudo mkdir -p "$TARGET_HOME/phase5"
for f in install_av_phase5.sh build_opencv_cuda.sh verify_opengl_cuda.sh \
         install_av_stack.sh launch_av_mission.sh; do
    if [ -f "$SCRIPTS/$f" ]; then
        sudo cp "$SCRIPTS/$f" "$TARGET_HOME/phase5/$f"
        sudo chmod +x "$TARGET_HOME/phase5/$f"
        echo "   -> phase5/$f"
    fi
done
sudo mkdir -p "$TARGET_HOME/phase5/lib"
sudo cp "$SCRIPTS"/lib/*.sh "$TARGET_HOME/phase5/lib/"

# =============================================================================
# Verification gauntlet
# =============================================================================
echo "[*] Baking verification gauntlet..."
sudo cp "$SCRIPTS/verify_tuning.sh" "$TARGET_HOME/verify_tuning.sh"
sudo chmod +x "$TARGET_HOME/verify_tuning.sh"

# =============================================================================
# Systemd services
# =============================================================================
echo "[*] Installing systemd services..."
sudo cp "$SCRIPTS/jetson-first-boot.service" "$ROOTFS/etc/systemd/system/"
sudo cp "$SCRIPTS/jetson-rt-tune.service"    "$ROOTFS/etc/systemd/system/"
sudo chmod 644 "$ROOTFS/etc/systemd/system/jetson-first-boot.service"
sudo chmod 644 "$ROOTFS/etc/systemd/system/jetson-rt-tune.service"
sudo mkdir -p "$ROOTFS/etc/systemd/system/multi-user.target.wants/"
sudo ln -sf /etc/systemd/system/jetson-first-boot.service \
    "$ROOTFS/etc/systemd/system/multi-user.target.wants/jetson-first-boot.service"
sudo ln -sf /etc/systemd/system/jetson-rt-tune.service \
    "$ROOTFS/etc/systemd/system/multi-user.target.wants/jetson-rt-tune.service"

# =============================================================================
# Clock-floor guard   battery-less carrier protection
# The p3768 carrier has NO RTC battery, so a full power-off resets the clock to
# 1970. A 1970 clock breaks the Axelera Voyager runtime's Metis bring-up (the NPU
# never gets MSI interrupts; dmesg spams `axl ... IRQ MSI timeout`). This floors
# the clock to a known-good time EARLY at boot (sysinit, before axsystemserver)
# and re-saves it every 15 min. chrony still corrects to real time when online.
# See docs/TROUBLESHOOTING.md H-13 and docs/OPERATIONS.md.
# =============================================================================
echo "[*] Baking clock-floor guard (Metis 1970-clock protection)..."
sudo install -D -m 0755 "$SCRIPTS/jetson_clock_floor.sh" "$ROOTFS/usr/local/sbin/jetson_clock_floor.sh"
sudo cp "$SCRIPTS/jetson-clock-floor.service"      "$ROOTFS/etc/systemd/system/jetson-clock-floor.service"
sudo cp "$SCRIPTS/jetson-clock-floor-save.service" "$ROOTFS/etc/systemd/system/jetson-clock-floor-save.service"
sudo cp "$SCRIPTS/jetson-clock-floor-save.timer"   "$ROOTFS/etc/systemd/system/jetson-clock-floor-save.timer"
sudo chmod 644 "$ROOTFS/etc/systemd/system/jetson-clock-floor.service" \
               "$ROOTFS/etc/systemd/system/jetson-clock-floor-save.service" \
               "$ROOTFS/etc/systemd/system/jetson-clock-floor-save.timer"
sudo mkdir -p "$ROOTFS/etc/systemd/system/sysinit.target.wants" \
              "$ROOTFS/etc/systemd/system/timers.target.wants" "$ROOTFS/var/lib"
sudo ln -sf /etc/systemd/system/jetson-clock-floor.service \
    "$ROOTFS/etc/systemd/system/sysinit.target.wants/jetson-clock-floor.service"
sudo ln -sf /etc/systemd/system/jetson-clock-floor-save.timer \
    "$ROOTFS/etc/systemd/system/timers.target.wants/jetson-clock-floor-save.timer"
# Seed the floor with the build time so even the very first boot is never 1970.
date +%s | sudo tee "$ROOTFS/var/lib/clock-floor.epoch" >/dev/null
echo "   -> clock-floor guard staged (seed $(date -u +%Y-%m-%dT%H:%M:%SZ))"

# =============================================================================
# WiFi: Intel AX210 (iwlwifi) + legacy RTL8822CE (rtw88) driver load policy
# =============================================================================
echo "[*] Baking WiFi driver config + auto-connect profile..."
# NEVER force-load the wifi driver from modules-load.d: systemd-modules-load
# runs at sysinit, and with the Key-E slot powered (vpcie3v3-supply DT change) a
# hung vendor-driver probe there blocks sysinit.target, so sshd/getty/GUI never
# start while the kernel still answers ping. That force-load was the cause of
# the "boots to USB gadget but never reaches sshd" failure (TROUBLESHOOTING
# F-7/F-10). rtw88 (in-kernel) is blacklisted: it does not bring this card's
# link up. The vendor rtl8822ce is blacklisted from modalias AUTOload until it
# is proven to probe cleanly on the target; load it deliberately over SSH with
# `sudo modprobe rtl8822ce` (an explicit modprobe by name ignores blacklists).
# Once verified, set WIFI_AUTOLOAD=1 at bake time to enable boot-time autoload.
sudo install -d -m 0755 "$ROOTFS/etc/modprobe.d" "$ROOTFS/etc/modules-load.d"
sudo rm -f "$ROOTFS/etc/modules-load.d/rtl8822ce.conf"
if [ "${WIFI_AUTOLOAD:-0}" = "1" ]; then
    printf 'blacklist rtw88_8822ce\nblacklist rtw88_pci\nblacklist rtw88_core\n' \
        | sudo tee "$ROOTFS/etc/modprobe.d/blacklist-rtw88.conf" >/dev/null
else
    printf 'blacklist rtw88_8822ce\nblacklist rtw88_pci\nblacklist rtw88_core\nblacklist rtl8822ce\n' \
        | sudo tee "$ROOTFS/etc/modprobe.d/blacklist-rtw88.conf" >/dev/null
fi

# Auto-connect WiFi profile. Opt-in: set SEED_WIFI_SSID (and SEED_WIFI_PSK)
# at bake time to stage a NetworkManager profile. No credentials are baked by
# default; without SEED_WIFI_SSID the image ships with no pre-seeded network.
WIFI_SSID="${SEED_WIFI_SSID:-}"
WIFI_PSK="${SEED_WIFI_PSK:-}"
if [ -n "$WIFI_SSID" ]; then
    sudo install -d -m 0700 "$ROOTFS/etc/NetworkManager/system-connections"
    sudo tee "$ROOTFS/etc/NetworkManager/system-connections/${WIFI_SSID}.nmconnection" >/dev/null <<NMCONN
[connection]
id=${WIFI_SSID}
type=wifi
autoconnect=true
autoconnect-priority=10
[wifi]
mode=infrastructure
ssid=${WIFI_SSID}
[wifi-security]
key-mgmt=wpa-psk
psk=${WIFI_PSK}
[ipv4]
method=auto
[ipv6]
method=auto
NMCONN
    sudo chmod 600 "$ROOTFS/etc/NetworkManager/system-connections/${WIFI_SSID}.nmconnection"
    log_info "Staged WiFi auto-connect profile for SSID '${WIFI_SSID}'."
else
    log_info "No SEED_WIFI_SSID set; skipping WiFi profile staging (none baked)."
fi
echo "   -> WiFi auto-connect profile staged: ${WIFI_SSID}"

# Intel AX210 firmware (iwlwifi-ty-a0-gf-a0-*.ucode + .pnvm). The sample rootfs'
# linux-firmware normally already ships it; verify, and stage from a vendored
# firmware/iwlwifi/ dir if present. iwlwifi is left to modalias-autoload (an
# in-tree, well-behaved driver, unlike the RTL vendor blob behind F-10).
if ls "$ROOTFS"/lib/firmware/iwlwifi-ty-a0-gf-a0-*.ucode >/dev/null 2>&1; then
    echo "   -> AX210 iwlwifi firmware present in rootfs"
elif [ -d "$REPO_ROOT/firmware/iwlwifi" ]; then
    sudo cp "$REPO_ROOT/firmware/iwlwifi/"iwlwifi-ty-* "$ROOTFS/lib/firmware/" 2>/dev/null \
        && echo "   -> staged AX210 firmware from firmware/iwlwifi/"
else
    echo "   [WARN] AX210 iwlwifi-ty firmware not in rootfs; install linux-firmware on"
    echo "          target or vendor it under firmware/iwlwifi/ (Wi-Fi will not come up)."
fi

# =============================================================================
# USB-C device-mode keepawake   stops the tegra-xudc PORTSC=0xffffffff IRQ storm
# on USB-C connect (see docs/TROUBLESHOOTING.md F-13): keeps the device-mode
# controller powered so its IRQ handler never reads a gated register. Does NOT
# affect recovery-mode (bootROM) flashing.
# =============================================================================
echo "[*] Baking USB-C keepawake udev rule..."
sudo install -d -m 0755 "$ROOTFS/etc/udev/rules.d"
sudo cp "$SCRIPTS/99-tegra-xudc-keepawake.rules" "$ROOTFS/etc/udev/rules.d/99-tegra-xudc-keepawake.rules"
sudo chmod 644 "$ROOTFS/etc/udev/rules.d/99-tegra-xudc-keepawake.rules"

# =============================================================================
# On-device operator guide   ships as ~/README.md (frontmatter-stripped mirror
# of docs/OPERATIONS.md) so the field operator has the cheat-sheet on the box.
# =============================================================================
if [ -f "$REPO_ROOT/docs/OPERATIONS.md" ]; then
    echo "[*] Baking on-device operator README (~/README.md)..."
    awk 'NR==1&&/^---$/{fm=1;next} fm&&/^---$/{fm=0;next} !fm' \
        "$REPO_ROOT/docs/OPERATIONS.md" | sudo tee "$TARGET_HOME/README.md" >/dev/null
    sudo chown 1000:1000 "$TARGET_HOME/README.md" || true
fi

# =============================================================================
# Bootloader: RT boot parameters (config-driven)
# =============================================================================
echo "[*] Injecting RT boot parameters..."
EXTLINUX="$EXTLINUX_CONF"   # bootloader template; apply_binaries copies it to rootfs at flash
if [ -f "$EXTLINUX" ]; then
    # CRITICAL: explicit root= device. A custom extlinux that relies only on
    # ${cbootargs} inherits the board's eMMC default (root=/dev/mmcblk0p1), which
    # does NOT exist on an Orin NX booting from NVMe -- the kernel then boots fine
    # and `rootwait` hangs FOREVER waiting for a disk that never appears (looks like
    # "frozen right after the NVIDIA logo"). A stock NVMe flash writes root= here
    # explicitly; we must too. The last root= on the cmdline wins, so appending it
    # after ${cbootargs} overrides the wrong default. See docs/TROUBLESHOOTING.md
    # "F-4 root=/dev/mmcblk0p1" and docs/FLASH.md. The recovery boot.img path is
    # fixed in parallel by 01_extract_and_patch.sh (CMDLINE_ADD in p3767.conf.common).
    ROOT_DEV="${TARGET_STORAGE_DEV:-nvme0n1p1}"
    BOOT_ARGS="root=/dev/${ROOT_DEV} rootwait rootfstype=ext4 pcie_aspm=off"
    if [ "${CONFIG_LOW_JITTER:-y}" = "y" ] && [ "${CONFIG_KERNEL_PREEMPT_RT:-y}" = "y" ]; then
        CORES="${CONFIG_ISOLATED_CORE_RANGE:-1-5}"
        BOOT_ARGS="${BOOT_ARGS} nohz_full=${CORES} isolcpus=${CORES} rcu_nocbs=${CORES} irqaffinity=0"
    fi
    # Deliberately NO cma= boot arg. cma=2048M cannot be placed on Orin NX
    # (the kernel logs "cma: Failed to reserve 2048 MiB"), and a cmdline cma=
    # also BYPASSES the device tree's linux,cma pool -- net result is ZERO CMA.
    # With no CMA, nvgpu's 64MB contiguous comptag allocation fails at poweron
    # and the whole GR falcon / FECS / CUDA / devfreq / nvpmodel chain
    # collapses ("Unable to recover GR falcon"). Omitting cma= lets the DT
    # linux,cma pool (256MB, NVIDIA-sized, proven on stock) take over: GPU
    # init clean, CUDA live, MAXN_SUPER applies. Verified on device 2026-06-10.
    # The stale-arg cleanup below strips any old cma= on re-bakes.

    # Remove stale args (idempotent re-bake)
    sudo sed -i 's| root=/dev/[^ ]*||g; s/ rootwait//g; s/ rootfstype=[^ ]*//g' "$EXTLINUX"
    sudo sed -i 's/ nohz_full=[^ ]*//g; s/ isolcpus=[^ ]*//g; s/ rcu_nocbs=[^ ]*//g' "$EXTLINUX"
    sudo sed -i 's/ irqaffinity=[^ ]*//g; s///g; s/ pcie_aspm=off//g' "$EXTLINUX"
    sudo sed -i 's/ cma=[^ ]*//g' "$EXTLINUX"

    # Inject fresh args on active APPEND line
    sudo sed -i "s|^\([[:space:]]*\)APPEND \${cbootargs}|\1APPEND \${cbootargs} ${BOOT_ARGS}|g" "$EXTLINUX"
    echo "   -> boot args: ${BOOT_ARGS}"
else
    echo "   [WARN] extlinux.conf not found in rootfs."
fi

# =============================================================================
# Generate /etc/jetson-av/power.conf from build config
# Baked at image build time so jetson_rt_tune.sh finds it at runtime.
# =============================================================================
echo "[*] Generating /etc/jetson-av/power.conf..."
sudo mkdir -p "$ROOTFS/etc/jetson-av"
# Mode IDs are from the SUPER nvpmodel conf, which 04_flash_nvme.sh installs
# as the default table (verified live on device): 0=MAXN_SUPER 1=10W 2=15W
# 3=25W 4=40W. The old mapping assumed the standard conf and set 4, which on
# the super table is the fixed 40W profile -- it silently downgraded the
# requested MAXN_SUPER on every boot.
if [ "${CONFIG_NVPMODEL_MAXN_SUPER:-y}" = "y" ]; then
    NVPMODEL_MODE_VAL=0
elif [ "${CONFIG_NVPMODEL_MAXN:-n}" = "y" ]; then
    NVPMODEL_MODE_VAL=3
elif [ "${CONFIG_NVPMODEL_15W:-n}" = "y" ]; then
    NVPMODEL_MODE_VAL=2
elif [ "${CONFIG_NVPMODEL_10W:-n}" = "y" ]; then
    NVPMODEL_MODE_VAL=1
else
    NVPMODEL_MODE_VAL=0
fi
printf 'NVPMODEL_MODE=%s\n' "$NVPMODEL_MODE_VAL" | sudo tee "$ROOTFS/etc/jetson-av/power.conf" > /dev/null
printf 'METIS_POWER_CAP_W=%s\n' "${CONFIG_METIS_POWER_CAP_W:-18}" | sudo tee -a "$ROOTFS/etc/jetson-av/power.conf" > /dev/null
echo "   -> NVPMODEL_MODE=$NVPMODEL_MODE_VAL METIS_POWER_CAP_W=${CONFIG_METIS_POWER_CAP_W:-18}"

# =============================================================================
# Plugin hooks   post-bake (ZED X DTBO injection into extlinux.conf)
# =============================================================================
run_hook post_bake

echo ""
echo "==========================================="
echo " Phase 3 Complete. Payload Baked into RootFS."
echo "==========================================="
echo ""
echo " Next (Jetson in Recovery Mode): make flash"
