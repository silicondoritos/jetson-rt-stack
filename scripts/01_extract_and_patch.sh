#!/bin/bash
set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/config.sh"
. "$HERE/lib/log.sh"
. "$HERE/lib/plugin.sh"

echo "==========================================="
echo " AV Kernel Phase 1: Extraction & Patching"
echo "==========================================="

mkdir -p "$BUILD_WORKSPACE"
cd "$BUILD_WORKSPACE"

# =============================================================================
# L4T BSP
# =============================================================================
if [ ! -d "Linux_for_Tegra" ]; then
    echo "[*] Extracting L4T Driver Package..."
    tar xf "$TARBALL_L4T_PATH"
else
    echo "[-] Linux_for_Tegra already exists, skipping L4T extraction."
fi

# =============================================================================
# RootFS
# =============================================================================
if [ ! -d "Linux_for_Tegra/rootfs/bin" ]; then
    echo "[*] Populating root filesystem (requires sudo)..."
    if sudo -n true 2>/dev/null; then
        sudo tar xpf "$TARBALL_ROOTFS_PATH" -C Linux_for_Tegra/rootfs/
    else
        echo ""
        echo "[!] ============================================================"
        echo "[!] MANUAL STEP REQUIRED   sudo unavailable for automation."
        echo "[!] Run this command, then re-run make extract:"
        echo "[!]"
        echo "[!]   sudo tar xpf $TARBALL_ROOTFS_PATH \\"
        echo "[!]       -C $BUILD_WORKSPACE/Linux_for_Tegra/rootfs/"
        echo "[!] ============================================================"
        echo ""
        exit 1
    fi
else
    echo "[-] rootfs already populated, skipping."
fi

# =============================================================================
# Public Sources
# =============================================================================
sudo chown -R "$(id -u):$(id -g)" Linux_for_Tegra/source || true

if [ ! -d "Linux_for_Tegra/source/kernel/kernel-jammy-src" ]; then
    echo "[*] Extracting public sources..."
    tar xf "$TARBALL_PUBLIC_SOURCES_PATH" -C .
    cd Linux_for_Tegra/source
    tar xf kernel_src.tbz2
    tar xf kernel_oot_modules_src.tbz2
    tar xf nvidia_kernel_display_driver_source.tbz2
    cd ../..
else
    echo "[-] Sources already extracted, skipping."
fi

# =============================================================================
# Plugin hooks   vendor source injection (ZED X, Axelera, custom)
# Each plugin checks its own CONFIG_ guards internally.
# =============================================================================
load_plugins
run_hook post_extract

# =============================================================================
# Core AV kernel defconfig injection
# Vendor-specific CONFIG_ symbols are appended by plugin post_defconfig hooks.
# =============================================================================
DEFCONFIG="Linux_for_Tegra/source/kernel/kernel-jammy-src/arch/arm64/configs/defconfig"

if ! grep -q "CONFIG_PREEMPT_RT=y" "$DEFCONFIG" && \
   ! grep -q "# AV KERNEL" "$DEFCONFIG"; then
    echo "[*] Injecting AV kernel configuration..."

    # --- Preemption model ---
    PREEMPT_RT_BLOCK=""
    if [ "${CONFIG_KERNEL_PREEMPT_RT:-y}" = "y" ]; then
        # generic_rt_build.sh owns CONFIG_PREEMPT_RT (it runs after this
        # injection); setting it here too caused double-ownership drift.
        PREEMPT_RT_BLOCK=""
    elif [ "${CONFIG_KERNEL_PREEMPT_DYNAMIC:-n}" = "y" ]; then
        PREEMPT_RT_BLOCK="CONFIG_PREEMPT_DYNAMIC=y"
    fi
    # (stock PREEMPT is the kernel default   no explicit injection needed)

    # --- CPU isolation (only with RT) ---
    LOW_JITTER_BLOCK=""
    if [ "${CONFIG_LOW_JITTER:-y}" = "y" ] && [ "${CONFIG_KERNEL_PREEMPT_RT:-y}" = "y" ]; then
        LOW_JITTER_BLOCK="CONFIG_NO_HZ_FULL=y
