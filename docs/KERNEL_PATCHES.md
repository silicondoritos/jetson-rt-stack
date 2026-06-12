---
title: Kernel Patches
layout: default
description: "All patches applied to the L4T R36.4.3 kernel source: PCIe retries, MAX9296 deserializer, ZED X overlay, Metis in-tree promotion."
nav_order: 13
---

# Kernel Patches and Source Modifications

This page documents every modification this build makes to the stock L4T R36.4.3 kernel source. Read it when you need to know exactly what changes in NVIDIA's tree and why. [scripts/01_extract_and_patch.sh](../scripts/01_extract_and_patch.sh) applies the source-tree patches (Phase 1); [scripts/02_build_kernel.sh](../scripts/02_build_kernel.sh) applies the build-time steps that depend on a compiled tree, such as the ZED X overlay (Phase 2). Every operation is idempotent and safe to re-run on an existing workspace.

Related pages: [KERNEL_OPTIMIZATIONS.md](KERNEL_OPTIMIZATIONS.md) catalogues the defconfig knobs these patches enable, [RT_KERNEL_OPTIMIZATION.md](RT_KERNEL_OPTIMIZATION.md) covers the runtime latency tuning loop, and [FINE_TUNING.md](FINE_TUNING.md) covers the per-boot service knobs.

The vendor driver trees and the Voyager SDK are proprietary and not part of this repository: the Stereolabs ZED X tree is NDA-gated, while the Axelera Metis driver and Voyager SDK need only an Axelera customer-portal account (no NDA). See [DRIVERS.md](DRIVERS.md) for acquisition steps. The plugin glue that injects them lives in [plugins/axelera/plugin.sh](../plugins/axelera/plugin.sh) and [plugins/zedx/plugin.sh](../plugins/zedx/plugin.sh).

---

## 1. PCIe Link-Training Patience Patch (critical)

**File**: [pcie-designware.h](../latest_jetson/Linux_for_Tegra/source/kernel/kernel-jammy-src/drivers/pci/controller/dwc/pcie-designware.h) (`drivers/pci/controller/dwc/`)

```c
// Stock NVIDIA: 10 retries (~0.9 s), too short for a slow PCIe endpoint
#define LINK_WAIT_MAX_RETRIES  10

// This build: 200 retries (~18 s)
#define LINK_WAIT_MAX_RETRIES  200
```

The retry count governs how long the DesignWare PCIe core waits for an endpoint to train its link. The longer ceiling is for Axelera Metis link-training reliability, and it is verified on device (2026-06-10): the Metis enumerates at `1f9d:1100` on lanes 4-7 and `metis.ko` loads. A slot whose card trains early links up early; the longer ceiling only lengthens boot for a genuinely empty slot.

The value is applied in two steps by [`_axelera_pcie_patch`](../plugins/axelera/plugin.sh) in Phase 1:

1. If `voyager-sdk/axl-jetson.patch` is present, it is applied first (it sets the macro to an intermediate value).
2. A `sed` then forces the macro to the value pinned in [versions.env](../versions.env) (`PCIE_LINK_WAIT_MAX_RETRIES=200`), regardless of whether the vendor patch ran.

The `sed` consumes all whitespace and the full value (`([[:space:]]+[0-9]+)+`) because L4T aligns the macro with multiple tabs. A narrower pattern matched only the first tab and left a stray second value on the line, which is a compile error. The substitution is idempotent: re-running collapses any prior result back to a single value.

> The pinned value (200) is enforced at flash time by [scripts/pre_flash_audit.sh](../scripts/pre_flash_audit.sh), which compares the header against `PCIE_LINK_WAIT_MAX_RETRIES` and aborts on a mismatch.

---

## 2. ZED X MAX9296 Deserializer Fix (critical, frame integrity)

The ZED Link Mono adapter uses a **MAX9296** GMSL2 deserializer. The stock Stereolabs build selects the MAX96712, a different chip. The wrong driver produces silently corrupted frames with no error visible to userspace.

**R36.4.3 structure** (Kconfig-driven, no top-level `stereolabs/Makefile`). Two changes are required.

**1. Kernel defconfig** ([defconfig](../latest_jetson/Linux_for_Tegra/source/kernel/kernel-jammy-src/arch/arm64/configs/defconfig), `arch/arm64/configs/`):

