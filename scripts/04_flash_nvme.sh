#!/bin/bash
set -e

# Source versions.env to pick up TARGET_BOARD / TARGET_STORAGE_DEV. Defaults
# below match the original hardcoded values, so the script behaves the same
# if config.sh / versions.env are missing.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/config.sh" 2>/dev/null || true

# Fall back to original literals if versions.env didn't define these.
# NEVER default to *-super (Orin NANO power table; misconfigures the NX HV rail).
TARGET_BOARD="${TARGET_BOARD:-jetson-orin-nano-devkit}"
TARGET_STORAGE_DEV="${TARGET_STORAGE_DEV:-nvme0n1p1}"
TARGET_FLASH_XML="${TARGET_FLASH_XML:-tools/kernel_flash/flash_l4t_t234_nvme.xml}"
TARGET_QSPI_XML="${TARGET_QSPI_XML:-bootloader/generic/cfg/flash_t234_qspi.xml}"

echo "==========================================="
echo " AV Kernel Phase 4: NVMe Flashing"
echo "==========================================="
echo " Board     : $TARGET_BOARD"
echo " Storage   : $TARGET_STORAGE_DEV"
echo " Flash XML : $TARGET_FLASH_XML"
echo " QSPI  XML : $TARGET_QSPI_XML"
echo "==========================================="

cd "$L4T_DIR"

echo "[*] Fusing NVIDIA binaries into rootfs..."
sudo ./tools/l4t_flash_prerequisites.sh

# ---------------------------------------------------------------------------
# CRITICAL: apply_binaries.sh installs the STOCK nvidia-l4t-kernel packages
# (Image + base/OOT/display modules, vermagic "...preempt") which CLOBBER our
# custom PREEMPT_RT kernel. We must run it (it stages NVIDIA userspace/firmware
# the rootfs needs) but then restore OUR kernel + modules on top, or the device
# boots a stock kernel and none of our RT modules load (vermagic mismatch).
# See docs/TROUBLESHOOTING.md "apply_binaries clobbers the custom kernel".
# ---------------------------------------------------------------------------
if [ "${STOCK_BASELINE:-0}" = "1" ]; then
    # -----------------------------------------------------------------------
    # DIAGNOSTIC: flash the STOCK NVIDIA kernel (leave apply_binaries' kernel in
    # place, skip the RT restore). Used to isolate a boot hang: is it our custom
    # PREEMPT_RT kernel, or something below it (DTB / hardware / NVMe)? If this
    # boots and comes up on 192.168.55.1, the board + SSD + our flash process are
    # proven good and the fault is the RT kernel. No serial console is needed:
    # USB-gadget enumeration on the host is the "it booted" signal.
    # -----------------------------------------------------------------------
    echo "[*] STOCK_BASELINE=1 -> flashing STOCK kernel (no RT restore, diagnostic)."
    sudo ./apply_binaries.sh
    # The flasher boots kernel/Image + l4t_initrd.img as its RAM flash environment.
    # kernel/Image is still our RT build, but apply_binaries just rebuilt
    # l4t_initrd.img with STOCK 'preempt' modules -> vermagic mismatch -> the flash
    # initrd's USB/RNDIS modules won't load -> "Device failed to boot to the initrd
    # flash kernel". Point the flash kernel at the stock Image apply_binaries
    # installed so the flash environment is internally consistent (stock + stock).
    sudo cp "$ROOTFS/boot/Image" "$L4T_DIR/kernel/Image"
