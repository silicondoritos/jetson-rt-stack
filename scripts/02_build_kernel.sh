#!/bin/bash
set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/config.sh"

echo "==========================================="
echo " AV Kernel Phase 2: Compilation (The Forge)"
echo "==========================================="
echo " Environment: Docker Forge (jetson-av-builder)"
echo "==========================================="

SOURCE="$SOURCE_DIR"
L4T="$L4T_DIR"
ROOTFS="$L4T/rootfs"

cd "$SOURCE"

export CROSS_COMPILE="$CROSS_COMPILE_BIN"
export ARCH=arm64
export LOCALVERSION="$LOCALVERSION"
export KERNEL_HEADERS="$PWD/kernel/kernel-jammy-src"

# IGNORE_PREEMPT_RT_PRESENCE: suppress NVIDIA's check that prevents
# generic_rt_build.sh from running outside its own environment.
# Required when building PREEMPT_RT inside Docker with the Bootlin toolchain.
if [ "${CONFIG_KERNEL_PREEMPT_RT:-y}" = "y" ]; then
    export IGNORE_PREEMPT_RT_PRESENCE=1
fi

# --- Reproducibility knobs ---
if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
    SOURCE_DATE_EPOCH="$(git -C "$REPO_ROOT" log -1 --format=%ct 2>/dev/null || date +%s)"
fi
export SOURCE_DATE_EPOCH

export LC_ALL=C
export LANG=C

BUILD_LOG="$REPO_ROOT/BUILD_LOG.md"

echo "[*] SOURCE_DATE_EPOCH = $SOURCE_DATE_EPOCH"
echo "[*] LOCALVERSION = $LOCALVERSION"

echo "[*] Building Kernel Image..."
make -C kernel version=-tegra -j"$(nproc)" 2>&1 | tee -a "$BUILD_LOG"
[ "${PIPESTATUS[0]}" -eq 0 ] || { echo "[FAIL] kernel Image build failed"; exit 1; }

echo "[*] Building OOT Modules (NVIDIA + vendor plugins)..."
# A prior bindeb-pkg headers build leaves debian/linux-headers/ behind with
# broken symlinks (lib/modules/<rel>/build and scripts/dtc/include-prefixes/<arch>
# for arches the trimmed kernel doesn't ship). NVIDIA's nvidia-headers target
# then runs `cp -LR kernel-jammy-src/*`, follows those dead links, and aborts the
# whole `make modules` with "cannot stat". Strip dangling symlinks under debian/
# first so the headers copy (and thus nvgpu/nvdisplay) builds cleanly. Idempotent.
if [ -d "$KERNEL_SRC/debian" ]; then
    find "$KERNEL_SRC/debian" -xtype l -delete 2>/dev/null || true
fi
make modules -j"$(nproc)" 2>&1 | tee -a "$BUILD_LOG"
[ "${PIPESTATUS[0]}" -eq 0 ] || { echo "[FAIL] module build failed"; exit 1; }

echo "[*] Building Device Trees..."
make dtbs -j"$(nproc)" 2>&1 | tee -a "$BUILD_LOG"
[ "${PIPESTATUS[0]}" -eq 0 ] || { echo "[FAIL] dtbs build failed"; exit 1; }

# --- Verify critical build outputs ---
echo "[*] Verifying build outputs..."
KERNEL_IMAGE="$L4T/source/kernel/kernel-jammy-src/arch/arm64/boot/Image"

[ -f "$KERNEL_IMAGE" ] && echo "   [OK] kernel Image" || { echo "   [FAIL] kernel Image not found!"; exit 1; }

# Conditional checks based on config
if [ "${CONFIG_AXELERA_METIS:-y}" = "y" ]; then
    METIS_KO="$SOURCE/axelera/metis.ko"
    [ -f "$METIS_KO" ] && echo "   [OK] metis.ko" \
        || echo "   [WARN] metis.ko not found   check axelera-driver tree"
fi