```
CONFIG_SL_DESER_MAX9296=m
# CONFIG_SL_DESER_MAX96712 is not set
```

Added as part of the AV kernel config block (Section 7).

**2. Compiler flag** (`source/stereolabs/drivers/Makefile`):

```makefile
# before
subdir-ccflags-y += -DCONFIG_SL_DESER_MAX96712
# after
subdir-ccflags-y += -DCONFIG_SL_DESER_MAX9296
```

Applied with `sed` in Phase 1 by [`zedx_post_extract`](../plugins/zedx/plugin.sh). The substitution direction follows the camera selection: `CONFIG_CAMERA_ZEDX_MONO` swaps MAX96712 to MAX9296; `CONFIG_CAMERA_ZEDX_DUO` does the reverse.

> **Note**: In L4T R35.x and earlier, the fix lived in a top-level `stereolabs/Makefile` (`export CONFIG_SL_DESER_MAX96712=m` changed to `MAX9296`). That file does not exist in R36.4.3; the selection moved to Kconfig. Older docs or scripts that reference `stereolabs/Makefile` do not apply to this build.

---

## 3. ZED X R36.4 Kernel Patches

**Source**: `zedx-driver/nvidia_kernel/kernel_patches/R36.4/0*.patch` (the branch is derived from `L4T_VERSION`).

Applied with `patch -p2 -N` (the `-N` skips already-applied patches). The `zedbox` variants are excluded; this build targets **ZED Link Mono** only. The patches integrate the ZED X driver sources and Makefiles into the NVIDIA kernel out-of-tree (OOT) build layout.

The `*compilation_makefile*` patch creates `source/stereolabs/Makefile` and `Makefile-dkms` from `/dev/null`, which `patch -p2` cannot map onto our `source/stereolabs/` copy. Phase 1 materializes those two files directly at the correct path with an `awk` extraction. See [plugins/zedx/plugin.sh](../plugins/zedx/plugin.sh).

---

## 4. ZED X Driver Injection

**Source directory** to **destination in the kernel tree**:

| Source | Destination |
|--------|-------------|
| `zedx-driver/src/kernel/stereolabs/` | `source/stereolabs/` |
| `zedx-driver/src/hardware/stereolabs/` | `source/hardware/stereolabs/` |
| `zedx-driver/src/hardware/stereolabs/overlay/*.dts` | `source/hardware/nvidia/t23x/nv-public/` |
| `zedx-driver/src/hardware/stereolabs/overlay/*.dtsi` | `source/hardware/nvidia/t23x/nv-public/` |
| `zedx-driver/src/hardware/stereolabs/Utils/` | `source/hardware/nvidia/t23x/nv-public/Utils/` |

The overlay DTS files are relocated into `nv-public/` directly to avoid recursion limits in NVIDIA's OOT DTS build system. The overlays `#include "Utils/camera-clks.dtsi"` and `"Utils/<sensor>-sl-modes.dtsi"` relative to their own location, so the `Utils/` tree must sit beside them in `nv-public/`. A missing `Utils/` makes the overlay build fail with a bare "No such file" deep inside the preprocessor.

---

## 5. nv-public Makefile dtbo-y Correction

**File**: `source/hardware/nvidia/t23x/nv-public/Makefile`

The ZED X R36.4 patches register overlay targets as `dtbo-y += $(makefile-path)/...`. The `nv-public/Makefile` also runs an `addprefix $(makefile-path)/` block unconditionally, producing a double-prefix path (`t23x/nv-public/t23x/nv-public/...`) that the build system cannot resolve, so the DTBO silently builds nothing.

Phase 1 applies a `sed` correction after patching:

```bash
# Strip the pre-set $(makefile-path)/ from dtbo-y entries so the
# addprefix block adds it exactly once.
sed -i 's|dtbo-y += \$(makefile-path)/\(.*-sl-overlay\.dtbo\)|dtbo-y += \1|g' \
    Linux_for_Tegra/source/hardware/nvidia/t23x/nv-public/Makefile
```

> **Note**: Even with the corrected path, the NVIDIA `kernel-devicetree` build system never compiles `dtbo-y` targets. Section 8 explains the direct `dtc` workaround.

---