else
    KREL="$(cat "$KERNEL_SRC/include/config/kernel.release" 2>/dev/null || echo 5.15.148-tegra)"
    _KBK="$(mktemp -d)"
    echo "[*] Preserving custom RT kernel ($KREL) across apply_binaries..."
    sudo cp -a "$ROOTFS/lib/modules/$KREL" "$_KBK/modules"
    sudo cp -a "$ROOTFS/boot/Image" "$_KBK/Image"
    # Preserve the ZED X camera overlay (.dtbo) if the camera profile is enabled.
    if [ "${CONFIG_CAMERA_ZEDX_MONO:-n}" = "y" ] && [ -f "$ROOTFS/boot/$ZED_DTBO_NAME" ]; then
        sudo cp -a "$ROOTFS/boot/$ZED_DTBO_NAME" "$_KBK/$ZED_DTBO_NAME"
    fi

    sudo ./apply_binaries.sh

    echo "[*] Restoring custom RT kernel over apply_binaries' stock kernel..."
    sudo rm -rf "$ROOTFS/lib/modules/$KREL"
    sudo cp -a "$_KBK/modules" "$ROOTFS/lib/modules/$KREL"
    sudo cp -a "$_KBK/Image" "$ROOTFS/boot/Image"
    [ -f "$_KBK/$ZED_DTBO_NAME" ] && sudo cp -a "$_KBK/$ZED_DTBO_NAME" "$ROOTFS/boot/$ZED_DTBO_NAME"
    # Regenerate modules.dep WITH the kernel's System.map (-F). A cross-build depmod
    # without it can mis-resolve OOT GPU/display module symbol versions under
    # PREEMPT_RT, which breaks nvgpu / nvidia-drm bring-up at boot (black screen,
    # no desktop, no CUDA   the documented "no display with PREEMPT_RT" failure).
    # The System.map from the matching RT kernel build is the source of truth.
    _SYSMAP="$KERNEL_SRC/System.map"
    [ -f "$_SYSMAP" ] || _SYSMAP="$ROOTFS/boot/System.map"
    if [ -f "$_SYSMAP" ]; then
        echo "[*] depmod with System.map ($_SYSMAP)"
        sudo depmod -b "$ROOTFS" -F "$_SYSMAP" "$KREL"
    else
        echo "[!] WARN: System.map not found   depmod without symbol versions"
        sudo depmod -b "$ROOTFS" "$KREL"
    fi
    sudo rm -rf "$_KBK"

    # -----------------------------------------------------------------------
    # If NVMe/PCIe/PHY (or any early-boot driver) were built INTO the kernel (=y),
    # their .ko no longer exists, but nv-update-initrd's module list still names
    # them and ERRORS OUT ("nvme.ko not found"), leaving the stock initrd in place.
    # Strip the now-built-in modules from the list so the regen succeeds; a built-in
    # driver doesn't belong in the initrd anyway. See docs/TROUBLESHOOTING.md F-6.
    # -----------------------------------------------------------------------
    _MODLIST="$ROOTFS/etc/nv-update-initrd/list.d/modules"
    if [ -f "$_MODLIST" ]; then
        for _m in nvme nvme-core pcie-tegra194 phy-tegra194-p2u; do
            if ! sudo find "$ROOTFS/lib/modules/$KREL" -name "${_m}.ko" 2>/dev/null | grep -q .; then
                echo "[*] initrd list: dropping now-built-in module '${_m}'"
                sudo sed -i "\\|/${_m}\\.ko:|d" "$_MODLIST"
            fi
        done
    fi

    # -----------------------------------------------------------------------
    # apply_binaries.sh rebuilt the initrd while STOCK modules were in place, so
    # its early-boot modules carry stock "preempt" vermagic. On our preempt_rt
    # kernel those refuse to load. Regenerate the initrd with the RT modules
    # (built-in NVMe/PCIe means the root device is found without an initrd module).
    # -----------------------------------------------------------------------
    echo "[*] Regenerating initrd with RT modules..."
    sudo ./tools/l4t_update_initrd.sh || echo "[!] WARN: initrd regen failed   NVMe root may not mount"

    # Gate: the device must be able to reach its NVMe root. Two valid cases:
    #   (a) NVMe is a MODULE  -> the initrd's nvme.ko must be preempt_rt; or
    #   (b) NVMe is BUILT-IN (=y) -> no nvme.ko in the initrd is expected/needed.
    # (b) is our config since we moved NVMe/PCIe/PHY to =y to drop the initrd
    # module-load step from the root-mount path. See docs/TROUBLESHOOTING.md F-6.
    _NVME_BUILTIN="$(grep -c '^CONFIG_BLK_DEV_NVME=y' "$KERNEL_SRC/.config" 2>/dev/null || echo 0)"
    _INITRD_NVME_VM="$(
      _t="$(mktemp -d)"
      ( zcat "$ROOTFS/boot/initrd" 2>/dev/null || cat "$ROOTFS/boot/initrd" ) \
          | ( cd "$_t" && cpio -idm 2>/dev/null )
      _k="$(find "$_t" -name 'nvme.ko*' | head -1)"
      [ -n "$_k" ] && strings "$_k" | grep -m1 '^vermagic=' | grep -o 'preempt_rt\|preempt'
      rm -rf "$_t"
    )"
    if [ "$_NVME_BUILTIN" -ge 1 ] && [ -z "$_INITRD_NVME_VM" ]; then
        echo "[*] initrd: NVMe is built into the kernel (=y); no nvme.ko needed in initrd."
    elif [ "$_INITRD_NVME_VM" = "preempt_rt" ]; then
        echo "[*] initrd verified: NVMe module is preempt_rt."
    else
        echo "[FATAL] NVMe is not built-in and initrd nvme.ko vermagic is" >&2
        echo "        '${_INITRD_NVME_VM:-absent}', not preempt_rt. Device would hang (no NVMe root). Aborting." >&2
        exit 1
    fi

    # Fail loudly if the restore did not produce an RT-consistent module tree.
    if ! ROOTFS="$ROOTFS" L4T="$L4T_DIR" bash "$HERE/verify_vermagic.sh" --rootfs >/dev/null 2>&1; then
        echo "[FATAL] rootfs vermagic gate failed after apply_binaries restore. Aborting flash." >&2
        exit 1
    fi
    echo "[*] Custom RT kernel restored and vermagic-verified."
