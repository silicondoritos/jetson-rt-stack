#!/bin/bash
# =============================================================================
#  INSTALL_ZED_SDK.SH   ZED SDK Userspace Install (Custom RT Kernel Aware)
# =============================================================================
#  Purpose: Install Stereolabs ZED SDK 5.3 on the Jetson WITHOUT triggering
#           the installer's own DKMS rebuild of sl_zedx.ko, because we have
#           already built sl_zedx.ko in-tree with vermagic alignment.
#
#  Strategy:
#    1. Verify our in-tree sl_zedx.ko is loaded (vermagic OK).
#    2. Run ZED installer in --silent mode with --skip_drivers (or vendor
#       equivalent). This installs the userspace libs only.
#    3. Verify pyzed Python binding is installable in /opt/av-env.
#    4. If the installer attempts DKMS anyway, our shipped kernel-headers
#       .deb (installed by jetson_first_boot.sh) gives it a vermagic-aligned
#       fallback. The double-built sl_zedx.ko ends up in /lib/modules/extra/
#       and is shadowed by our kernel/drivers/media/i2c/zedx/ build   harmless.
#
#  Idempotent: safe to run multiple times.
#  Run from: jetson_first_boot.sh (after kernel headers .deb is installed).
# =============================================================================
set -e

if [ "$EUID" -ne 0 ]; then
    echo "[!] Must run as root. Use: sudo $0"
    exit 1
fi

ZED_SDK_DIR="/opt/zed-sdk"
ZED_INSTALL_DEST="/usr/local/zed"
KREL=$(uname -r)

echo "==========================================="
echo " ZED SDK Installer (RT Kernel Aware)"
echo "==========================================="

# --- 1. Pre-flight: confirm sl_zedx.ko is loaded ---
echo "[*] Verifying sl_zedx.ko presence and vermagic..."
SL_ZEDX_KO=$(find "/lib/modules/$KREL" -name "sl_zedx.ko*" 2>/dev/null | head -1)
if [ -z "$SL_ZEDX_KO" ]; then
    echo "   [WARN] sl_zedx.ko not found in /lib/modules/$KREL/."
    echo "          The kernel was either not built with CONFIG_VIDEO_ZEDX=m,"
    echo "          or modules_install did not run. SDK install will continue,"
    echo "          but camera capture will not work until this is fixed."
else
    VM=$(modinfo "$SL_ZEDX_KO" 2>/dev/null | awk -F': *' '/^vermagic:/{print $2; exit}')
    if echo "$VM" | grep -q "$KREL"; then
        echo "   -> sl_zedx.ko OK (vermagic: $VM)"
    else
        echo "   [FAIL] sl_zedx.ko vermagic mismatch:"
        echo "          kernel: $KREL"
        echo "          module: $VM"
        echo "          Aborting   SDK would silently install a bad copy."
        exit 1
    fi

    # Try to load it now if not already loaded; first-boot may run before
    # the camera is enumerated, so non-fatal if modprobe finds no device.
    if ! lsmod | grep -q '^sl_zedx'; then
        modprobe sl_zedx 2>/dev/null || true
    fi
fi

# --- 2. CUDA version check ---
# ZED SDK 5.3 requires CUDA 12.6, which is what L4T R36.4.3 ships. If the wrong
# CUDA is in place (e.g. someone pip-installed a CUDA 12.x toolkit), pyzed
# imports will segfault. Verify before installing.
echo "[*] Checking CUDA version..."
if [ -f /usr/local/cuda/version.json ]; then
    CUDA_VER=$(grep -oE '"version" *: *"[0-9.]+"' /usr/local/cuda/version.json | head -1 | grep -oE '[0-9.]+')
    echo "   -> CUDA: $CUDA_VER"
    case "$CUDA_VER" in
        12.6*) echo "   -> CUDA 12.6 detected (matches ZED SDK 5.3 requirement)";;
        *)     echo "   [WARN] CUDA $CUDA_VER may not be compatible with ZED SDK 5.3";;
    esac
else
    echo "   [WARN] CUDA not detected   install nvidia-jetpack first"
fi

# --- 3. Find the installer ---
INSTALLER=$(ls -1 "$ZED_SDK_DIR"/ZED_SDK_Tegra_*.run 2>/dev/null | head -1)
if [ -z "$INSTALLER" ]; then
    echo "[*] No ZED SDK installer found at $ZED_SDK_DIR/ZED_SDK_Tegra_*.run"
    echo "    Skipping ZED SDK install. Drop the .run file in $ZED_SDK_DIR"
    echo "    and re-run: sudo $0"
    exit 0
fi
echo "[*] Found installer: $(basename $INSTALLER)"