## 6. Axelera Metis Driver: In-Tree Promotion

**Source**: `axelera-driver/` synced into `source/axelera/axelera-driver/`.

The vendor source is rsynced into `source/axelera/axelera-driver/` and then promoted to in-tree by writing a Kconfig and Kbuild stub under `drivers/misc/axelera/` in the kernel tree:

```
drivers/misc/axelera/
├── Kconfig                   defines CONFIG_AXELERA_METIS
├── Makefile                  obj-$(CONFIG_AXELERA_METIS) += metis-wrapper/
├── metis-src                 symlink to source/axelera/axelera-driver/
└── metis-wrapper/
    └── Makefile              include $(VENDOR_DIR)/Makefile
```

The kernel's own `make modules` discovers the new sub-tree, recurses through the wrapper, and invokes the vendor Makefile under our `CROSS_COMPILE`, `ARCH`, and `KERNEL_HEADERS`. The resulting `metis.ko` shares an identical vermagic with the kernel: no DKMS, no toolchain drift. See [VERMAGIC_STRATEGY.md](VERMAGIC_STRATEGY.md).

`drivers/misc/Kconfig` and `drivers/misc/Makefile` are wired by Phase 1 with `sed` and `tee`:

```
# drivers/misc/Kconfig (insert before the final endmenu)
source "drivers/misc/axelera/Kconfig"

# drivers/misc/Makefile (append)
obj-$(CONFIG_AXELERA_METIS) += axelera/
```

Defconfig flag: `CONFIG_AXELERA_METIS=m` (Section 7). The udev rules (`72-axelera.rules`) are staged into `rootfs/etc/udev/rules.d/` during Phase 1.

---

## 6b. ZED X Driver: In-Tree Promotion

Same strategy as Metis. Phase 1 generates:

```
drivers/media/i2c/zedx/
├── Kconfig                   VIDEO_ZEDX, VIDEO_ZEDX_AR0234, VIDEO_ZEDX_IMX678,
│                             SL_DESER_MAX9296, SL_DESER_MAX96712 (default n)
├── Makefile                  obj-$(CONFIG_VIDEO_ZEDX) += zedx-wrapper/
├── zedx-src                  symlink to source/stereolabs/
└── zedx-wrapper/
    └── Makefile              include $(VENDOR_DIR)/Makefile
```

Wired into `drivers/media/i2c/Kconfig` and `drivers/media/i2c/Makefile`. Defconfig flags: `CONFIG_VIDEO_ZEDX=m`, `CONFIG_VIDEO_ZEDX_AR0234=m`, `CONFIG_VIDEO_ZEDX_IMX678=m`. The MAX9296 / MAX96712 selection is Kconfig-controlled, with MAX96712 default-off.

`sl_zedx.ko` and the deserializer module are produced by the kernel's module build and inherit its vermagic. The out-of-tree path under `source/stereolabs/` is preserved as the canonical source via the `zedx-src` symlink, so vendor patches still apply where the upstream Stereolabs build expects them.

> **Build path note**: the in-tree `metis-wrapper/` and `zedx-wrapper/` use a custom `modules:` target that Kbuild's `obj-m` subdir descent never invokes. Both vendor modules are therefore built as external (`M=`) modules against the just-built kernel in Phase 2, which still guarantees the kernel's exact vermagic. The in-tree shim exists so the Kconfig symbols and source layout are part of the tree.

---

## 7. AV Kernel Config Injection

**File**: [defconfig](../latest_jetson/Linux_for_Tegra/source/kernel/kernel-jammy-src/arch/arm64/configs/defconfig) (`arch/arm64/configs/`)

Appended once, with an idempotency check on `CONFIG_PREEMPT_RT=y`. Key additions:

