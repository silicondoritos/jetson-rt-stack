#!/bin/bash
# =============================================================================
# plugins/axelera/plugin.sh   Axelera Metis + Voyager SDK integration hooks
# =============================================================================
# This file contains our integration glue. The Axelera Metis kernel driver,
# Voyager SDK, and axl-jetson.patch are NOT included in this repo   they are
# proprietary (Axelera customer portal, account, no NDA). See docs/DRIVERS.md for acquisition instructions.
#
# What this plugin does:
#   doctor          validate axelera-driver and voyager-sdk vendor trees
#   post_extract    inject vendor driver sources into L4T kernel tree, create
#                   in-tree Kconfig/Makefile shims, apply PCIe patience patch,
#                   stage udev rules
#   post_defconfig   append CONFIG_AXELERA_METIS to kernel defconfig
#   pre_bake        stage Voyager SDK and udev rules into rootfs
# =============================================================================

plugin_name() { echo "axelera"; }

# ---------------------------------------------------------------------------
# doctor
# ---------------------------------------------------------------------------
axelera_doctor() {
    if [ "${CONFIG_AXELERA_METIS:-y}" != "y" ]; then
        echo "[axelera] AXELERA_METIS=n   skipping Axelera doctor checks"
        return 0
    fi

    local failed=0

    if { [ -d "$AXELERA_DRIVER_DIR/.git" ] || [ -d "$AXELERA_DRIVER_DIR" ]; } \
       && [ -n "$(ls -A "$AXELERA_DRIVER_DIR" 2>/dev/null)" ]; then
        log::pass "axelera-driver (populated)"
    else
        log::xfail "axelera-driver" \
            "account-gated   request access via the Axelera customer portal, then place at: $AXELERA_DRIVER_DIR"
        log::xfail "  └ info" "see docs/DRIVERS.md §Axelera Metis for acquisition steps"
        failed=1
    fi

    if [ "${CONFIG_VOYAGER_SDK:-y}" = "y" ]; then
        if [ -d "$VOYAGER_SDK_DIR" ] && [ -n "$(ls -A "$VOYAGER_SDK_DIR" 2>/dev/null)" ]; then
            log::pass "voyager-sdk (populated)"
            if [ -f "$VOYAGER_SDK_DIR/axl-jetson.patch" ]; then
                log::pass "  └ axl-jetson.patch present"
            else
                log::warn "  └ axl-jetson.patch missing   will use sed-only PCIe patch"
                WARN_COUNT=$((WARN_COUNT + 1))
            fi
        else
            log::warn "voyager-sdk empty   place Voyager SDK 1.6 source tree at $VOYAGER_SDK_DIR"
            log::warn "  └ info: see docs/DRIVERS.md §Voyager SDK for acquisition steps"
            WARN_COUNT=$((WARN_COUNT + 1))
        fi
    fi

    return $failed
}

# ---------------------------------------------------------------------------
# post_extract   inject vendor sources, create in-tree shims, apply PCIe patch
# ---------------------------------------------------------------------------
axelera_post_extract() {
    if [ "${CONFIG_AXELERA_METIS:-y}" != "y" ]; then
        echo "[axelera] AXELERA_METIS=n   skipping Axelera extraction"
        return 0
    fi

    local L4T_SRC="$L4T_DIR/source"
    local KERNEL_TREE="$L4T_SRC/kernel/kernel-jammy-src"

    # 1. Inject Axelera driver sources into the L4T source tree
    echo "[axelera] Injecting Axelera Metis driver sources..."
    sudo mkdir -p "$L4T_SRC/axelera/axelera-driver"
    sudo rsync -av --exclude='.git' "$AXELERA_DRIVER_DIR/" \
        "$L4T_SRC/axelera/axelera-driver/"
    sudo chown -R "$(id -u):$(id -g)" "$L4T_SRC/axelera/"

    # 2. Promote to in-tree build (vermagic safety)
    if [ "${CONFIG_AXELERA_PROMOTE_INTREE:-y}" = "y" ]; then
        _axelera_promote_intree "$KERNEL_TREE"
    fi

    # 3. Stage udev rules at extract time (belt-and-suspenders; also at bake)
    if [ "${CONFIG_AXELERA_UDEV_RULES:-y}" = "y" ]; then
        sudo mkdir -p "$L4T_DIR/rootfs/etc/udev/rules.d/"
        sudo cp "$AXELERA_DRIVER_DIR/udev/72-axelera.rules" \
            "$L4T_DIR/rootfs/etc/udev/rules.d/"
        echo "[axelera] Axelera udev rules staged."
    fi

    # 4. PCIe patience patch
    _axelera_pcie_patch "$KERNEL_TREE"
}

