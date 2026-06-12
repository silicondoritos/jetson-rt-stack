#!/bin/bash
# =============================================================================
#  INSTALL_ZEDX_DAEMONS.SH   ZED X SPSC/IMU kernel modules + vendor daemons
# =============================================================================
#  ZED SDK 5.3 cannot open a ZED X ("CAMERA MOTION SENSORS NOT DETECTED",
#  "No camera-to-SPSC mappings found") without three pieces that live in the
#  zedx-driver vendor tree, NOT in the SDK installer:
#
#    1. bmi088.ko + bmi_spsc.ko   the BMI088 IMU + SPSC ring-buffer modules.
#       Built here against the running kernel's vermagic-aligned headers.
#    2. The vendor daemons: ZEDX_Driver (driver_zed_loader.service, reloads
#       the module stack in link order), ZEDX_Daemon (zed_x_daemon.service),
#       IMU_Daemon (IMU_Daemon.service, the privileged SPSC broker).
#    3. A udev rule granting the `zed` group access to /dev/spsc_bmi*.
#
#  IMPORTANT (path trap, verified live 2026-06-10): ZEDX_Driver insmods from
#  /usr/lib/modules/$(uname -r)/kernel/drivers/stereolabs/   NOT updates/.
#  Modules must be installed there or the loader silently skips them and the
#  SDK loses the IMU on every loader restart.
#
#  Requires: the zedx-driver vendor tree (ZEDX_DRIVER_DIR or /home/j/zedx-driver),
#  linux-headers for the running kernel, gcc/cmake/bison/flex, qtbase5-dev.
#  Idempotent: safe to re-run.
# =============================================================================
set -e

if [ "$EUID" -ne 0 ]; then echo "[!] Must run as root. Use: sudo $0"; exit 1; fi

KREL=$(uname -r)
HDRS=/usr/src/linux-headers-$KREL
# Vendor tree resolution: the bake stages a minimal subset (Daemon/,
# nvidia_364_fix/, bmi088 module source) at /opt/zedx-daemons/vendor; a full
# zedx-driver checkout (dev machines) works the same way.
if [ -z "${ZEDX_DRIVER_DIR:-}" ] && [ -d /opt/zedx-daemons/vendor/Daemon ]; then
    ZEDX_DRIVER_DIR=/opt/zedx-daemons/vendor
fi
VENDOR="${ZEDX_DRIVER_DIR:-/home/j/zedx-driver}"
# Prebuilt daemon binaries (staged from zedx-daemon-cache/ at bake) skip the
# on-device cmake/Qt build entirely.
DAEMON_CACHE="${DAEMON_CACHE:-/opt/zedx-daemons/cache}"
LOADER_MOD_DIR=/usr/lib/modules/$KREL/kernel/drivers/stereolabs/bmi088
BMI_SRC="$VENDOR/src/kernel/stereolabs/drivers/stereolabs/bmi088"

echo "==========================================="
echo " ZED X SPSC modules + daemons installer"
echo "==========================================="

[ -d "$VENDOR/Daemon" ] || { echo "[!] vendor tree not found at $VENDOR"; exit 1; }
[ -d "$HDRS" ] || { echo "[!] headers missing: $HDRS   install /opt/kernel-headers/*.deb first"; exit 1; }