| Config | Value | Reason |
|--------|-------|--------|
| `CONFIG_SL_DESER_MAX9296` | m | ZED Link Mono MAX9296 deserializer (see Section 2) |
| `CONFIG_SL_DESER_MAX96712` | not set | Wrong deserializer; corrupts frames silently |
| `CONFIG_PREEMPT_RT` | y | Real-time preemption |
| `CONFIG_NO_HZ_FULL` | y | Tickless on cores 1-5 |
| `CONFIG_HZ_1000` | y | 1 ms timer resolution |
| `CONFIG_CPU_ISOLATION` | y | Kernel enforcement of isolcpus |
| `CONFIG_RCU_NOCB_CPU` | y | RCU callbacks off isolated cores |
| `CONFIG_IRQ_FORCED_THREADING` | y | All IRQ handlers threaded |
| `CONFIG_CMA_SIZE_MBYTES` | 2048 | Defconfig fallback raised from the stock 32. On the flashed device the device tree `linux,cma` node governs instead and reserves a 256 MB pool (CmaTotal 262144 kB, verified on device 2026-06-10 with the GPU healthy and no `cma=` boot argument) |
| `CONFIG_HUGETLB_PAGE` | y | HugePages for AI and vision buffers |
| `CONFIG_DMABUF_HEAPS` | y | Zero-copy DMA framework |
| `CONFIG_DMABUF_HEAPS_CMA` | y | CMA heap for the camera-to-NPU path |
| `CONFIG_PCIEASPM` | not set | PCIe always-on, no link power management |
| `CONFIG_RTW88_8822CE` | m | Realtek RTL8822CE Wi-Fi driver (M.2 Key E); kept out of boot autoload by default, see [KERNEL_OPTIMIZATIONS.md](KERNEL_OPTIMIZATIONS.md) section 11 |
| `CONFIG_EDAC_TEGRA` | y | ECC memory monitoring |
| `CONFIG_PSTORE_RAM` | y | Black-box crash logging |
| `CONFIG_KASAN` | not set | Strip debug overhead and jitter |
| `CONFIG_DYNAMIC_FTRACE` | not set | Strip debug overhead and jitter |

The NVMe root chain (`CONFIG_BLK_DEV_NVME`, `CONFIG_NVME_CORE`, `CONFIG_PCIE_TEGRA194`, `CONFIG_PCIE_TEGRA194_HOST`, `CONFIG_PHY_TEGRA194_P2U`) is built in (`=y`), not as modules. The rootfs lives on NVMe over PCIe, so building these in takes the initrd module-load step out of the root-mount path entirely, and with it the vermagic-matching fragility for boot-critical modules. See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) F-6.

PREEMPT_RT is then formally enabled with NVIDIA's `generic_rt_build.sh "enable"`.

> **Full catalogue**: see [KERNEL_OPTIMIZATIONS.md](KERNEL_OPTIMIZATIONS.md). The defconfig block is organized into sixteen domains (RT core, ZED X, DMABUF, Armv8.5, hardening, RT depth, memory and cache, cgroups v2, networking, I/O, Wi-Fi, module discipline, in-tree drivers, PCIe, debug strip, filesystems).

---

## 8. ZED X Overlay DTBO: Direct dtc Compilation (Phase 2)

The NVIDIA `kernel-devicetree` build system cannot produce this overlay, for three compounding reasons:

1. `kernel-devicetree/scripts/Makefile.lib` adds `dtb-y` to `always-y` but never adds `dtbo-y`. Overlay targets in `dtbo-y` are registered but never built.
2. The ZED X overlay DTS uses `#ifdef BUILDOVERLAY` to conditionally emit `/dts-v1/; /plugin/;`. Without `-DBUILDOVERLAY`, the output is a malformed empty blob.
3. DTC 1.5.x (the Ubuntu 20.04 host `dtc`) reports `duplicate_label` errors on overlay DTS files. These are false positives: the same label appears in both the fragment overlay body and a base-tree cross-reference, which is valid in overlay context. The kernel-built `dtc` handles this without error; the host `dtc` requires `-f` to force output.

**Solution** in [scripts/02_build_kernel.sh](../scripts/02_build_kernel.sh): after `make dtbs`, the build compiles the DTBO directly with the kernel's own `dtc`.

```bash
cpp -E -DBUILDOVERLAY -DLINUX_VERSION=600 -DTEGRA_HOST1X_DT_VERSION=2 \
    -x assembler-with-cpp -nostdinc \
    -I<hw-nvidia>/t23x/nv-public \
    -I<hw-nvidia>/t23x/nv-public/include/kernel \
    -I<hw-nvidia>/tegra/nv-public \
    -I<kernel-src>/include \
    -o /tmp/zedlink-mono.dts.tmp \
    <hw-nvidia>/t23x/nv-public/tegra234-p3768-camera-zedlink-mono-sl-overlay.dts

$DTC_BIN -@ -f -I dts -O dtb \
    -o Linux_for_Tegra/kernel/dtb/tegra234-p3768-camera-zedlink-mono-sl-overlay.dtbo \
    /tmp/zedlink-mono.dts.tmp
```

