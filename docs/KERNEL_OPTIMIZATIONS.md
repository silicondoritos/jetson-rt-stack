---
title: Kernel Options
layout: default
description: "Every CONFIG_* kernel flag in this build and the rationale behind each choice for PREEMPT_RT, DMABUF, CMA, and hardening."
nav_order: 14
---

# Kernel Optimizations

This document records every `CONFIG_*` flag this build sets beyond the NVIDIA stock
defconfig, grouped by domain, with the rationale and the cost/benefit on this hardware
(Jetson Orin NX 16GB, p3767-0000 module on a p3768 carrier, L4T R36.4.3 / JetPack 6.2).

`scripts/01_extract_and_patch.sh` appends these flags to
`arch/arm64/configs/defconfig` during Phase 1. Vendor flags for the ZED X deserializer,
DMABUF, and the Metis driver are appended later in the same phase by the Axelera and ZED X
plugin hooks (`plugins/axelera/plugin.sh`, `plugins/zedx/plugin.sh`). The build then
enables PREEMPT_RT through NVIDIA's `generic_rt_build.sh`.

The configuration is split into sixteen domains. Each domain below states its purpose and
the specific reasoning for the flags it sets.

Related pages: [KERNEL_PATCHES.md](KERNEL_PATCHES.md) documents the source-tree patches
these flags ride on, [RT_KERNEL_OPTIMIZATION.md](RT_KERNEL_OPTIMIZATION.md) covers the
runtime latency tuning loop, and [FINE_TUNING.md](FINE_TUNING.md) covers the per-boot
service knobs.

## 1. Real-Time Core (foundational)

```
CONFIG_PREEMPT_RT=y
CONFIG_NO_HZ_FULL=y
CONFIG_HZ_1000=y
CONFIG_CPU_ISOLATION=y
CONFIG_RCU_NOCB_CPU=y
CONFIG_IRQ_FORCED_THREADING=y
CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE=y
# CONFIG_CPU_FREQ_GOV_ONDEMAND is not set
# CONFIG_CPU_FREQ_GOV_CONSERVATIVE is not set
```

- **PREEMPT_RT**: makes spinlocks sleepable and threads IRQ handlers. This is the
  foundation for low-jitter scheduling on the isolated cores 1-5.
- **NO_HZ_FULL**: tickless operation on isolated cores; the scheduler timer interrupt does
  not fire on cores 1-5 while a single runnable task occupies the core.
- **HZ_1000**: 1 ms timer base.
- **CPU_ISOLATION**: kernel-level enforcement that the scheduler skips isolated cores.
- **RCU_NOCB_CPU**: RCU callback offload, which keeps RCU grace-period work off the RT
  cores.
- **IRQ_FORCED_THREADING**: every interrupt becomes a kernel thread that the stack can
  prioritise and pin.

The live kernel confirms this domain: `uname -v` reports `SMP PREEMPT_RT` and
`/sys/kernel/realtime` reads `1`.

## 2. ZED X Deserializer

```
CONFIG_SL_DESER_MAX9296=m
# CONFIG_SL_DESER_MAX96712 is not set
```

ZED Link Mono uses the MAX9296 GMSL2 deserializer. Selecting MAX96712 (a different chip)
produces silently corrupted frames with no error visible to userspace. See
[DRIVERS.md](DRIVERS.md) section 1 and [KERNEL_PATCHES.md](KERNEL_PATCHES.md) section 2.

## 3. DMABUF Zero-Copy Pipeline

```
CONFIG_SYNC_FILE=y
CONFIG_SW_SYNC=y
CONFIG_DMABUF_HEAPS=y
CONFIG_DMABUF_SYSFS_STATS=y
CONFIG_DMABUF_HEAPS_SYSTEM=y
CONFIG_DMABUF_HEAPS_CMA=y
CONFIG_CMA_SIZE_MBYTES=2048
```

The end-to-end byte path (ZED X to ISP to Metis NPU) is DMA-only by design. The
capture end is verified live (2026-06-11: 29.5 FPS stereo via pyzed, plus live
camera-to-Metis inference at 29.6 FPS); the zero-copy property itself (no CPU
memcpy on the hot path) still lacks a published dma_buf trace and remains a
design goal, not a verified claim.
`/dev/dma_heap/linux,cma` is the user-facing handle. `CONFIG_CMA_SIZE_MBYTES=2048` is a
kernel-config default only: on Orin the device-tree `linux,cma` node overrides it, so the
runtime pool is the DT-sized 256 MB pool (NVIDIA-sized, stock-proven), not 2 GB.