fi

# ---------------------------------------------------------------------------
# Power: enable Orin NX Super mode (MAXN_SUPER, ~40W+) by DEFAULT. apply_binaries
# installs both the standard nvpmodel conf (max 25W) and the *_super conf, but the
# board boots the standard one (15W default). Overwrite the active conf with the
# super conf and default it to MAXN_SUPER so the device comes up at full power on
# first boot, no reboot dance. Override mode with POWER_MODE_DEFAULT (0=MAXN_SUPER,
# 4=40W). See docs/TROUBLESHOOTING.md F-7.
# ---------------------------------------------------------------------------
_NVPM_STD="$ROOTFS/etc/nvpmodel/nvpmodel_p3767_0000.conf"
_NVPM_SUPER="$ROOTFS/etc/nvpmodel/nvpmodel_p3767_0000_super.conf"
if [ -f "$_NVPM_SUPER" ]; then
    echo "[*] Enabling Orin NX Super power mode (MAXN_SUPER) by default..."
    sudo cp "$_NVPM_STD" "${_NVPM_STD}.stock.bak" 2>/dev/null || true
    sudo cp "$_NVPM_SUPER" "$_NVPM_STD"
    sudo sed -i "s/^< PM_CONFIG DEFAULT=[0-9]* >/< PM_CONFIG DEFAULT=${POWER_MODE_DEFAULT:-0} >/g" "$_NVPM_STD"
    echo "   -> $(grep -m1 '^< PM_CONFIG DEFAULT' "$_NVPM_STD" 2>/dev/null)"
else
    echo "[!] WARN: super nvpmodel conf not found   device will cap at 25W"
fi

# ---------------------------------------------------------------------------
# Pre-seed the default user so first boot SKIPS the oem-config wizard and
# comes up with GUI autologin + SSH. This is NOT optional in practice:
# apply_binaries re-creates /etc/systemd/system/default.target ->
# nv-oem-config.target on EVERY flash, and the seed (which removes that
# symlink, l4t_create_default_user.sh) is the only thing that undoes it. A
# flash without the seed boots into the oem-config flow, which waits before
# sshd with the USB gadget up and pinging -- indistinguishable from a hang
# (this bit us: TROUBLESHOOTING F-7). Defaults:
#   SEED_USER (default: j) / SEED_PASS (default: jetson)
#   SEED_HOSTNAME           (default: jetson-av)
#   SEED_AUTOLOGIN=1        (default: on)
# To get the interactive wizard on purpose, set SEED_USER="" explicitly.
# ---------------------------------------------------------------------------
SEED_USER="${SEED_USER-j}"
SEED_PASS="${SEED_PASS-jetson}"
if [ -n "${SEED_USER}" ] && [ -n "${SEED_PASS}" ]; then
    echo "[*] Pre-seeding user '$SEED_USER' (skips oem-config, enables headless SSH)..."
    _AL=""; [ "${SEED_AUTOLOGIN:-1}" = "1" ] && _AL="-a"
    # shellcheck disable=SC2086
    sudo ./tools/l4t_create_default_user.sh \
        -u "$SEED_USER" -p "$SEED_PASS" $_AL \
        -n "${SEED_HOSTNAME:-jetson-av}" --accept-license \
        || echo "[!] WARN: user pre-seed failed; first boot will run the setup wizard"
    # Hard gate: a seeded flash must NOT boot into the oem-config flow.
    if [ -e "$ROOTFS/etc/systemd/system/default.target" ] && \
       readlink "$ROOTFS/etc/systemd/system/default.target" | grep -q "nv-oem-config"; then
        echo "[FATAL] default.target still points at nv-oem-config.target after seeding."
        echo "        This image would boot into the setup wizard (no sshd). Aborting."
        exit 1
    fi
