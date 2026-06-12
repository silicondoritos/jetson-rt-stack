#!/bin/bash
# =============================================================================
# plugins/zedx/plugin.sh   Stereolabs ZED X integration hooks
# =============================================================================
# This file contains our integration glue. The actual ZED X kernel driver,
# ISP calibration files, and ZED SDK are NOT included in this repo   they are
# proprietary / NDA-gated. See docs/DRIVERS.md for acquisition instructions.
#
# What this plugin does:
#   doctor          validate the zedx-driver and zed-sdk vendor trees exist
#   post_extract    inject vendor sources into the L4T kernel tree, apply
#                   Stereolabs kernel patches (branch derived from L4T_VERSION),
#                   create in-tree Kconfig/Makefile
#                   shims, fix the deserializer compiler flag
#   post_defconfig   append ZED X CONFIG_* symbols to the kernel defconfig
#   pre_bake        stage ISP calibration files and ZED SDK installer
#   post_bake       copy compiled DTBO into /boot and register in extlinux.conf
# =============================================================================

plugin_name() { echo "zedx"; }

# Stereolabs names its kernel-patch directories by L4T branch (e.g. R36.4 for
# all 36.4.x point releases). Derive the branch from the pinned L4T_VERSION so a
# re-pin needs no edit here; override with ZEDX_PATCH_BRANCH if the vendor tree
# you were granted uses a different directory name.
ZEDX_PATCH_BRANCH="${ZEDX_PATCH_BRANCH:-R$(printf '%s' "${L4T_VERSION:-R36.4.3}" | sed 's/^R//' | cut -d. -f1,2)}"

# ---------------------------------------------------------------------------
# doctor
# ---------------------------------------------------------------------------
zedx_doctor() {
    if [ "${CONFIG_CAMERA_NONE:-n}" = "y" ]; then
        echo "[zedx] CAMERA_NONE   skipping ZED X doctor checks"
        return 0
    fi

    local failed=0

    if [ -d "$ZEDX_DRIVER_DIR" ] && [ -n "$(ls -A "$ZEDX_DRIVER_DIR" 2>/dev/null)" ]; then
        log::pass "zedx-driver (populated)"
        if [ -d "$ZEDX_DRIVER_DIR/nvidia_kernel/kernel_patches/$ZEDX_PATCH_BRANCH" ]; then
            log::pass "  └ $ZEDX_PATCH_BRANCH patches present"
        else
            log::xfail "  └ $ZEDX_PATCH_BRANCH patches" \
                "wrong branch? need nvidia_kernel/kernel_patches/$ZEDX_PATCH_BRANCH/"
            failed=1
        fi
    else
        log::xfail "zedx-driver" \
            "NDA-gated   request access from Stereolabs support, then place at: $ZEDX_DRIVER_DIR"
        log::xfail "  └ info" "see docs/DRIVERS.md §ZED X for acquisition steps"
        failed=1
    fi

    if [ -d "$ZED_SDK_DIR" ] && ls "$ZED_SDK_DIR"/$ZED_SDK_INSTALLER_GLOB >/dev/null 2>&1; then
        log::pass "zed-sdk (installer present)"
    else
        log::warn "zed-sdk: no $ZED_SDK_INSTALLER_GLOB   first-boot will skip ZED SDK install"
        log::warn "  └ download from: https://www.stereolabs.com/developers/release"
        WARN_COUNT=$((WARN_COUNT + 1))
    fi

    return $failed
}