# --- 1. Repair cross-built headers host tools --------------------------------
# The headers .deb is produced by a cross-compile, so scripts/basic/fixdep &
# friends are x86_64 binaries that cannot run on the Jetson. Any on-target
# module build (this one, or any DKMS installer) dies with "Exec format
# error" until they are rebuilt natively. Do NOT run `make scripts` here: the
# headers .deb ships no Kconfig files, so in-tree targets fail AND delete
# generated files the deb provided.
if file -b "$HDRS/scripts/basic/fixdep" 2>/dev/null | grep -q x86-64; then
    echo "[*] Rebuilding headers host tools natively (x86 binaries shipped)..."
    apt-get install -y -o DPkg::Lock::Timeout=600 bison flex libssl-dev >/dev/null
    ( cd "$HDRS"
      for f in $(find scripts tools -type f 2>/dev/null); do
          file -b "$f" 2>/dev/null | grep -q "x86-64" && rm -f "$f" || true
      done
      gcc -O2 -o scripts/basic/fixdep scripts/basic/fixdep.c
      cd scripts/genksyms
      [ -f parse.tab.c ] || bison -o parse.tab.c --defines=parse.tab.h parse.y
      [ -f lex.lex.c ]  || flex -o lex.lex.c lex.l
      gcc -O2 -I. -o genksyms genksyms.c parse.tab.c lex.lex.c
      cd ../mod
      gcc -O2 -o mk_elfconfig mk_elfconfig.c
      ./mk_elfconfig < empty.o > elfconfig.h 2>/dev/null || ./mk_elfconfig < /bin/ls > elfconfig.h
      gcc -O2 -o modpost modpost.c file2alias.c sumversion.c )
    # Freeze the syncconfig trigger: generated files must be newer than .config
    touch "$HDRS/.config" 2>/dev/null || true
    sleep 1
    touch "$HDRS/include/config/auto.conf" "$HDRS/include/config/auto.conf.cmd" \
          "$HDRS/include/generated/autoconf.h" 2>/dev/null || true
    echo "   -> host tools rebuilt for $(uname -m)"
fi

# --- 2. Build the BMI088 IMU + SPSC modules ----------------------------------
if modinfo -k "$KREL" bmi_spsc >/dev/null 2>&1 && modinfo -k "$KREL" bmi088 >/dev/null 2>&1 \
   && [ -f "$LOADER_MOD_DIR/bmi_spsc.ko" ]; then
    echo "[*] bmi088/bmi_spsc already installed for $KREL   skipping build"
else
    echo "[*] Building bmi088 + bmi_spsc against $KREL headers..."
    BUILD=/var/tmp/bmi088-build
    rm -rf "$BUILD"; cp -r "$BMI_SRC" "$BUILD"
    make -C "$BUILD" KDIR="/lib/modules/$KREL/build" >/dev/null
    VM=$(modinfo "$BUILD/bmi_spsc.ko" | awk -F': *' '/^vermagic:/{print $2}')
    echo "$VM" | grep -q "$KREL" || { echo "[!] vermagic mismatch: $VM"; exit 1; }
    mkdir -p "$LOADER_MOD_DIR"
    install -m 0644 "$BUILD/bmi_spsc.ko" "$BUILD/bmi088.ko" "$LOADER_MOD_DIR/"
    # Also under updates/ so plain modprobe works without the loader.
    UPD=/lib/modules/$KREL/updates/drivers/stereolabs/bmi088
    mkdir -p "$UPD"; install -m 0644 "$BUILD/bmi_spsc.ko" "$BUILD/bmi088.ko" "$UPD/"
    depmod -a
    echo "   -> installed to $LOADER_MOD_DIR (loader path) + updates/"
fi

# --- 3. Build + install the vendor daemons -----------------------------------
apt-get install -y -o DPkg::Lock::Timeout=600 qtbase5-dev cmake >/dev/null
declare -A BIN=( [driver_zed_loader]=ZEDX_Driver [zed_x_daemon]=ZEDX_Daemon [imu-daemon]=IMU_Daemon )
for d in driver_zed_loader zed_x_daemon imu-daemon; do
    bin="${BIN[$d]}"
    if [ -x "/usr/sbin/$bin" ]; then
        echo "[*] /usr/sbin/$bin already installed   skipping build"
        continue
    fi
    if [ -x "$DAEMON_CACHE/$bin" ]; then
        echo "[*] Installing $bin from prebuilt cache..."
        install -m 0755 "$DAEMON_CACHE/$bin" "/usr/sbin/$bin"
        continue
    fi
    echo "[*] Building $d..."
    B="/var/tmp/build-$d"
    rm -rf "$B"; mkdir -p "$B"
    ( cd "$B" && cmake -DRT_L4T_VERSION=36 -DCMAKE_BUILD_TYPE=Release \
          "$VENDOR/Daemon/$d" >/dev/null && make -j"$(nproc)" >/dev/null )
    install -m 0755 "$B/$bin" "/usr/sbin/$bin"