# Internal: create drivers/misc/axelera/ in-tree shim
_axelera_promote_intree() {
    local KERNEL_TREE="$1"
    local AXL_DIR="$KERNEL_TREE/drivers/misc/axelera"

    echo "[axelera] Promoting Axelera Metis to in-tree build (vermagic safety)..."
    sudo mkdir -p "$AXL_DIR"
    sudo chown -R "$(id -u):$(id -g)" "$AXL_DIR"

    if [ ! -L "$AXL_DIR/metis-src" ]; then
        ln -sfn "../../../../../axelera/axelera-driver" "$AXL_DIR/metis-src"
    fi

    # Kconfig stub
    cat > "$AXL_DIR/Kconfig" <<'KCONFIG'
config AXELERA_METIS
    tristate "Axelera Metis M.2 PCIe AI accelerator"
    depends on PCI
    default m
    help
      Driver for the Axelera Metis M.2 AIPU (1f9d:1100). Built in-tree
      so vermagic always matches the running kernel.
KCONFIG

    cat > "$AXL_DIR/Makefile" <<'MAKE'
obj-$(CONFIG_AXELERA_METIS) += metis-wrapper/
MAKE

    sudo mkdir -p "$AXL_DIR/metis-wrapper"
    sudo chown -R "$(id -u):$(id -g)" "$AXL_DIR/metis-wrapper"

    cat > "$AXL_DIR/metis-wrapper/Makefile" <<'MAKE'
# In-tree wrapper that sub-makes into the vendor OOT Makefile.
# See the explanatory comment in the ZED X wrapper for the rationale.
VENDOR_DIR := $(srctree)/drivers/misc/axelera/metis-src

ifneq ($(KERNELRELEASE),)
obj-m :=
modules:
	@echo "[axelera] sub-make → $(VENDOR_DIR)"
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

    if [ ! -f "$AXL_DIR/metis-src/Makefile" ]; then
        echo "[axelera] WARN: metis-src/Makefile missing   verify axelera-driver/ contents"
    fi

    # Wire into drivers/misc/Kconfig and Makefile
    local MISC_KCONFIG="$KERNEL_TREE/drivers/misc/Kconfig"
    local MISC_MAKEFILE="$KERNEL_TREE/drivers/misc/Makefile"

    if [ -f "$MISC_KCONFIG" ] && ! grep -q 'drivers/misc/axelera/Kconfig' "$MISC_KCONFIG"; then
        if grep -q '^endmenu' "$MISC_KCONFIG"; then
            sudo sed -i '/^endmenu/i source "drivers/misc/axelera/Kconfig"' "$MISC_KCONFIG"
        else
            printf 'source "drivers/misc/axelera/Kconfig"\n' | sudo tee -a "$MISC_KCONFIG" >/dev/null
        fi
    fi

    if [ -f "$MISC_MAKEFILE" ] && ! grep -q 'CONFIG_AXELERA_METIS' "$MISC_MAKEFILE"; then
        printf 'obj-$(CONFIG_AXELERA_METIS) += axelera/\n' | sudo tee -a "$MISC_MAKEFILE" >/dev/null
    fi

    echo "[axelera] Metis in-tree promotion complete."
}