# ---------------------------------------------------------------------------
# post_extract   inject vendor sources, apply patches, create in-tree shims
# ---------------------------------------------------------------------------
zedx_post_extract() {
    if [ "${CONFIG_CAMERA_NONE:-n}" = "y" ]; then
        echo "[zedx] CAMERA_NONE   skipping ZED X extraction"
        return 0
    fi

    local L4T_SRC="$L4T_DIR/source"
    local KERNEL_TREE="$L4T_SRC/kernel/kernel-jammy-src"

    # 1. Inject ZED X driver sources into the L4T source tree
    echo "[zedx] Injecting Stereolabs ZED X driver sources..."
    cp -r "$ZEDX_DRIVER_DIR/src/kernel/stereolabs" "$L4T_SRC/"
    cp -r "$ZEDX_DRIVER_DIR/src/hardware/stereolabs" "$L4T_SRC/hardware/"

    # 2. Apply Stereolabs kernel patches for the pinned L4T branch
    echo "[zedx] Applying Stereolabs $ZEDX_PATCH_BRANCH kernel patches..."
    for patch in "$ZEDX_DRIVER_DIR/nvidia_kernel/kernel_patches/$ZEDX_PATCH_BRANCH/0"*.patch; do
        [ -f "$patch" ] || continue
        if [[ "$patch" != *"zedbox"* ]]; then
            echo "   -> Applying $(basename "$patch")"
            patch -p2 -N -d "$L4T_DIR/source" < "$patch" || true
        fi
    done

    # 2b. Materialize the stereolabs compilation Makefiles. The 0006 patch
    # creates source/stereolabs/Makefile{,-dkms} from /dev/null, but `patch -p2`
    # mangles the /dev/null source to a file literally named "null", and the
    # patch's src/kernel/stereolabs/ layout does not map to our source/stereolabs/
    # copy at any -p level. Extract the new files directly to the correct path.
    local _p6
    _p6="$(ls "$ZEDX_DRIVER_DIR/nvidia_kernel/kernel_patches/$ZEDX_PATCH_BRANCH/"*compilation_makefile*.patch 2>/dev/null | head -1)"
    if [ -n "$_p6" ] && [ -d "$L4T_SRC/stereolabs" ]; then
        echo "[zedx] Materializing source/stereolabs/Makefile{,-dkms} from $(basename "$_p6")"
        awk -v d="$L4T_SRC/stereolabs" '
            /^\+\+\+ b\/src\/kernel\/stereolabs\// { f=$2; sub(/.*stereolabs\//,"",f); o=d"/"f; printf "">o; c=1; next }
            /^(--- |diff )/ { c=0 }
            /^@@/ { next }
            c && /^\+/ { print substr($0,2) >> o }
        ' "$_p6"
    fi
    rm -f "$L4T_SRC/null" "$L4T_SRC/stereolabs/null" 2>/dev/null

    # 3. Copy overlay DTS/DTSI files
    echo "[zedx] Copying Stereolabs overlay DTS..."
    local NV_PUBLIC="$L4T_SRC/hardware/nvidia/t23x/nv-public"
    sudo cp -r "$ZEDX_DRIVER_DIR/src/hardware/stereolabs/overlay/"*.dts  "$NV_PUBLIC/"
    sudo cp -r "$ZEDX_DRIVER_DIR/src/hardware/stereolabs/overlay/"*.dtsi "$NV_PUBLIC/"
    # The overlays #include "Utils/camera-clks.dtsi" and "Utils/<sensor>-sl-modes.dtsi"
    # relative to their own location, so the Utils/ tree must sit beside them in
    # nv-public. cpp resolves these at DTBO compile time; a missing Utils/ makes the
    # overlay build fail with a bare "No such file" 40 lines deep in the preprocessor.
    if [ -d "$ZEDX_DRIVER_DIR/src/hardware/stereolabs/Utils" ]; then
        echo "[zedx] Copying overlay Utils/ includes into nv-public..."
        sudo cp -r "$ZEDX_DRIVER_DIR/src/hardware/stereolabs/Utils" "$NV_PUBLIC/"
    fi
    sudo chown -R "$(id -u):$(id -g)" "$NV_PUBLIC/"

    # 4. Fix dtbo-y double-prefix bug in nv-public Makefile
    # The ZED X patches register overlays with $(makefile-path)/ prefix, but
    # the Makefile's addprefix block adds that prefix itself   strip it here to
    # prevent the double-prefix that causes DTBO builds to silently produce nothing.
    echo "[zedx] Correcting ZED X dtbo-y registration..."
    local NV_PUBLIC_MK="$NV_PUBLIC/Makefile"
    sed -i 's|dtbo-y += \$(makefile-path)/\(.*-sl-overlay\.dtbo\)|dtbo-y += \1|g' "$NV_PUBLIC_MK"

    # 5. Fix deserializer compiler flag based on camera selection
    local DESER_FROM DESER_TO
    if [ "${CONFIG_CAMERA_ZEDX_MONO:-n}" = "y" ]; then
        DESER_FROM="-DCONFIG_SL_DESER_MAX96712"
        DESER_TO="-DCONFIG_SL_DESER_MAX9296"
        echo "[zedx] Hardcoding MAX9296 deserializer (ZED Link Mono)..."
    else
        DESER_FROM="-DCONFIG_SL_DESER_MAX9296"
        DESER_TO="-DCONFIG_SL_DESER_MAX96712"
        echo "[zedx] Setting MAX96712 deserializer (ZED Link Duo)..."
    fi
    sed -i "s|$DESER_FROM|$DESER_TO|g" "$L4T_SRC/stereolabs/drivers/Makefile"

    # 6. Promote ZED X to in-tree build
    _zedx_promote_intree "$KERNEL_TREE"
}