if [ "${CONFIG_CAMERA_ZEDX_MONO:-n}" = "y" ] || [ "${CONFIG_CAMERA_ZEDX_DUO:-n}" = "y" ]; then
    ZEDX_KO=$(find "$SOURCE/stereolabs" -name "sl_zedx.ko" 2>/dev/null | head -1)
    [ -n "$ZEDX_KO" ] && echo "   [OK] sl_zedx.ko" \
        || echo "   [WARN] sl_zedx.ko not found   check zedx-driver tree"
fi

echo "[*] Installing Kernel Image..."
cp kernel/kernel-jammy-src/arch/arm64/boot/Image "$L4T/kernel/Image"
cp kernel/kernel-jammy-src/arch/arm64/boot/Image.gz "$L4T/kernel/Image.gz" 2>/dev/null || true

echo "[*] Installing modules into rootfs (requires sudo)..."
export INSTALL_MOD_PATH="$ROOTFS"
sudo -E make install -C kernel version=-tegra
sudo -E make modules_install

# --- Vendor external modules (M=) -------------------------------------------
# The in-tree metis-wrapper/ uses a custom `modules:` target that Kbuild's
# obj-m subdir descent never invokes, so vendor modules must be built as
# EXTERNAL modules (M=) against the just-built kernel. This guarantees the
# kernel's exact vermagic (same mechanism the NVIDIA OOT modules use).
KREL_DIR="$(cat "$KERNEL_SRC/include/config/kernel.release" 2>/dev/null || echo 5.15.148-tegra)"
build_vendor_mod() {
    local label="$1" vdir="$2"; shift 2
    # Remaining args are extra make variables (KBUILD_EXTRA_SYMBOLS=..., etc).
    [ -f "$vdir/Makefile" ] || { echo "   [WARN] $label: $vdir/Makefile missing   skipping"; return 0; }
    echo "[*] Building $label external module (M=$vdir)..."
    if make -C "$KERNEL_SRC" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" LOCALVERSION=-tegra M="$vdir" "$@" modules; then
        sudo -E make -C "$KERNEL_SRC" LOCALVERSION=-tegra M="$vdir" "$@" INSTALL_MOD_PATH="$ROOTFS" modules_install
        echo "   [OK] $label installed"
    else
        echo "   [WARN] $label build failed   module will be absent"
    fi
}
[ "${CONFIG_AXELERA_METIS:-y}" = "y" ] && build_vendor_mod "Metis (axelera)" "$AXELERA_DRIVER_DIR"
# ZED X stereolabs drivers (sl_zedx + GMSL deserializers) build the same way:
# source/stereolabs/Makefile is `obj-m += drivers/`, and the in-tree zedx-wrapper/
# custom modules: target is   like metis-wrapper/   never invoked by Kbuild's obj-m
# descent. Build + install it as an external module so its vermagic matches exactly.
# The deserializer (MAX9296 vs MAX96712) was already selected in stereolabs/drivers/
# Makefile by the zedx plugin's post_extract.
if [ "${CONFIG_CAMERA_ZEDX_MONO:-n}" = "y" ] || [ "${CONFIG_CAMERA_ZEDX_DUO:-n}" = "y" ]; then
    # The stereolabs drivers consume symbols exported by the NVIDIA OOT camera
    # stack (tegracam_*/camera_common_*) and hwpm: without their Module.symvers,
    # the external-module MODPOST fails with "undefined!" and the camera ships
    # absent. Mirrors the KBUILD_EXTRA_SYMBOLS chain of L4T's own stereolabs
    # target (source/Makefile).
    build_vendor_mod "ZED X (stereolabs)" "$SOURCE/stereolabs" \
        "KBUILD_EXTRA_SYMBOLS=$SOURCE/nvidia-oot/Module.symvers $SOURCE/hwpm/drivers/tegra/hwpm/Module.symvers" \
        "CONFIG_TEGRA_OOT_MODULE=m" \
        "srctree.sl_drivers=$SOURCE/stereolabs/"