CONFIG_CPU_ISOLATION=y
CONFIG_RCU_NOCB_CPU=y
CONFIG_IRQ_FORCED_THREADING=y"
    fi

    # --- CMA size ---
    CMA_MBYTES="${CONFIG_CMA_SIZE_MBYTES:-2048}"

    cat >> "$DEFCONFIG" <<EOF

# =============================================================
# AV KERNEL: Real-Time Core
# =============================================================
${PREEMPT_RT_BLOCK}
${LOW_JITTER_BLOCK}
CONFIG_HZ_1000=y
# CONFIG_HZ_250 is not set
CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE=y
# CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL is not set

# =============================================================
# AV KERNEL: CMA   contiguous memory for 4K stereo AI buffers
# Also set cma=NM in extlinux.conf boot args (belt+suspenders)
# =============================================================
CONFIG_CMA_SIZE_MBYTES=${CMA_MBYTES}

# =============================================================
# AV KERNEL: HugePages for AI/Vision buffer performance
# =============================================================
CONFIG_HUGETLB_PAGE=y

# =============================================================
# AV KERNEL: Armv8.5-A silicon features
# =============================================================
CONFIG_ARM64_PTR_AUTH=y
CONFIG_ARM64_BTI=y
CONFIG_ARM64_BTI_KERNEL=y
CONFIG_CRYPTO_AES_ARM64_CE=y
CONFIG_CRYPTO_SHA512_ARM64=y
CONFIG_KERNEL_MODE_NEON=y

# =============================================================
# AV KERNEL: Aerospace hardening & resiliency
# =============================================================
CONFIG_EDAC=y
CONFIG_EDAC_TEGRA=y
CONFIG_PSTORE=y
CONFIG_PSTORE_RAM=y
CONFIG_SOFT_WATCHDOG=y
CONFIG_HARDLOCKUP_DETECTOR=y

# =============================================================
# AV KERNEL: Network   ROS 2 DDS multicast + low-latency QoS
# =============================================================
CONFIG_NET_SCH_FQ=m
CONFIG_NET_SCH_FQ_CODEL=m

# =============================================================
# AV KERNEL: Wi-Fi   Realtek RTL8822CE (M.2 Key E)
# Full enablement pinned explicitly: vendor menu + core + PCI transport +
# the 8822C chip family + the 8822CE PCIe variant, over cfg80211/mac80211.
# =============================================================
CONFIG_WLAN=y
CONFIG_WLAN_VENDOR_REALTEK=y
CONFIG_CFG80211=m
CONFIG_MAC80211=m
CONFIG_RTW88=m
CONFIG_RTW88_CORE=m
CONFIG_RTW88_PCI=m
CONFIG_RTW88_8822C=m
CONFIG_RTW88_8822CE=m

# =============================================================
# AV KERNEL: PCIe ASPM   stock parity in code (=y); the Axelera
# sub-microsecond wake policy is enforced at runtime via the
# pcie_aspm=off kernel cmdline arg (see versions.env RT_BOOT_ARGS).
# =============================================================
CONFIG_PCIEASPM=y
CONFIG_PCIEASPM_DEFAULT=y

# =============================================================
# AV KERNEL: PCIe Advanced Error Reporting (AER)
# =============================================================
CONFIG_PCIEPORTBUS=y
CONFIG_PCIEAER=y
CONFIG_PCIE_DPC=y
CONFIG_PCIEAER_INJECT=m

# =============================================================
# AV KERNEL: Strip debug overhead   no jitter sources
# =============================================================
# CONFIG_KASAN is not set
# CONFIG_PROVE_LOCKING is not set
# CONFIG_DEBUG_LOCKDEP is not set
# CONFIG_SLUB_DEBUG is not set
# CONFIG_KMEMLEAK is not set
# CONFIG_FUNCTION_GRAPH_TRACER is not set
# CONFIG_DYNAMIC_FTRACE is not set
# CONFIG_SCHED_DEBUG is not set

# =============================================================
# AV KERNEL: Filesystem extras
# =============================================================
CONFIG_FUSE_FS=m
CONFIG_VFAT_FS=y
CONFIG_NTFS_FS=m

# =============================================================
# AV KERNEL: RT depth   high-res timers, RCU boost
# =============================================================
CONFIG_HIGH_RES_TIMERS=y
CONFIG_HZ=1000
CONFIG_RCU_BOOST=y
CONFIG_RCU_BOOST_DELAY=500
# CONFIG_PREEMPT_DYNAMIC is not set
# CONFIG_NO_HZ_IDLE is not set
# CONFIG_NUMA_BALANCING is not set
# CONFIG_SCHED_AUTOGROUP is not set
# CONFIG_LATENCYTOP is not set