# Internal: create the drivers/media/i2c/zedx/ in-tree shim
_zedx_promote_intree() {
    local KERNEL_TREE="$1"
    local ZEDX_DIR="$KERNEL_TREE/drivers/media/i2c/zedx"

    echo "[zedx] Promoting ZED X to in-tree build (vermagic safety)..."
    sudo mkdir -p "$ZEDX_DIR"
    sudo chown -R "$(id -u):$(id -g)" "$ZEDX_DIR"

    if [ ! -L "$ZEDX_DIR/zedx-src" ]; then
        ln -sfn "../../../../../../stereolabs" "$ZEDX_DIR/zedx-src"
    fi

    # Kconfig stub   defines the ZED X symbols so defconfig can enable them
    cat > "$ZEDX_DIR/Kconfig" <<'KCONFIG'
config VIDEO_ZEDX
    tristate "Stereolabs ZED X stereo camera"
    depends on I2C && VIDEO_DEV && MEDIA_CAMERA_SUPPORT
    select V4L2_FWNODE
    default m
    help
      Stereolabs ZED X driver. Built in-tree so vermagic always matches.

config VIDEO_ZEDX_AR0234
    tristate "ZED X   onsemi AR0234 sensor"
    depends on VIDEO_ZEDX
    default m

config VIDEO_ZEDX_IMX678
    tristate "ZED X   Sony IMX678 sensor"
    depends on VIDEO_ZEDX
    default m

config SL_DESER_MAX9296
    tristate "Stereolabs MAX9296 GMSL2 deserializer (ZED Link Mono)"
    depends on VIDEO_ZEDX
    default m
    help
      Enable for ZED Link Mono. Wrong deserializer = silently corrupted
      stereo depth at 30fps with no error messages.

config SL_DESER_MAX96712
    tristate "Stereolabs MAX96712 GMSL2 deserializer (ZED Link Duo)"
    depends on VIDEO_ZEDX
    default n

config SL_IMU_BMI088
    tristate "Stereolabs BMI088 IMU + SPSC sensor channel"
    depends on VIDEO_ZEDX && I2C
    default m
    help
      BMI088 IMU with the SPSC ring-buffer interface (bmi088.ko +
      bmi_spsc.ko). REQUIRED for ZED SDK >= 5.x camera open: without it
      the SDK fails with "CAMERA MOTION SENSORS NOT DETECTED". See
      docs/TROUBLESHOOTING.md H-6.
KCONFIG

    # Makefile glue
    printf 'obj-$(CONFIG_VIDEO_ZEDX) += zedx-wrapper/\n' > "$ZEDX_DIR/Makefile"

    sudo mkdir -p "$ZEDX_DIR/zedx-wrapper"
    sudo chown -R "$(id -u):$(id -g)" "$ZEDX_DIR/zedx-wrapper"

    cat > "$ZEDX_DIR/zedx-wrapper/Makefile" <<'MAKE'
# In-tree wrapper for the ZED X driver. Same pattern as drivers/misc/axelera/.
# Sub-make drives the vendor OOT Makefile (M-style) rather than including it.
VENDOR_DIR := $(srctree)/drivers/media/i2c/zedx/zedx-src/drivers

ifneq ($(KERNELRELEASE),)
obj-m :=
modules:
	@echo "[zedx] sub-make → $(VENDOR_DIR)"
	$(MAKE) -C $(srctree) M=$(VENDOR_DIR) \
	    LOCALVERSION=$(LOCALVERSION) CROSS_COMPILE=$(CROSS_COMPILE) ARCH=$(ARCH) modules
modules_install:
	$(MAKE) -C $(srctree) M=$(VENDOR_DIR) INSTALL_MOD_PATH=$(INSTALL_MOD_PATH) modules_install
clean:
	$(MAKE) -C $(srctree) M=$(VENDOR_DIR) clean
else
KDIR ?= /lib/modules/$(shell uname -r)/build
all:
	$(MAKE) -C $(KDIR) M=$(VENDOR_DIR) modules
clean:
	$(MAKE) -C $(KDIR) M=$(VENDOR_DIR) clean
endif
.PHONY: modules modules_install clean all
MAKE

    # Wire into drivers/media/i2c/Kconfig + Makefile
    local I2C_KCONFIG="$KERNEL_TREE/drivers/media/i2c/Kconfig"
    local I2C_MAKEFILE="$KERNEL_TREE/drivers/media/i2c/Makefile"

    if [ -f "$I2C_KCONFIG" ] && ! grep -q 'media/i2c/zedx/Kconfig' "$I2C_KCONFIG"; then
        if grep -q '^endif # VIDEO_CAMERA_SENSOR' "$I2C_KCONFIG"; then
            sudo sed -i '/^endif # VIDEO_CAMERA_SENSOR/i source "drivers/media/i2c/zedx/Kconfig"' "$I2C_KCONFIG"
        else
            printf 'source "drivers/media/i2c/zedx/Kconfig"\n' | sudo tee -a "$I2C_KCONFIG" >/dev/null
        fi
    fi

    if [ -f "$I2C_MAKEFILE" ] && ! grep -q 'CONFIG_VIDEO_ZEDX' "$I2C_MAKEFILE"; then
        printf 'obj-$(CONFIG_VIDEO_ZEDX) += zedx/\n' | sudo tee -a "$I2C_MAKEFILE" >/dev/null
    fi

    echo "[zedx] ZED X in-tree promotion complete."
}