fi
sudo depmod -b "$ROOTFS" "$KREL_DIR" 2>/dev/null || true

echo "[*] Installing Device Trees & Overlays..."
mkdir -p "$L4T/kernel/dtb/"
find kernel-devicetree/ -name "*.dtb*" -exec cp {} "$L4T/kernel/dtb/" \;
DTB_COUNT=$(ls "$L4T/kernel/dtb/"*.dtb* 2>/dev/null | wc -l)
echo "   -> $DTB_COUNT DTB files installed."

# --- Compile ZED X Overlay DTBO (conditional) ---
# NVIDIA's kernel-devicetree build system silently skips dtbo-y targets due to
# a missing BUILDOVERLAY flag. Compile directly with cpp + dtc.
if [ "${CONFIG_CAMERA_ZEDX_MONO:-n}" = "y" ] || [ "${CONFIG_CAMERA_ZEDX_DUO:-n}" = "y" ]; then
    echo "[*] Compiling ZED X overlay DTBO..."
    DTC_BIN="$SOURCE/kernel/kernel-jammy-src/scripts/dtc/dtc"
    HW_NV="$SOURCE/hardware/nvidia"
    DTBO_NAME="${CONFIG_ZEDX_DTBO_NAME:-tegra234-p3768-camera-zedlink-mono-sl-overlay.dtbo}"
    ZED_DTS="$HW_NV/t23x/nv-public/$(basename "$DTBO_NAME" .dtbo).dts"
    ZED_DTBO="$L4T/kernel/dtb/$DTBO_NAME"

    cpp -E \
        -DBUILDOVERLAY \
        -DLINUX_VERSION=600 \
        -DTEGRA_HOST1X_DT_VERSION=2 \
        -x assembler-with-cpp \
        -nostdinc \
        -I"$HW_NV/t23x/nv-public" \
        -I"$HW_NV/t23x/nv-public/include/kernel" \
        -I"$HW_NV/t23x/nv-public/include/nvidia-oot" \
        -I"$HW_NV/t23x/nv-public/include/platforms" \
        -I"$HW_NV/tegra/nv-public" \
        -I"$SOURCE/kernel/kernel-jammy-src/include" \
        -o /tmp/zedlink-mono.dts.tmp \
        "$ZED_DTS"

    $DTC_BIN -@ -f -I dts -O dtb -o "$ZED_DTBO" /tmp/zedlink-mono.dts.tmp
    echo "   -> $(ls -lh "$ZED_DTBO" | awk '{print $5, $NF}')   ZED X overlay DTBO compiled."
fi

# --- Build linux-headers-*.deb for on-target DKMS ---
echo "[*] Building linux-headers-*.deb for on-target DKMS..."
cd "$SOURCE/kernel/kernel-jammy-src"
if make -j"$(nproc)" bindeb-pkg LOCALVERSION="$LOCALVERSION" \
        KDEB_PKGVERSION="1-tegra" 2>&1 | tee -a "$BUILD_LOG"; then
    HEADERS_DEB=$(ls -t "$SOURCE/kernel/"linux-headers-*.deb 2>/dev/null | head -1)
    if [ -n "$HEADERS_DEB" ]; then
        mkdir -p "$L4T/staging/kernel-headers"
        cp "$HEADERS_DEB" "$L4T/staging/kernel-headers/"
        echo "   -> $(basename "$HEADERS_DEB") staged at $L4T/staging/kernel-headers/"
    else
        echo "   [WARN] linux-headers-*.deb not found after bindeb-pkg"
    fi
else
    echo "   [WARN] bindeb-pkg failed   on-target DKMS will not have headers"
fi
cd "$SOURCE"

echo "[*] Updating Initramfs (best-effort)..."
cd "$L4T"
# nv-update-initrd is installed into the rootfs by apply_binaries.sh, which runs
# at FLASH time (04_flash_nvme.sh) and regenerates the boot initrd there. At
# build time the rootfs has no nv-update-initrd, so this is best-effort only.
if ! sudo ./tools/l4t_update_initrd.sh; then
    echo "   [WARN] l4t_update_initrd.sh failed (nv-update-initrd absent until apply_binaries"
    echo "          runs at flash). Skipping; the boot initrd is regenerated during make flash."
