#!/bin/bash
# =============================================================================
# scripts/show_versions.sh   print the version manifest
# =============================================================================
# Prints what this build pins. Used as `make versions` and at the top of every
# build manifest. Reads versions.env via lib/config.sh.
# =============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/config.sh"
. "$HERE/lib/log.sh"

log::section "AV Firmware: Version Manifest"

cat <<EOF
Repository       : $REPO_ROOT

L4T / JetPack
  L4T            : $L4T_VERSION
  JetPack        : $JETPACK_VERSION
  Kernel base    : $KERNEL_BASE_VERSION
  LOCALVERSION   : $LOCALVERSION

Toolchain (Bootlin, locked)
  Toolchain      : $BOOTLIN_TOOLCHAIN
  Prefix         : $BOOTLIN_PREFIX
  Install at     : $TOOLCHAIN_DIR

CUDA / Python stack
  CUDA           : $CUDA_VERSION
  PyTorch        : $PYTORCH_VERSION
  torchvision    : $TORCHVISION_VERSION
  PyTorch index  : $PYTORCH_INDEX_URL
  numpy          : $NUMPY_CONSTRAINT
  Voyager pypi   : $VOYAGER_PYPI_URL

ZED SDK
  Version        : $ZED_SDK_VERSION

Hardware target
  Board          : $TARGET_BOARD
  Storage        : $TARGET_STORAGE_DEV
  Hostname       : $TARGET_HOSTNAME
  USB IP         : $TARGET_USB_IP
  USB ID (APX)   : $USB_ID_APX
  USB ID (RNDIS) : $USB_ID_RNDIS

RT tuning
  Isolated cores : $RT_ISOLATED_CORES
  Boot args      : $RT_BOOT_ARGS

Critical kernel patches
  PCIe retries   : $PCIE_LINK_WAIT_MAX_RETRIES
  CMA size (MB)  : $CMA_SIZE_MBYTES

External vendor trees
  Axelera        : $AXELERA_DRIVER_DIR
  Voyager SDK    : $VOYAGER_SDK_DIR
  ZED X driver   : $ZEDX_DRIVER_DIR
  ZED SDK        : $ZED_SDK_DIR

Required NVIDIA tarballs (must live next to repo root)
  L4T            : $TARBALL_L4T_PATH
  RootFS         : $TARBALL_ROOTFS_PATH
  Public sources : $TARBALL_PUBLIC_SOURCES_PATH

Docker
  Image tag      : $DOCKER_IMAGE_TAG
EOF

# Extra runtime info if the build has happened
if [ -f "$EXPECTED_VERMAGIC_FILE" ]; then
    echo
    log::section "Last Build"
    echo "EXPECTED_VERMAGIC : $(cat "$EXPECTED_VERMAGIC_FILE")"
    if [ -f "$BUILD_MANIFEST" ]; then
        echo "Manifest          : $BUILD_MANIFEST"
        echo
        cat "$BUILD_MANIFEST"
    fi
fi
