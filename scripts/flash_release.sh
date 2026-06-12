#!/bin/bash
# =============================================================================
# scripts/flash_release.sh   flash a Jetson from an extracted release tarball
# =============================================================================
# This script is meant to live INSIDE a release tarball (release-vX.Y.Z/).
# It does not need the source repo or Docker   only sudo + USB + the staged
# Linux_for_Tegra/ tree.
#
# Usage (single device):
#   tar xzf release-v1.0.0.tar.gz && cd release-v1.0.0
#   ./scripts/flash_release.sh
#
# Optional env:
#   DEVICE=av-07           label this device for the fleet log
#   STRICT=0                continue past failures (default 1)
#   DEBUG=1                 verbose output
#
# All steps pre/post-verified, logged to logs/, recorded to STEP_MANIFEST.tsv.
# =============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Inside a release tarball the layout is one level above HERE; outside (when
# run from the source repo) lib/ is at HERE/lib.
if [ -d "$HERE/lib" ]; then
    LIB="$HERE/lib"
else
    LIB="$HERE/../scripts/lib"
fi
. "$LIB/config.sh"
. "$LIB/log.sh"
. "$LIB/verify.sh"
. "$LIB/checks.sh"

# Override BUILD_WORKSPACE for the release layout (the tarball uses
# release-vX.Y.Z/Linux_for_Tegra/ instead of latest_jetson/Linux_for_Tegra/).
if [ -d "$HERE/../Linux_for_Tegra" ]; then
    L4T_DIR="$(cd "$HERE/../Linux_for_Tegra" && pwd)"
    ROOTFS="$L4T_DIR/rootfs"
    KERNEL_OUT="$L4T_DIR/kernel"
    KERNEL_IMAGE="$KERNEL_OUT/Image"
    EXTLINUX_CONF="$ROOTFS/boot/extlinux/extlinux.conf"
fi

PHASE=flash
DEVICE="${DEVICE:-unnamed}"
log::section "Flash Release   device label: $DEVICE"

# --- Step 1: integrity of the release ---------------------------------------
pre_release()  { check::dir_exists "$L4T_DIR"; }
exec_release() {
    check::file_exists "$L4T_DIR/BUILD_MANIFEST.json" || return 1
    check::file_exists "$KERNEL_IMAGE" || return 1
    check::dir_exists  "$ROOTFS"       || return 1
    log::ok "Release tree intact"
    log::info "Build manifest:"
    cat "$L4T_DIR/BUILD_MANIFEST.json"
}
post_release() { return 0; }
step::run "Validate release tree" pre_release exec_release post_release

# --- Step 2: detect Jetson recovery mode ------------------------------------
pre_recovery()  { check::command_exists lsusb; }
exec_recovery() {
    log::info "Looking for Jetson APX (USB ID $USB_ID_APX)   auto-detect for 60s."
    local i=0
    while [ "$i" -lt 60 ]; do
        if lsusb 2>/dev/null | grep -q "$USB_ID_APX"; then
            log::ok "Detected APX"
            return 0
        fi
        sleep 1; i=$((i+1))
    done
    log::warn "Auto-detect timed out   prompting operator"
    log::info "Put Jetson in FORCE RECOVERY MODE (short REC+GND, plug USB-C, hold 2s)"
    read -r -p "Press ENTER once you see APX in 'lsusb', or Ctrl+C to abort... " _
    lsusb | grep -q "$USB_ID_APX"
}
post_recovery() { check::usb_device_visible "$USB_ID_APX"; }
step::run "Detect recovery mode" pre_recovery exec_recovery post_recovery

# --- Step 3: USB autosuspend OFF, large usbfs buffer ------------------------
pre_usb()  { check::file_exists /sys/module/usbcore/parameters/autosuspend; }
exec_usb() {
    sudo sh -c 'echo -1  > /sys/module/usbcore/parameters/autosuspend'
    sudo sh -c 'echo 200 > /sys/module/usbcore/parameters/usbfs_memory_mb' || true
}
post_usb() {
    [ "$(cat /sys/module/usbcore/parameters/autosuspend)" = "-1" ]
}
step::run "USB autosuspend OFF" pre_usb exec_usb post_usb