fi

# --- Capture EXPECTED_VERMAGIC for downstream audit gates ---
echo "[*] Capturing EXPECTED_VERMAGIC..."
SAMPLE_KO=$(find "$SOURCE/kernel/kernel-jammy-src" "$SOURCE/stereolabs" "$SOURCE/axelera" \
              -name '*.ko' -type f 2>/dev/null | head -1)
if [ -n "$SAMPLE_KO" ]; then
    VM=$(modinfo "$SAMPLE_KO" 2>/dev/null | awk -F': *' '/^vermagic:/{print $2; exit}')
    [ -z "$VM" ] && VM=$(strings "$SAMPLE_KO" 2>/dev/null | grep -m1 '^vermagic=' | sed 's/^vermagic=//')
    if [ -n "$VM" ]; then
        echo "$VM" > "$L4T/EXPECTED_VERMAGIC"
        echo "   -> EXPECTED_VERMAGIC: $VM"
    fi
fi

# --- Vermagic consistency check ---
echo "[*] Running vermagic consistency gate..."
if [ -x "$REPO_ROOT/scripts/verify_vermagic.sh" ]; then
    L4T="$L4T" bash "$REPO_ROOT/scripts/verify_vermagic.sh" --build-tree || {
        echo "[!] Vermagic mismatch in build tree. Aborting Phase 2."
        exit 1
    }
fi

# --- Write BUILD_MANIFEST.json ---
echo "[*] Writing BUILD_MANIFEST.json..."
KREL=$(cat "$SOURCE/kernel/kernel-jammy-src/include/config/kernel.release" 2>/dev/null || echo unknown)
DEFCONFIG_SHA=$(sha256sum "$SOURCE/kernel/kernel-jammy-src/arch/arm64/configs/defconfig" 2>/dev/null | awk '{print $1}')
TOOLCHAIN_VER=$("${CROSS_COMPILE}gcc" --version 2>/dev/null | head -1 || echo unknown)
GIT_HEAD=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)
GIT_DIRTY=$(git -C "$REPO_ROOT" diff --quiet 2>/dev/null && echo clean || echo dirty)

cat > "$L4T/BUILD_MANIFEST.json" <<JSON
{
  "build_time_iso8601": "$(date -u -Iseconds)",
  "source_date_epoch":  "${SOURCE_DATE_EPOCH}",
  "host_user":          "${BUILD_IDENTITY:-silicondoritos}",
  "host_uname":         "$(uname -srvm)",
  "kernel_release":     "${KREL}",
  "expected_vermagic":  "$(cat "$L4T/EXPECTED_VERMAGIC" 2>/dev/null || echo unknown)",
  "localversion":       "${LOCALVERSION}",
  "cross_compile":      "${CROSS_COMPILE}",
  "toolchain_gcc":      "$(echo "$TOOLCHAIN_VER" | sed 's/"/\\"/g')",
  "defconfig_sha256":   "${DEFCONFIG_SHA}",
  "git_head":           "${GIT_HEAD}",
  "git_state":          "${GIT_DIRTY}",
  "headers_deb":        "$(ls -1 "$L4T/staging/kernel-headers/"linux-headers-*.deb 2>/dev/null | head -1 | xargs -n1 basename 2>/dev/null || echo none)"
}
JSON
echo "   -> $L4T/BUILD_MANIFEST.json"

echo ""
echo "==========================================="
echo " Phase 2 Complete. Kernel Built & Installed."
echo "==========================================="
echo ""
echo " Kernel:   $L4T/kernel/Image"
echo " Modules:  $ROOTFS/lib/modules/"
echo " DTBs:     $L4T/kernel/dtb/"
echo ""
echo " Next (on Host, outside Docker): make bake"