# ---------------------------------------------------------------------------
# post_defconfig   append ZED X CONFIG_ symbols to kernel defconfig
# ---------------------------------------------------------------------------
zedx_post_defconfig() {
    if [ "${CONFIG_CAMERA_NONE:-n}" = "y" ]; then
        return 0
    fi

    local DEFCONFIG="$KERNEL_SRC/arch/arm64/configs/defconfig"

    if grep -q "CONFIG_VIDEO_ZEDX" "$DEFCONFIG"; then
        return 0
    fi

    # Deserializer selection
    local MONO_LINE DUO_LINE
    if [ "${CONFIG_CAMERA_ZEDX_MONO:-n}" = "y" ]; then
        MONO_LINE="CONFIG_SL_DESER_MAX9296=m"
        DUO_LINE="# CONFIG_SL_DESER_MAX96712 is not set"
    else
        MONO_LINE="# CONFIG_SL_DESER_MAX9296 is not set"
        DUO_LINE="CONFIG_SL_DESER_MAX96712=m"
    fi

    cat >> "$DEFCONFIG" <<EOF

# ============================================================
# ZED X in-tree driver (injected by zedx plugin)
# ============================================================
CONFIG_VIDEO_ZEDX=m
CONFIG_VIDEO_ZEDX_AR0234=m
CONFIG_VIDEO_ZEDX_IMX678=m
CONFIG_SL_IMU_BMI088=m
${MONO_LINE}
${DUO_LINE}
EOF

    # DMABUF zero-copy pipeline
    if [ "${CONFIG_DMABUF_ZEROCOPY:-y}" = "y" ]; then
        cat >> "$DEFCONFIG" <<'EOF'

# DMABUF Zero-Copy Pipeline (ZED X → ISP → CMA → Metis)
CONFIG_SYNC_FILE=y
CONFIG_SW_SYNC=y
CONFIG_DMABUF_HEAPS=y
CONFIG_DMABUF_SYSFS_STATS=y
CONFIG_DMABUF_HEAPS_SYSTEM=y
CONFIG_DMABUF_HEAPS_CMA=y
EOF
    fi
}