# =============================================================
# AV KERNEL: Memory & cache for AI buffers
# =============================================================
# NOTE: TRANSPARENT_HUGEPAGE is Kconfig-blocked under PREEMPT_RT on 5.15
# ('depends on ... && !PREEMPT_RT'): any THP line here is a silent no-op,
# so none is set. jetson_rt_tune.sh treats the THP sysfs as best-effort.
CONFIG_USERFAULTFD=y
CONFIG_PAGE_REPORTING=y
# CONFIG_ZSWAP is not set
# CONFIG_ZRAM is not set

# =============================================================
# AV KERNEL: cgroups v2   core/memory partitioning
# =============================================================
CONFIG_CGROUPS=y
CONFIG_CGROUP_SCHED=y
CONFIG_CGROUP_CPUACCT=y
CONFIG_CPUSETS=y
CONFIG_CGROUP_DEVICE=y
CONFIG_CGROUP_FREEZER=y
CONFIG_CGROUP_PIDS=y
CONFIG_CGROUP_BPF=y
CONFIG_MEMCG=y
CONFIG_MEMCG_SWAP=y

# =============================================================
# AV KERNEL: Networking   ROS 2 DDS, MAVROS, BBR
# =============================================================
CONFIG_TCP_CONG_BBR=m
CONFIG_DEFAULT_TCP_CONG="bbr"
CONFIG_NET_FOU=m
CONFIG_BPF_JIT=y
CONFIG_BPF_JIT_ALWAYS_ON=y
CONFIG_XDP_SOCKETS=y
# NOTE: NET_RX_BUSY_POLL is promptless and forced off by PREEMPT_RT
# ('default y if !PREEMPT_RT'): busy-poll is unavailable on RT kernels.

# =============================================================
# AV KERNEL: I/O   NVMe, async I/O, USB-serial for FCU + modems
# =============================================================
# Build the NVMe root chain (NVMe + Tegra PCIe host + PCIe PHY) IN (=y), not as
# modules. The rootfs lives on NVMe-over-PCIe, so building these =y takes the
# initrd module-load step out of the root-mount path entirely (and with it the
# whole vermagic-matching fragility for the boot-critical modules). On the
# PREEMPT_RT kernel this was the difference between a hang in early boot and a
# clean mount. See docs/TROUBLESHOOTING.md F-6.
CONFIG_PCIE_TEGRA194=y
CONFIG_PCIE_TEGRA194_HOST=y
CONFIG_PHY_TEGRA194_P2U=y
CONFIG_NVME_CORE=y
CONFIG_BLK_DEV_NVME=y
CONFIG_BLK_MQ_PCI=y
CONFIG_NVME_MULTIPATH=y
CONFIG_NVME_HWMON=y
CONFIG_IO_URING=y
CONFIG_USB_ANNOUNCE_NEW_DEVICES=y
CONFIG_USB_SERIAL_FTDI_SIO=m
CONFIG_USB_SERIAL_CP210X=m
CONFIG_USB_ACM=m
CONFIG_USB_USBNET=m
CONFIG_USB_NET_RNDIS_HOST=m
CONFIG_USB_NET_CDCETHER=m

# =============================================================
# AV KERNEL: Security & hardening
# =============================================================
CONFIG_HARDENED_USERCOPY=y
CONFIG_FORTIFY_SOURCE=y
CONFIG_STACKPROTECTOR_STRONG=y
CONFIG_RANDOMIZE_BASE=y
CONFIG_RANDOMIZE_MODULE_REGION_FULL=y
CONFIG_INIT_STACK_ALL_ZERO=y
# CONFIG_DEVMEM is not set
# CONFIG_LEGACY_PTYS is not set

# =============================================================
# AV KERNEL: Module discipline   vermagic + symbol CRC enforcement
# =============================================================
CONFIG_MODVERSIONS=y
CONFIG_MODULE_SRCVERSION_ALL=y
# CONFIG_MODULE_FORCE_LOAD is not set