# --- 4. Run installer in silent mode ---
# Stereolabs' .run installer accepts these silent-mode flags (verified May
# 2026 against https://www.stereolabs.com/docs/development/zed-sdk/jetson):
#   silent            no interactive prompts
#   runtime_only      install runtime libs only (skip dev tools)
#   skip_python       skip auto-pip; we install pyzed manually below into
#                     /opt/av-env so the venv owns it
#   skip_cuda         do not attempt to install CUDA (L4T owns it)
#   skip_tools        skip ZED Explorer / GUI tools (headless device)
#   skip_od_module    skip the (large) object-detection model bundle
#   skip_hub          skip ZED Hub agent
#   nvpmodel=0        do NOT change the system power profile (we control it)
#
# Earlier revisions of this script invoked `skip_drivers`   that flag does
# NOT exist in the Stereolabs .run installer. We rely on the kernel-side
# ZED X / MAX9296 driver coming from the Stereolabs `.deb` package matching
# the deserializer (see docs/DRIVERS.md §1.2 + VERIFICATION_REPORT.md).
#
# IMPORTANT (vermagic): Stereolabs ships compiled .ko modules in their .deb
# packages built against the stock NVIDIA L4T kernel. Those modules will
# NOT load on our PREEMPT_RT kernel without source. If you have access to
# the ZED X driver source via your Stereolabs business agreement, place it
# at $ZEDX_DRIVER_DIR before `make extract` so the in-tree promotion
# (drivers/media/i2c/zedx/) builds it under our kernel's vermagic.
chmod +x "$INSTALLER"
echo "[*] Running ZED SDK installer (silent mode)..."
"$INSTALLER" -- silent runtime_only skip_python skip_cuda skip_tools \
                  skip_od_module skip_hub nvpmodel=0 \
    || {
        echo "   [WARN] ZED SDK installer returned non-zero. Continuing   userspace"
        echo "          may have partial install; check $ZED_INSTALL_DEST/."
    }

# --- 5. Install pyzed into the AV venv ---
echo "[*] Installing pyzed into /opt/av-env..."
if [ -d /opt/av-env ]; then
    # ZED ships a get_python_api.py helper; older installers put it in
    # $ZED_INSTALL_DEST, newer ones in /usr/local/zed/.
    GET_PY=$(find "$ZED_INSTALL_DEST" -name 'get_python_api.py' 2>/dev/null | head -1)
    if [ -n "$GET_PY" ]; then
        # get_python_api.py imports `requests`, which the venv does not ship.
        /opt/av-env/bin/pip show requests >/dev/null 2>&1 || \
            /opt/av-env/bin/pip install requests
        # Use our venv's python so the wheel lands inside it.
        /opt/av-env/bin/python "$GET_PY" || {
            echo "   [WARN] get_python_api.py failed; pyzed not installed."
            echo "          Re-run manually: /opt/av-env/bin/python $GET_PY"
        }
        # pyzed's wheel declares an UNBOUNDED numpy dep and the helper
        # installs with --ignore-installed, which upgrades the venv to
        # numpy 2.x and breaks the Voyager pins + any cv2 built against
        # 1.x headers (observed live 2026-06-10). Re-assert the pin.
        /opt/av-env/bin/pip install "numpy<2.0.0" 2>&1 | tail -1
    else
        echo "   [WARN] get_python_api.py not found; skipping pyzed install."
    fi
else
    echo "   [WARN] /opt/av-env not found; pyzed install skipped."
    echo "          jetson_first_boot.sh creates the venv   re-run it."
fi

# --- 5b. Group access ---
# The installer creates $ZED_INSTALL_DEST as 770 root:zed, so any user not in
# the `zed` group cannot even traverse the dir   pyzed then fails with
# "ImportError: libsl_zed.so: cannot open shared object file" (verified live
# 2026-06-10). Put the target user in the group; takes effect on next login
# (use `sg zed -c ...` in the current session).
ZED_USER="${TARGET_USER:-j}"
if getent group zed >/dev/null 2>&1 && id "$ZED_USER" >/dev/null 2>&1; then
    if ! id -nG "$ZED_USER" | tr ' ' '\n' | grep -qx zed; then
        usermod -aG zed "$ZED_USER"
        echo "   -> added $ZED_USER to the zed group (re-login to take effect)"
    fi
fi

# --- 6. Smoke test ---
echo "[*] Smoke-testing ZED SDK..."
if [ -f /opt/av-env/bin/python ]; then
    /opt/av-env/bin/python - <<'PY' || echo "   [WARN] pyzed import failed"
try:
    import pyzed.sl as sl
    print("   -> pyzed import OK, version:", sl.Camera.create_camera_information.__doc__ is not None and "available")
except Exception as e:
    print(f"   [WARN] pyzed import failed: {e}")
PY
fi

echo "==========================================="
echo " ZED SDK install complete."
echo "==========================================="