`-@` enables the `__symbols__` node required for overlay label resolution at boot. `-f` suppresses the `duplicate_label` false positives.

---

## 9. Vermagic Discipline (module loadability gate)

A kernel patched this heavily ships a vermagic string that is incompatible with **any** stock NVIDIA, Stereolabs, or Axelera pre-built module. The pipeline enforces vermagic alignment at three checkpoints:

1. **End of Phase 2**: [scripts/verify_vermagic.sh](../scripts/verify_vermagic.sh) `--build-tree` walks every `.ko` produced by the build (kernel plus ZED X plus Metis), confirms they share one vermagic, and writes the value to `latest_jetson/Linux_for_Tegra/EXPECTED_VERMAGIC`.
2. **[scripts/pre_flash_audit.sh](../scripts/pre_flash_audit.sh)**: re-runs the gate against `$ROOTFS/lib/modules/` and exits non-zero on any mismatch, aborting the flash.
3. **Live target ([scripts/verify_tuning.sh](../scripts/verify_tuning.sh))**: checks `sl_zedx`, `metis`, and `max9296` against the running `uname -r`, and walks every `.ko` under `/lib/modules/$(uname -r)` to catch partial drift.

A vermagic-aligned `linux-headers-5.15.x-tegra_*.deb` is also produced by Phase 2 (`make bindeb-pkg`), staged at `Linux_for_Tegra/staging/kernel-headers/`, baked into `/opt/kernel-headers/` in Phase 3, and `dpkg -i`'d at first boot. This is the only way ZED SDK and Voyager DKMS-based installers can build against this kernel.

See [VERMAGIC_STRATEGY.md](VERMAGIC_STRATEGY.md) for the full strategy.

---

## Verification

After Phase 2 completes, confirm every patch is active before flashing.

```bash
# PCIe patience (matches PCIE_LINK_WAIT_MAX_RETRIES in versions.env)
grep LINK_WAIT_MAX_RETRIES \
  latest_jetson/Linux_for_Tegra/source/kernel/kernel-jammy-src/drivers/pci/controller/dwc/pcie-designware.h
# expect: 200

# Correct deserializer (defconfig is the home for this in R36.4.3)
grep "CONFIG_SL_DESER_MAX9296" \
  latest_jetson/Linux_for_Tegra/source/kernel/kernel-jammy-src/arch/arm64/configs/defconfig
# expect: CONFIG_SL_DESER_MAX9296=m

# CMA reservation (defconfig fallback; the flashed DT linux,cma node
# governs at runtime and reserves 256 MB on this device)
grep CMA_SIZE_MBYTES \
  latest_jetson/Linux_for_Tegra/source/kernel/kernel-jammy-src/arch/arm64/configs/defconfig
# expect: CONFIG_CMA_SIZE_MBYTES=2048

# In-tree integrations
grep -E "CONFIG_(AXELERA_METIS|VIDEO_ZEDX)" \
  latest_jetson/Linux_for_Tegra/source/kernel/kernel-jammy-src/arch/arm64/configs/defconfig
# expect: CONFIG_AXELERA_METIS=m, CONFIG_VIDEO_ZEDX=m, ...

# Vermagic captured
cat latest_jetson/Linux_for_Tegra/EXPECTED_VERMAGIC
# expect: 5.15.x-tegra SMP preempt_rt mod_unload aarch64

# Headers .deb produced
ls -lh latest_jetson/Linux_for_Tegra/staging/kernel-headers/linux-headers-*.deb

# ZED X DTBO present
ls -lh latest_jetson/Linux_for_Tegra/kernel/dtb/tegra234-p3768-camera-zedlink-mono-sl-overlay.dtbo
# expect: ~79K (a 0-byte or missing file means the DTBO did not compile)

# Vermagic gate (build tree)
./scripts/verify_vermagic.sh --build-tree

# Full pre-flash audit
./scripts/pre_flash_audit.sh
# expect: all-green banner, exit 0
```