# ---------------------------------------------------------------------------
# pre_bake   stage ISP calibration files and ZED SDK installer
# ---------------------------------------------------------------------------
zedx_pre_bake() {
    if [ "${CONFIG_CAMERA_NONE:-n}" = "y" ]; then
        echo "[zedx] CAMERA_NONE   skipping ZED X bake staging"
        return 0
    fi

    local ROOTFS="$L4T_DIR/rootfs"

    # ISP calibration configs
    echo "[zedx] Staging ZED X ISP calibration configs..."
    sudo mkdir -p "$ROOTFS/var/nvidia/nvcam/settings"
    for isp_file in "$ZEDX_DRIVER_DIR/ISP/"*.isp; do
        [ -f "$isp_file" ] || continue
        sudo cp "$isp_file" "$ROOTFS/var/nvidia/nvcam/settings/"
        sudo chmod 664 "$ROOTFS/var/nvidia/nvcam/settings/$(basename "$isp_file")"
        echo "   -> $(basename "$isp_file")"
    done

    # ZED SDK installer (optional   user may not have it yet)
    if [ "${CONFIG_ZEDX_SDK_AUTO_INSTALL:-y}" = "y" ]; then
        echo "[zedx] Staging ZED SDK installer..."
        sudo mkdir -p "$ROOTFS/opt/zed-sdk"
        if [ -d "$ZED_SDK_DIR" ] && ls "$ZED_SDK_DIR"/$ZED_SDK_INSTALLER_GLOB >/dev/null 2>&1; then
            sudo cp "$ZED_SDK_DIR"/$ZED_SDK_INSTALLER_GLOB "$ROOTFS/opt/zed-sdk/"
            sudo chmod +x "$ROOTFS/opt/zed-sdk/"$ZED_SDK_INSTALLER_GLOB
            echo "   -> ZED SDK .run staged at /opt/zed-sdk/"
        else
            echo "   [INFO] No ZED SDK .run in $ZED_SDK_DIR   first-boot will skip SDK install"
        fi
        sudo cp "$REPO_ROOT/scripts/install_zed_sdk.sh" "$ROOTFS/opt/zed-sdk/install_zed_sdk.sh"
        sudo chmod +x "$ROOTFS/opt/zed-sdk/install_zed_sdk.sh"
    fi

    # --- ZED X SPSC/IMU + vendor daemons (required for SDK camera open) ----
    # ZEDX_Driver (the vendor module loader) insmods from
    # /usr/lib/modules/<rel>/kernel/drivers/stereolabs/   NOT updates/   so
    # mirror every built stereolabs .ko there (verified live 2026-06-11;
    # see docs/DRIVERS.md §1.5 and TROUBLESHOOTING H-6).
    local KREL
    KREL=$(ls "$ROOTFS/lib/modules" 2>/dev/null | head -1)
    local UPDATES="$ROOTFS/lib/modules/$KREL/updates/drivers/stereolabs"
    local LOADER_PATH="$ROOTFS/usr/lib/modules/$KREL/kernel/drivers/stereolabs"
    if [ -n "$KREL" ] && [ -d "$UPDATES" ]; then
        echo "[zedx] Mirroring stereolabs modules to the ZEDX_Driver loader path..."
        sudo mkdir -p "$LOADER_PATH"
        sudo cp -r "$UPDATES/." "$LOADER_PATH/"
        echo "   -> $(find "$LOADER_PATH" -name '*.ko' | wc -l) module(s) at kernel/drivers/stereolabs/"
    else
        echo "   [WARN] no stereolabs modules under updates/   loader path not staged"
    fi

    # Daemon sources + ISP fix + installer, staged for first boot. The
    # daemons are aarch64 userspace built with Qt/cmake on the device
    # (install_zedx_daemons.sh); prebuilt binaries from a previous unit can
    # be cached at $REPO_ROOT/zedx-daemon-cache/ to skip the on-device build.
    echo "[zedx] Staging ZED X daemons + SPSC installer..."
    local ZDS="$ROOTFS/opt/zedx-daemons"
    sudo mkdir -p "$ZDS/vendor"
    sudo cp -r "$ZEDX_DRIVER_DIR/Daemon" "$ZDS/vendor/"
    [ -d "$ZEDX_DRIVER_DIR/nvidia_364_fix" ] && sudo cp -r "$ZEDX_DRIVER_DIR/nvidia_364_fix" "$ZDS/vendor/"
    sudo mkdir -p "$ZDS/vendor/src/kernel/stereolabs/drivers/stereolabs"
    sudo cp -r "$ZEDX_DRIVER_DIR/src/kernel/stereolabs/drivers/stereolabs/bmi088" \
               "$ZDS/vendor/src/kernel/stereolabs/drivers/stereolabs/"
    sudo cp "$REPO_ROOT/scripts/install_zedx_daemons.sh" "$ZDS/"
    sudo chmod +x "$ZDS/install_zedx_daemons.sh"
    if [ -d "$REPO_ROOT/zedx-daemon-cache" ]; then
        sudo mkdir -p "$ZDS/cache"
        sudo cp "$REPO_ROOT/zedx-daemon-cache/"* "$ZDS/cache/" 2>/dev/null && \
            echo "   -> prebuilt daemon binaries staged from zedx-daemon-cache/"
    fi
    printf 'KERNEL=="spsc_bmi*", GROUP="zed", MODE="0660"\n' | \
        sudo tee "$ROOTFS/etc/udev/rules.d/99-zed-spsc.rules" >/dev/null
    echo "   -> daemons vendor tree + udev rule staged at /opt/zedx-daemons/"
}