# =============================================================
# AV KERNEL: Platform resilience   kdump, LSM, TPM
# =============================================================
CONFIG_KEXEC=y
CONFIG_KEXEC_FILE=y
CONFIG_CRASH_DUMP=y
CONFIG_PROC_VMCORE=y
CONFIG_SECURITY=y
CONFIG_SECURITY_YAMA=y
CONFIG_SECURITY_LOCKDOWN_LSM=y
# =============================================================
# AV KERNEL: AppArmor   snapd/snaps (Chromium etc.) REQUIRE an active
# apparmor LSM; omitting it from CONFIG_LSM silently dropped
# CONFIG_SECURITY_APPARMOR from the build entirely and broke every snap.
# SELinux stays built (stock parity) but must NOT be the default.
# =============================================================
CONFIG_AUDIT=y
CONFIG_SECURITY_APPARMOR=y
CONFIG_SECURITY_APPARMOR_HASH=y
CONFIG_SECURITY_APPARMOR_HASH_DEFAULT=y
CONFIG_DEFAULT_SECURITY_APPARMOR=y
# CONFIG_DEFAULT_SECURITY_SELINUX is not set
CONFIG_LSM="lockdown,yama,integrity,apparmor"
CONFIG_TCG_TPM=y
CONFIG_TCG_TIS=y
CONFIG_HW_RANDOM_TPM=y

# =============================================================
# AV KERNEL: Strip remaining debug overhead
# =============================================================
# CONFIG_FUNCTION_TRACER is not set
# CONFIG_DEBUG_PREEMPT is not set
# CONFIG_DEBUG_RT_MUTEXES is not set
# CONFIG_PROVE_RCU is not set
# CONFIG_TIMER_STATS is not set
# CONFIG_DEBUG_VM is not set
# CONFIG_DEBUG_BUGVERBOSE is not set

# =============================================================
# AV KERNEL: Stock-parity pins   PREEMPT_RT requires EXPERT=y, which
# silently flips every 'default !EXPERT' symbol; pin them all back so
# the only deltas vs stock are the deliberate ones above. This restores
# the HDMI boot console (fbcon), menu cpuidle governor, rfkill-input,
# media autoselect (removes ~149 junk DVB/tuner modules), and basic HID.
# =============================================================
CONFIG_EXPERT=y
CONFIG_FRAMEBUFFER_CONSOLE=y
CONFIG_FRAMEBUFFER_CONSOLE_DETECT_PRIMARY=y
CONFIG_VT_HW_CONSOLE_BINDING=y
CONFIG_CPU_IDLE_GOV_MENU=y
CONFIG_DEBUG_MEMORY_INIT=y
CONFIG_RFKILL_INPUT=y
CONFIG_MEDIA_SUPPORT_FILTER=y
CONFIG_MEDIA_SUBDRV_AUTOSELECT=y
CONFIG_HID_A4TECH=y
CONFIG_HID_APPLE=y
CONFIG_HID_BELKIN=y
CONFIG_HID_CHERRY=y
CONFIG_HID_CHICONY=y
CONFIG_HID_CYPRESS=y
CONFIG_HID_EZKEY=y
CONFIG_HID_ITE=y
CONFIG_HID_KENSINGTON=y
CONFIG_HID_LOGITECH=y
CONFIG_HID_MICROSOFT=y
CONFIG_HID_MONTEREY=y
CONFIG_HID_REDRAGON=y
EOF
    echo "   -> AV kernel config injected."
else
    # Fix CMA even if block already present
    if grep -q "CONFIG_CMA_SIZE_MBYTES=32" "$DEFCONFIG"; then
        CMA_MBYTES="${CONFIG_CMA_SIZE_MBYTES:-2048}"
        sed -i "s/CONFIG_CMA_SIZE_MBYTES=32/CONFIG_CMA_SIZE_MBYTES=${CMA_MBYTES}/" "$DEFCONFIG"
        echo "[*] Fixed CMA_SIZE_MBYTES: 32 → ${CMA_MBYTES} MB."
    fi
    echo "[-] AV kernel config already present."
fi

# =============================================================================
# Plugin hooks   vendor CONFIG_ additions
# (ZED X deserializer, DMABUF symbols, CONFIG_AXELERA_METIS, etc.)
# =============================================================================
run_hook post_defconfig