# Internal: PCIe link-training patience patch
_axelera_pcie_patch() {
    local KERNEL_TREE="$1"
    local PCIE_HEADER="$KERNEL_TREE/drivers/pci/controller/dwc/pcie-designware.h"
    # 200 retries (~18s) so the RTL8822CE M.2 Key-E WiFi card has time to bring its
    # PCIe link up: its Bluetooth half inits first over USB, then the WiFi PCIe side
    # powers up several seconds later. 50 retries (~4.5s) gave up too early and WiFi
    # never enumerated (Metis trains fast, so it was unaffected). A slot whose card
    # trains links up early, so this only lengthens boot for genuinely empty slots.
    local RETRIES="${CONFIG_PCIE_LINK_WAIT_MAX_RETRIES:-200}"

    echo "[axelera] Applying PCIe patience patch (LINK_WAIT_MAX_RETRIES=$RETRIES)..."

    # Try the vendor patch first (optional   requires voyager-sdk tree)
    if [ -f "$VOYAGER_SDK_DIR/axl-jetson.patch" ]; then
        (
            cd "$KERNEL_TREE"
            patch -p1 -N < "$VOYAGER_SDK_DIR/axl-jetson.patch" || true
        )
    fi

    # Always force the configured value regardless of whether patch was applied
    if [ -f "$PCIE_HEADER" ]; then
        # ERE; consume ALL whitespace + every trailing number so the L4T
        # tab-tab alignment (RETRIES\t\t50) cannot leave an orphan value.
        # Idempotent: re-running collapses "100\t50" back to a single "100".
        sed -i -E "s/(#define[[:space:]]+LINK_WAIT_MAX_RETRIES)([[:space:]]+[0-9]+)+/\1\t${RETRIES}/" \
            "$PCIE_HEADER"
        echo "   -> LINK_WAIT_MAX_RETRIES set to $RETRIES"
    fi
}

# ---------------------------------------------------------------------------
# post_defconfig   append CONFIG_AXELERA_METIS to kernel defconfig
# ---------------------------------------------------------------------------
axelera_post_defconfig() {
    if [ "${CONFIG_AXELERA_METIS:-y}" != "y" ]; then
        return 0
    fi

    local DEFCONFIG="$KERNEL_SRC/arch/arm64/configs/defconfig"

    if ! grep -q "CONFIG_AXELERA_METIS" "$DEFCONFIG"; then
        cat >> "$DEFCONFIG" <<'EOF'

# ============================================================
# Axelera Metis in-tree driver (injected by axelera plugin)
# ============================================================
CONFIG_AXELERA_METIS=m
EOF
    fi
}

# ---------------------------------------------------------------------------
# pre_bake   stage Voyager SDK and udev rules into rootfs
# ---------------------------------------------------------------------------
axelera_pre_bake() {
    if [ "${CONFIG_AXELERA_METIS:-y}" != "y" ]; then
        echo "[axelera] AXELERA_METIS=n   skipping Axelera bake staging"
        return 0
    fi

    local ROOTFS="$L4T_DIR/rootfs"
    local TARGET_HOME="$ROOTFS/home/${TARGET_USER:-j}"

    # Voyager SDK
    if [ "${CONFIG_VOYAGER_SDK:-y}" = "y" ]; then
        if [ -d "$VOYAGER_SDK_DIR" ] && [ -n "$(ls -A "$VOYAGER_SDK_DIR" 2>/dev/null)" ]; then
            echo "[axelera] Staging Voyager SDK into rootfs..."
            # Idempotent: remove any prior copy first, else cp -r nests it
            # (TARGET_HOME/voyager-sdk/voyager-sdk) and errors on re-bake.
            sudo rm -rf "$TARGET_HOME/voyager-sdk"
            sudo cp -r "$VOYAGER_SDK_DIR" "$TARGET_HOME/voyager-sdk"
        else
            echo "[axelera] WARN: voyager-sdk tree empty   skipping SDK staging"
        fi
    fi

    # udev rules (belt-and-suspenders   also done at extract time)
    if [ "${CONFIG_AXELERA_UDEV_RULES:-y}" = "y" ]; then
        echo "[axelera] Staging Axelera udev rules..."
        sudo mkdir -p "$ROOTFS/etc/udev/rules.d/"
        sudo cp "$AXELERA_DRIVER_DIR/udev/72-axelera.rules" \
            "$ROOTFS/etc/udev/rules.d/"
    fi
}