fi

echo "--------------------------------------------------------"
echo " WARNING: The Jetson must be connected via USB and in "
echo " Force Recovery Mode (short REC and GND pins)."
echo " This operation will ERASE the NVMe SSD."
echo "--------------------------------------------------------"

# Auto-detect APX (USB ID 0955:7323)   poll for 60s. Falls back to interactive
# prompt if not found. Set APX_TIMEOUT=0 to skip auto-detect entirely.
APX_TIMEOUT="${APX_TIMEOUT:-60}"
if [ "$APX_TIMEOUT" -gt 0 ]; then
    echo "[*] Polling for APX device (USB ID 0955:7323) for ${APX_TIMEOUT}s..."
    i=0
    while [ "$i" -lt "$APX_TIMEOUT" ]; do
        if lsusb 2>/dev/null | grep -q "0955:7323"; then
            echo "[*] APX detected   proceeding."
            break
        fi
        sleep 1; i=$((i+1))
        printf '.'
    done
    echo
    if ! lsusb 2>/dev/null | grep -q "0955:7323"; then
        echo "[!] APX not detected after ${APX_TIMEOUT}s."
        read -p "    Press ENTER to continue anyway, or Ctrl+C to abort... "
    fi
else
    read -p "Press ENTER to continue when Jetson is in Recovery Mode, or Ctrl+C to abort... "
fi

# The NVIDIA RNDIS flash gadget can appear as eth0 or usb0 depending on
# host udev config. Force it to usb0 so the flash tool finds it.
if [ ! -f /etc/udev/rules.d/72-nvidia-rndis.rules ]; then
    echo "[*] Installing udev rule to name NVIDIA RNDIS gadget as usb0..."
    sudo tee /etc/udev/rules.d/72-nvidia-rndis.rules > /dev/null <<'UDEV'
# NVIDIA Tegra initrd flash RNDIS gadget → always usb0
SUBSYSTEM=="net", ACTION=="add", ATTRS{idVendor}=="0955", ATTRS{idProduct}=="7035", NAME="usb0"
UDEV
    sudo udevadm control --reload-rules
fi

# Validate the chosen board exists in this L4T tree before invoking the flash.
# The flasher's error if the board name is wrong is buried 200 lines into the
# log and looks like a generic NVIDIA failure, which has cost real teams
# real time. Catch it here.
if [ -d "$L4T_DIR" ]; then
    cd "$L4T_DIR"
    if ! ls "${TARGET_BOARD}.conf" >/dev/null 2>&1 \
       && ! ls "p3768"*"${TARGET_BOARD}"*.conf >/dev/null 2>&1 \
       && ! ls "${TARGET_BOARD}"*.conf >/dev/null 2>&1; then
        echo "[!] WARNING: no board config matches '$TARGET_BOARD' in $(pwd)"
        echo "    Available board configs:"
        ls -1 *.conf 2>/dev/null | grep -E '^p3768|^jetson-' | sed 's/^/      /' | head -20
        echo "    Set TARGET_BOARD in versions.env to one of the above."
        read -p "Press ENTER to attempt the flash anyway, or Ctrl+C to abort... "
    fi
fi

echo "[*] Initiating Flash Sequence..."
sudo ./tools/kernel_flash/l4t_initrd_flash.sh \
    --external-device "$TARGET_STORAGE_DEV" \
    -c "$TARGET_FLASH_XML" \
    -p "-c $TARGET_QSPI_XML" \
    --showlogs --network usb0 \
    "$TARGET_BOARD" internal

echo "==========================================="
echo " Phase 4 Complete. Flash Successful."
echo "==========================================="