# =============================================================================
# Enable PREEMPT_RT via NVIDIA's script (conditional on config)
# =============================================================================
if [ "${CONFIG_KERNEL_PREEMPT_RT:-y}" = "y" ]; then
    echo "[*] Enabling PREEMPT_RT via NVIDIA generic_rt_build.sh..."
    cd Linux_for_Tegra/source
    ./generic_rt_build.sh "enable"
    # The RT recipe sets EMBEDDED (whose only Kconfig effect is selecting
    # EXPERT, which the fragment pins directly) but EMBEDDED also kills
    # SECRETMEM ('def_bool ... && !EMBEDDED'). Drop it for stock parity.
    KSRC_REL="kernel/kernel-jammy-src"
    "./$KSRC_REL/scripts/config" --file "./$KSRC_REL/arch/arm64/configs/defconfig" \
        --disable EMBEDDED 2>/dev/null || true
    cd ../..
else
    echo "[*] Skipping PREEMPT_RT (CONFIG_KERNEL_PREEMPT_RT not set)"
fi

# =============================================================================
# Boot cmdline: explicit NVMe root= for the recovery / boot.img path
# =============================================================================
# p3767.conf.common's CMDLINE_ADD ships no root=, so the kernel inherits the board
# eMMC default (root=/dev/mmcblk0p1). An Orin NX booting from NVMe has no eMMC, so
# that device never appears and `rootwait` hangs FOREVER -- looks exactly like a
# freeze right after the NVIDIA logo. L4TLauncher's "Attempting Recovery Boot" path
# uses this baked-in cmdline (not extlinux), so the fix must live here too. The last
# root= on the cmdline wins, so appending it overrides the wrong default. The normal
# extlinux path gets its explicit root= from 03_bake_rootfs.sh. Idempotent.
# See docs/TROUBLESHOOTING.md F-4 and docs/FLASH.md.
ROOT_DEV="${TARGET_STORAGE_DEV:-nvme0n1p1}"
P3767_CONF="Linux_for_Tegra/p3767.conf.common"
if [ -f "$P3767_CONF" ] && ! grep -q "root=/dev/${ROOT_DEV}" "$P3767_CONF"; then
    echo "[*] Setting NVMe root=/dev/${ROOT_DEV} in $(basename "$P3767_CONF") CMDLINE_ADD..."
    sed -i "s|\(CMDLINE_ADD=\"[^\"]*\)\"|\1 root=/dev/${ROOT_DEV}\"|" "$P3767_CONF"
fi

# =============================================================================
# WiFi: power the M.2 Key-E (C1) PCIe slot so the RTL8822CE link trains
# =============================================================================
# Stock tegra234-p3768-0000.dtsi gives the C1 controller (pcie@14100000) NO
# vpcie3v3-supply, so the slot's 3.3V rail is never enabled and the WiFi card's
# PHY never powers up ("Phy link never came up" -> card absent from lspci -> no
# wlan interface). The gpio-gated rail vdd_3v3_pcie (gpio_aon AA.5) already
# exists in the same file and already feeds C8 (Ethernet). NVIDIA's own p3740
# WiFi reference platform wires this exact supply onto pcie@14100000. We add it
# to C1. The p2u_hsio_3 phy ref makes this match unique to C1; idempotent (the
# inserted line breaks the vddio->blank->phys pattern, so it won't re-fire).
# See docs/TROUBLESHOOTING.md (WiFi) and the C8 node above it for the template.
P3768_DTSI="Linux_for_Tegra/source/hardware/nvidia/t23x/nv-public/tegra234-p3768-0000.dtsi"
if [ -f "$P3768_DTSI" ]; then
    echo "[*] Adding vpcie3v3-supply to the M.2 Key-E (C1) node for WiFi..."
    perl -0777 -i -pe 's/(vddio-pex-ctl-supply = <&vdd_1v8_ao>;\n)\n(\t+phys = <&p2u_hsio_3>;)/${1}\t\t\tvpcie3v3-supply = <&vdd_3v3_pcie>;\n\n${2}/' "$P3768_DTSI"
fi

echo ""
echo "==========================================="
echo " Phase 1 Complete. Ready for Compilation."
echo "==========================================="
echo ""
echo " Next: make docker-build  (one-time, if not done)"
echo "       make build          (runs inside Docker)"