# --- Step 4: NVIDIA RNDIS udev rule -----------------------------------------
pre_rndis()  { check::dir_exists /etc/udev/rules.d; }
exec_rndis() {
    if [ ! -f /etc/udev/rules.d/72-nvidia-rndis.rules ]; then
        sudo tee /etc/udev/rules.d/72-nvidia-rndis.rules >/dev/null <<UDEV
SUBSYSTEM=="net", ACTION=="add", ATTRS{idVendor}=="0955", ATTRS{idProduct}=="7035", NAME="usb0"
UDEV
        sudo udevadm control --reload-rules
    fi
}
post_rndis() { check::file_exists /etc/udev/rules.d/72-nvidia-rndis.rules; }
step::run "NVIDIA RNDIS udev rule" pre_rndis exec_rndis post_rndis

# --- Step 5: l4t_flash_prerequisites.sh -------------------------------------
pre_prereq()  { check::executable "$L4T_DIR/tools/l4t_flash_prerequisites.sh"; }
exec_prereq() { ( cd "$L4T_DIR" && sudo ./tools/l4t_flash_prerequisites.sh ); }
post_prereq() { check::dir_exists "$L4T_DIR/bootloader"; }
step::run "l4t_flash_prerequisites.sh" pre_prereq exec_prereq post_prereq

# --- Step 6: apply_binaries.sh ---------------------------------------------
pre_apply()  { check::executable "$L4T_DIR/apply_binaries.sh"; }
exec_apply() { ( cd "$L4T_DIR" && sudo ./apply_binaries.sh ); }
post_apply() { check::dir_nonempty "$ROOTFS/usr/lib"; }
step::run "apply_binaries.sh" pre_apply exec_apply post_apply

# --- Step 7: l4t_initrd_flash.sh   the actual write ------------------------
pre_flash()  { check::executable "$L4T_DIR/tools/kernel_flash/l4t_initrd_flash.sh"; }
exec_flash() {
    cd "$L4T_DIR"
    sudo ./tools/kernel_flash/l4t_initrd_flash.sh \
        --external-device "$TARGET_STORAGE_DEV" \
        -c tools/kernel_flash/flash_l4t_t234_nvme.xml \
        -p "-c bootloader/generic/cfg/flash_t234_qspi.xml" \
        --showlogs --network usb0 \
        "$TARGET_BOARD" internal
}
post_flash() {
    # After a successful flash, the Jetson reboots into the new image and
    # ENDS the recovery-mode RNDIS gadget. Detect the absence of APX as a
    # cheap "flash done & device reset" signal.
    log::info "Waiting for APX device to disappear (proxy for flash done)..."
    local i=0
    while [ "$i" -lt 30 ]; do
        if ! lsusb | grep -q "$USB_ID_APX"; then
            log::ok "APX gone   device rebooting into new image"
            return 0
        fi
        sleep 1; i=$((i+1))
    done
    log::warn "APX still present   flash may not have completed; check logs"
    return 1
}
step::run "l4t_initrd_flash.sh   write NVMe" pre_flash exec_flash post_flash

# --- Step 8: append fleet log ----------------------------------------------
pre_log()  { return 0; }
exec_log() {
    local fleet_log="$REPO_ROOT/fleet_log.csv"
    if [ ! -f "$fleet_log" ]; then
        printf 'timestamp,operator,device_label,build_sha256,result\n' > "$fleet_log"
    fi
    local sha; sha="$(sha256sum "$KERNEL_IMAGE" 2>/dev/null | awk '{print $1}')"
    printf '%s,%s,%s,%s,%s\n' \
        "$(date -u -Iseconds)" "$(id -un)" "$DEVICE" "$sha" "FLASHED" \
        >> "$fleet_log"
    log::ok "Recorded to $fleet_log"
}
post_log() { check::file_exists "$REPO_ROOT/fleet_log.csv"; }
step::run "Append to fleet_log.csv" pre_log exec_log post_log

# --- Final summary ---------------------------------------------------------
log::section "Flash done for $DEVICE"
log::info "Wait ~90 s for first-boot service to complete and reboot, then run:"
log::info "  ./scripts/05_post_flash_validate.sh"
echo
step::summary