Do not pass a `cma=` boot argument. Live-verified on this hardware (2026-06-10):
`cma=2048M` on the kernel command line failed to reserve ("cma: Failed to reserve 2048
MiB"), and because a cmdline `cma=` bypasses the device-tree `linux,cma` pool, the system
ran with zero CMA. nvgpu requires a 64 MB physically contiguous comptag allocation at GPU
power-on (`ga10b_cbc_alloc_comptags`); with zero CMA that allocation fails ("DMA alloc
FAILED: [sysmem] size=64225280 ... PHYSICALLY_ADDRESSED"), cascading into "Unable to
recover GR falcon", FECS context switch init errors, no CUDA, no GPU devfreq, and nvpmodel
unable to set any power mode (it reads the GPU frequency table). With no `cma=` argument
the DT pool takes over and the GPU is fully healthy (see [FLASH.md](FLASH.md) and
`scripts/03_bake_rootfs.sh`). Whether 256 MB is sufficient for the dual-stereo pipeline is
unverified; if a larger pool is ever needed, resize the device-tree `linux,cma` node, never
the command line. Confirm the reservation landed at runtime:

```bash
grep CmaTotal /proc/meminfo    # expect: CmaTotal 262144 kB
```

See [DMABUF_ZEROCOPY.md](DMABUF_ZEROCOPY.md) for the full pipeline.

## 4. ARMv8.5-A Silicon Features

```
CONFIG_ARM64_PTR_AUTH=y
CONFIG_ARM64_BTI=y
CONFIG_ARM64_BTI_KERNEL=y
CONFIG_CRYPTO_AES_ARM64_CE=y
CONFIG_CRYPTO_SHA512_ARM64=y
CONFIG_KERNEL_MODE_NEON=y
```

Enables Pointer Authentication, Branch Target Identification, and hardware-accelerated
AES/SHA. These are low-cost hardening and acceleration features on the Cortex-A78AE cores.

## 5. Aerospace Hardening and Resiliency

```
CONFIG_EDAC=y
CONFIG_EDAC_TEGRA=y
CONFIG_PSTORE=y
CONFIG_PSTORE_RAM=y
CONFIG_SOFT_WATCHDOG=y
CONFIG_HARDLOCKUP_DETECTOR=y
```

ECC reporting, persistent crash logs that survive a reboot, and watchdogs. These are
essential for an aerial deployment where you cannot power-cycle the board to attach a
debugger.

## 6. RT Depth

```
CONFIG_HIGH_RES_TIMERS=y
CONFIG_HZ=1000
CONFIG_RCU_BOOST=y
CONFIG_RCU_BOOST_DELAY=500
# CONFIG_PREEMPT_DYNAMIC is not set
# CONFIG_NO_HZ_IDLE is not set
# CONFIG_NUMA_BALANCING is not set
# CONFIG_SCHED_AUTOGROUP is not set
# CONFIG_LATENCYTOP is not set
```

- **RCU_BOOST**: priority-inherits RCU readers when a higher-priority writer is starving.
  Without it, a low-priority task holding RCU can be preempted indefinitely, which produces
  multi-millisecond latency stalls.
- **PREEMPT_DYNAMIC off**: fixes the preemption model to PREEMPT_RT with no runtime
  switching.
- **NUMA_BALANCING off**: Orin NX is single-NUMA, so balancing only wastes cycles.
- **SCHED_AUTOGROUP off**: it interferes with the explicit cpuset and pinning policy.
- **LATENCYTOP off**: per-task latency tracking adds measurable overhead.

## 7. Memory and Cache

```
CONFIG_TRANSPARENT_HUGEPAGE=y
CONFIG_TRANSPARENT_HUGEPAGE_MADVISE=y
CONFIG_HUGETLB_PAGE=y
CONFIG_USERFAULTFD=y
CONFIG_PAGE_REPORTING=y
# CONFIG_ZSWAP is not set
# CONFIG_ZRAM is not set
```

- **THP_MADVISE**: huge pages are opt-in through `madvise()`, so DDS and Voyager can request
  them without forcing them on the whole system.
- **USERFAULTFD**: required for advanced UVM and live-migration patterns.
- **ZSWAP/ZRAM off**: compression in the swap path introduces latency that is not acceptable
  under RT.

## 8. cgroups v2

```
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
```

Required for the `systemd-run --scope -p AllowedCPUs=4-5 ...` style pinning that the AV
stack scripts use for cuVSLAM (cores 4-5) and the Metis runtime (core 1). The AV stack
itself (ROS 2, Isaac ROS) is installed and verified live on the reference device (2026-06-11);
see [AV_STACK.md](AV_STACK.md).

## 9. Networking

```
CONFIG_NET_SCH_FQ=m
CONFIG_NET_SCH_FQ_CODEL=m
CONFIG_TCP_CONG_BBR=m
CONFIG_DEFAULT_TCP_CONG="bbr"
CONFIG_NET_FOU=m
CONFIG_BPF_JIT=y
CONFIG_BPF_JIT_ALWAYS_ON=y
CONFIG_XDP_SOCKETS=y
CONFIG_NET_RX_BUSY_POLL=y
```

- **FQ / FQ_CODEL**: fair-queue schedulers; `jetson_rt_tune.sh` switches the primary NIC to
  `fq` so DDS multicast does not starve.
- **BBR**: congestion control tuned for telemetry tunneling.
- **BPF_JIT** and **XDP_SOCKETS**: zero-copy packet I/O for future use, for example
  AF_XDP-based LiDAR ingest.
- **RX_BUSY_POLL**: low-latency receive at the cost of CPU; `jetson_rt_tune.sh` governs which
  NIC uses it.

## 10. I/O

```
CONFIG_BLK_MQ_PCI=y
CONFIG_NVME_MULTIPATH=y
CONFIG_NVME_HWMON=y
CONFIG_IO_URING=y
CONFIG_USB_ANNOUNCE_NEW_DEVICES=y
CONFIG_USB_SERIAL_FTDI_SIO=m
CONFIG_USB_SERIAL_CP210X=m
```

- **NVME_HWMON**: NVMe temperature monitoring for thermal-throttling decisions.
- **IO_URING**: asynchronous I/O for Isaac ROS bag recording.
- **CP210X / FTDI_SIO**: USB-serial bridges for the flight controller and modem
  peripherals.

The NVMe root chain (`CONFIG_BLK_DEV_NVME`, `CONFIG_NVME_CORE`, `CONFIG_PCIE_TEGRA194`,
`CONFIG_PCIE_TEGRA194_HOST`, `CONFIG_PHY_TEGRA194_P2U`) is built in (`=y`), not as modules,
so the root mount does not depend on loading modules from the initrd. See
[KERNEL_PATCHES.md](KERNEL_PATCHES.md) and [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## 11. Wi-Fi and Module Discipline

```
CONFIG_RTW88=m
CONFIG_RTW88_8822CE=m

CONFIG_MODVERSIONS=y
CONFIG_MODULE_SRCVERSION_ALL=y
# CONFIG_MODULE_FORCE_LOAD is not set
```

- **RTW88_8822CE**: in-kernel driver for the Realtek RTL8822CE M.2 Key E module. The bake
  stage blacklists the in-kernel `rtw88` driver, stages the vendor `rtl8822ce` driver out
  of boot autoload by default (set `WIFI_AUTOLOAD=1` to autoload it at boot), and stages a
  NetworkManager auto-connect profile. Manual bring-up: `sudo modprobe rtl8822ce`, then
  verify with `nmcli device status` and `iw dev`.
- **MODVERSIONS** and **SRCVERSION_ALL**: per-symbol CRC checks, stricter than vermagic
  alone. See [VERMAGIC_STRATEGY.md](VERMAGIC_STRATEGY.md).
- **MODULE_FORCE_LOAD off**: removes the `insmod --force` escape hatch.

## 12. Hardening (no RT cost)

```
CONFIG_HARDENED_USERCOPY=y
CONFIG_FORTIFY_SOURCE=y
CONFIG_STACKPROTECTOR_STRONG=y
CONFIG_RANDOMIZE_BASE=y
CONFIG_RANDOMIZE_MODULE_REGION_FULL=y
CONFIG_INIT_STACK_ALL_ZERO=y
# CONFIG_DEVMEM is not set
# CONFIG_DEVKMEM is not set
# CONFIG_LEGACY_PTYS is not set
```

KASLR, fortify-source, hardened user-copy, and stack zeroing. `/dev/mem` and `/dev/kmem` are
disabled: they have no legitimate use on a sealed AV platform and are a
privilege-escalation primitive.

## 13. Driver In-Tree Promotions

```
CONFIG_AXELERA_METIS=m
CONFIG_VIDEO_ZEDX=m
CONFIG_VIDEO_ZEDX_AR0234=m
CONFIG_VIDEO_ZEDX_IMX678=m
```

These flip on the in-tree Kconfig stubs that the Axelera and ZED X plugins generate under
`drivers/misc/axelera/` and `drivers/media/i2c/zedx/` during Phase 1. The Metis driver is
verified live: the NPU enumerates on PCIe (`0004:01:00.0`) bound to the `metis` driver. The
ZED X driver builds in-tree and the device-tree overlay is staged; end-to-end capture is
verified live (2026-06-11: 29.5 FPS stereo + CUDA depth via pyzed), and the measured
camera-plus-NPU throughput matrix is in [BENCHMARKS.md](BENCHMARKS.md). The ZED SDK userspace is
a separate on-device install (see [DRIVERS.md](DRIVERS.md) §1.5, §2). See [VERMAGIC_STRATEGY.md](VERMAGIC_STRATEGY.md) for why these
must share the kernel's PREEMPT_RT vermagic.

## 14. PCIe Power Management

```
# CONFIG_PCIEASPM is not set
```

Disables PCIe Active State Power Management at compile time. The Axelera Metis cannot wake
from L1 sleep without 10 to 50 µs of latency, which matters when inference runs every frame.
Enforcement is three-layer: this compile-time flag, `pcie_aspm=off` in the boot args, and
`jetson_rt_tune.sh` forcing `/sys/bus/pci/devices/*/power/control` to `on`.

## 15. Debug Strip (no jitter sources)

```
# CONFIG_KASAN is not set
# CONFIG_PROVE_LOCKING is not set
# CONFIG_DEBUG_LOCKDEP is not set
# CONFIG_SLUB_DEBUG is not set
# CONFIG_KMEMLEAK is not set
# CONFIG_FUNCTION_GRAPH_TRACER is not set
# CONFIG_DYNAMIC_FTRACE is not set
# CONFIG_SCHED_DEBUG is not set
# CONFIG_FUNCTION_TRACER is not set
# CONFIG_DEBUG_PREEMPT is not set
# CONFIG_DEBUG_RT_MUTEXES is not set
# CONFIG_PROVE_RCU is not set
# CONFIG_TIMER_STATS is not set
# CONFIG_DEBUG_VM is not set
# CONFIG_DEBUG_BUGVERBOSE is not set
```

Each of these adds 1 to 10 µs of measurable jitter through tracing hooks, locking
instrumentation, or memory-allocation poisoning. None are worth that cost on a deployed
system. Rebuild with them on only when chasing a specific bug.

## 16. Filesystem Extras

```
CONFIG_FUSE_FS=m
CONFIG_VFAT_FS=m
CONFIG_NTFS_FS=m
```

For mounting external SD and USB storage written by Windows-based ground control. `FUSE_FS`
covers any user-space filesystem plumbing.

---

## Verification

After Phase 2, the audit gate (`scripts/pre_flash_audit.sh`) checks the most critical of
these flags end to end. To inspect a specific flag manually:

```bash
# Inspect the staged defconfig
grep CONFIG_RCU_BOOST \
    latest_jetson/Linux_for_Tegra/source/kernel/kernel-jammy-src/arch/arm64/configs/defconfig

# Confirm the built kernel image was produced (post-build)
zcat latest_jetson/Linux_for_Tegra/kernel/Image \
    | strings | grep -m1 "Linux version"
```

On the running Jetson:

```bash
uname -v                                          # expect: SMP PREEMPT_RT
cat /sys/kernel/realtime                          # expect: 1
zcat /proc/config.gz | grep CONFIG_PREEMPT_RT
zcat /proc/config.gz | grep CONFIG_CMA_SIZE_MBYTES  # kernel-config default only; the DT linux,cma pool wins
```

`/proc/config.gz` is available because `CONFIG_IKCONFIG=y` and `CONFIG_IKCONFIG_PROC=y`.