# ---------------------------------------------------------------------------
# post_bake   stage compiled DTBO and register in extlinux.conf
# ---------------------------------------------------------------------------
zedx_post_bake() {
    if [ "${CONFIG_CAMERA_NONE:-n}" = "y" ]; then
        return 0
    fi

    local ROOTFS="$L4T_DIR/rootfs"
    local ZED_DTBO="${CONFIG_ZEDX_DTBO_NAME:-tegra234-p3768-camera-zedlink-mono-sl-overlay.dtbo}"
    # Inject into the bootloader template (apply_binaries copies it at flash);
    # the rootfs copy does not exist until flash time.
    local EXTLINUX="${EXTLINUX_CONF:-$L4T_DIR/bootloader/extlinux.conf}"

    if [ ! -f "$EXTLINUX" ]; then
        echo "[zedx] WARN: extlinux template not found   cannot inject DTBO overlay"
        return 0
    fi

    if [ -f "$L4T_DIR/kernel/dtb/$ZED_DTBO" ]; then
        sudo cp "$L4T_DIR/kernel/dtb/$ZED_DTBO" "$ROOTFS/boot/"
        echo "[zedx] DTBO staged at /boot/$ZED_DTBO"
    else
        echo "[zedx] WARN: $ZED_DTBO not in kernel/dtb/   run 'make build' first"
        return 1
    fi

    # Remove stale OVERLAYS + FDT lines then inject fresh. CRITICAL: the
    # L4TLauncher only processes the OVERLAYS line when the label ALSO has an
    # explicit FDT line; without FDT the overlay is silently skipped and the
    # camera device tree never reaches the live system (found on device:
    # /proc/device-tree had no camera nodes despite a valid dtbo + OVERLAYS).
    sudo sed -i '/^[[:space:]]*OVERLAYS /d; /^[[:space:]]*FDT /d' "$EXTLINUX"
    local FDT_DTB="kernel_tegra234-p3768-0000+p3767-0000-nv.dtb"
    sudo sed -i "/^[[:space:]]*INITRD \/boot\/initrd[[:space:]]*$/a\\      FDT /boot/dtb/${FDT_DTB}" "$EXTLINUX"
    sudo sed -i "/^[[:space:]]*APPEND \${cbootargs}/a\\      OVERLAYS /boot/${ZED_DTBO}" "$EXTLINUX"
    echo "[zedx] FDT /boot/dtb/$FDT_DTB + OVERLAYS /boot/$ZED_DTBO injected into extlinux.conf"
}