done
install -m 0644 "$VENDOR/Daemon/driver_zed_loader/driver_zed_loader.service" /etc/systemd/system/
install -m 0644 "$VENDOR/Daemon/zed_x_daemon/zed_x_daemon.service" /etc/systemd/system/
install -m 0644 "$VENDOR/Daemon/imu-daemon/IMU_Daemon.service" /etc/systemd/system/

# --- 3b. ISP image-quality fix (libnvisppg) ----------------------------------
# Stock R36.4.x libnvisppg.so (NVIDIA's ISP post-processing lib) produces a
# soft, not-crisp image on the ZED X. Stereolabs ships a patched build under
# nvidia_364_fix/<L4T>/ (same fix their support hands out via the zedbox .deb).
# dpkg-divert keeps the swap alive across nvidia-l4t-camera apt upgrades.
ISP_FIX="$VENDOR/nvidia_364_fix/R36.4.3/libnvisppg.so"
ISP_LIB=/usr/lib/aarch64-linux-gnu/nvidia/libnvisppg.so
if [ -f "$ISP_FIX" ]; then
    if [ "$(md5sum < "$ISP_FIX")" != "$(md5sum < "$ISP_LIB" 2>/dev/null)" ]; then
        echo "[*] Installing patched libnvisppg.so (ISP image-quality fix)..."
        dpkg-divert --add --rename --divert "$ISP_LIB.stock" "$ISP_LIB" 2>/dev/null || true
        install -m 0644 -o root -g root "$ISP_FIX" "$ISP_LIB"
        ldconfig
        systemctl restart nvargus-daemon 2>/dev/null || true
        echo "   -> patched lib installed (stock diverted to libnvisppg.so.stock)"
    else
        echo "[*] Patched libnvisppg.so already installed   skipping"
    fi
else
    echo "   [WARN] $ISP_FIX not found   image may look soft (see DRIVERS.md §1.6)"
fi

# --- 4. Device access for the zed group --------------------------------------
groupadd -f zed
printf 'KERNEL=="spsc_bmi*", GROUP="zed", MODE="0660"\n' > /etc/udev/rules.d/99-zed-spsc.rules
udevadm control --reload-rules 2>/dev/null || true

# --- 5. Enable + start the chain ---------------------------------------------
systemctl daemon-reload
systemctl enable driver_zed_loader.service zed_x_daemon.service IMU_Daemon.service >/dev/null 2>&1
systemctl restart driver_zed_loader.service
sleep 3
systemctl restart zed_x_daemon.service IMU_Daemon.service
sleep 2

# --- 6. Smoke test -------------------------------------------------------------
lsmod | grep -q '^bmi088' && echo "   -> bmi088 loaded" || echo "   [WARN] bmi088 not loaded"
[ -e /dev/spsc_bmi0 ] && echo "   -> /dev/spsc_bmi0 present" || echo "   [WARN] no SPSC device (camera attached?)"
if [ -f /opt/av-env/bin/python ]; then
    /opt/av-env/bin/python - <<'PY' || echo "   [WARN] SDK open failed"
import pyzed.sl as sl
c = sl.Camera(); p = sl.InitParameters(); p.depth_mode = sl.DEPTH_MODE.NONE
e = c.open(p)
print("   -> SDK open:", e)
if e == sl.ERROR_CODE.SUCCESS:
    print("   -> camera:", c.get_camera_information().camera_model)
    c.close()
PY
fi

echo "==========================================="
echo " ZED X SPSC/daemon install complete."
echo "==========================================="
