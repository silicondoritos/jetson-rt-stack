---
title: Vermagic Strategy
layout: default
description: "Must-read: why vermagic breaks pre-built kernel modules on a custom RT kernel, and the three-layer defense that prevents it."
nav_order: 19
---

# Vermagic Strategy

Vermagic mismatch is the most common reason a custom PREEMPT_RT kernel deployment fails at runtime: a module that built cleanly refuses to load with `Invalid module format`. This document explains what vermagic is, why this platform makes it harder than usual, and the three-layer defense the build pipeline enforces so that no mismatched module ever reaches the device. Read it before touching anything kernel- or module-adjacent. Related: [BUILD.md](BUILD.md) for the Phase 2 build that produces the matching modules, [DRIVERS.md](DRIVERS.md) for per-driver detail, and [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for symptom-first debugging.

## TL;DR

1. Every `.ko` carries a vermagic string, and with `CONFIG_MODVERSIONS=y` a per-symbol CRC table. The module loader rejects any module whose vermagic does not match the running kernel's, and any module whose imported-symbol CRCs do not match the kernel's exported symbols.
2. Stock NVIDIA, Stereolabs, and Axelera pre-built modules will not load on this kernel. The `preempt_rt` token and `LOCALVERSION=-tegra` guarantee a mismatch.
3. The pipeline runs a three-layer defense: build our own drivers (Metis, ZED X) against the exact kernel we ship, stage a vermagic-aligned `linux-headers-*.deb` in the rootfs for any third-party DKMS installer, and run automated gates ([verify_vermagic.sh](../scripts/verify_vermagic.sh) and [pre_flash_audit.sh](../scripts/pre_flash_audit.sh)) that hard-fail the build before flashing if anything drifts.

---

## What vermagic actually is

When Kbuild compiles a `.ko`, it embeds a string of the form:

```
<UTS_RELEASE> SMP <preempt_mode> mod_unload <arch>
```

For this platform the build produces:

```
5.15.148-tegra SMP preempt_rt mod_unload aarch64
```

The release prefix is derived at build time from `include/config/kernel.release`; the `5.15` base and `-tegra` suffix are pinned in [versions.env](../versions.env) (`KERNEL_BASE_VERSION`, `LOCALVERSION`).

| Field         | Value here        | Source                            |
|---------------|-------------------|-----------------------------------|
| `UTS_RELEASE` | `5.15.148-tegra`  | `KERNELVERSION` + `LOCALVERSION`  |
| SMP           | `SMP`             | `CONFIG_SMP=y`                    |
| Preempt mode  | `preempt_rt`      | `CONFIG_PREEMPT_RT=y`             |
| Module unload | `mod_unload`      | `CONFIG_MODULE_UNLOAD=y`          |
| Architecture  | `aarch64`         | `ARCH=arm64`                      |

When `insmod` or `modprobe` loads a module, the kernel compares the module's embedded vermagic byte-for-byte against its own. Any difference returns `Invalid module format`. There is no retry and no detailed diagnostic.

`CONFIG_MODVERSIONS=y` (set in [01_extract_and_patch.sh:280](../scripts/01_extract_and_patch.sh#L280)) adds a stricter check: every symbol a module imports must carry a CRC matching the kernel's `Module.symvers` entry. This catches ABI drift, for example a struct field added to an exported type, even when the vermagic string itself happens to match.

## Why this platform makes vermagic harder

Three factors combine to make this kernel's vermagic incompatible with anything the rest of the ecosystem ships:

1. **`LOCALVERSION=-tegra`** (exported in [02_build_kernel.sh:21](../scripts/02_build_kernel.sh#L21)). Stamps `-tegra` into `UTS_RELEASE`, so the release name is `5.15.x-tegra`, not the plain `5.15.x` a default build would produce.
2. **`CONFIG_PREEMPT_RT=y`** (injected by [01_extract_and_patch.sh](../scripts/01_extract_and_patch.sh) and enabled via NVIDIA's `generic_rt_build.sh`). This swaps the preempt-mode token from `preempt` (the NVIDIA default) to `preempt_rt`. This change alone breaks every NVIDIA-shipped module.
3. **The Bootlin toolchain** (`aarch64--glibc--stable-2022.08-1`, pinned in [versions.env](../versions.env)). Its GCC fingerprint differs from NVIDIA's. With `CONFIG_MODVERSIONS=y`, even a small inline-codegen difference can change exported-symbol CRCs.

## Where it bites

| Source of `.ko`                                  | Vermagic outcome                          | Mitigation in this repo                                                              |
|--------------------------------------------------|-------------------------------------------|-------------------------------------------------------------------------------------|
| Stock `nvidia-l4t-kernel-modules` from apt       | Mismatch (`preempt` vs `preempt_rt`)      | `apt-mark hold` plus apt `Pin-Priority: -1` at first boot                            |
| Pre-built Stereolabs `.deb` from their PPA       | Mismatch                                  | Build `sl_zedx.ko` ourselves against our kernel ([02_build_kernel.sh](../scripts/02_build_kernel.sh)) |
| Third-party DKMS rebuild (ZED SDK, others)       | Conditional: needs our headers `.deb`     | Ship `linux-headers-5.15.x-tegra_*.deb` and `dpkg -i` it at first boot               |
| Our Phase 2 module builds (Metis, ZED X)         | Always matches                            | Sole source of truth                                                                 |

The ZED SDK installer is run in runtime-only mode by [install_zed_sdk.sh](../scripts/install_zed_sdk.sh) precisely so it does not rebuild `sl_zedx.ko`: we already own a vermagic-aligned copy. The Voyager SDK is installed from pip wheels by [jetson_first_boot.sh](../scripts/jetson_first_boot.sh), not via a driver DKMS rebuild, so it does not produce kernel modules on the device. Both of these first-boot installs need network access; the first-boot service re-runs on each boot and completes them once the device is online, and until then `/opt/av-env` is not provisioned. Either way the vermagic story is unchanged: neither installer can introduce a mismatched `.ko`.

## The three-layer defense

### Layer 1: build our drivers against the kernel we ship

Metis and the ZED X stack (`sl_zedx` plus its GMSL2 deserializer) are compiled as external modules (`M=`) against the just-built kernel tree in [02_build_kernel.sh](../scripts/02_build_kernel.sh). The vendor wrappers carry a custom `modules:` target that Kbuild's in-tree `obj-m` descent never invokes, so the `M=` build is what actually produces the `.ko` files. Because that build uses the same kernel source, the same Bootlin toolchain, and the same `Module.symvers`, the resulting vermagic matches the kernel exactly. This is the same mechanism NVIDIA uses for its own out-of-tree modules.

| Module          | Build path                          | Selected by                |
|-----------------|-------------------------------------|----------------------------|
| `metis.ko`      | `source/axelera/` (`M=`)            | `CONFIG_AXELERA_METIS`     |
| `sl_zedx.ko`    | `source/stereolabs/` (`M=`)         | `CONFIG_CAMERA_ZEDX_*`     |
| `max9296.ko`    | `source/stereolabs/` (deserializer) | ZED X plugin post-extract  |

### Layer 2: ship matching headers for third-party DKMS

DKMS-based installers build against the running kernel and look for `/usr/src/linux-headers-$(uname -r)/`. Phase 2 produces a vermagic-aligned `linux-headers-*.deb` with `make bindeb-pkg` ([02_build_kernel.sh](../scripts/02_build_kernel.sh)). Phase 3 stages it into `/opt/kernel-headers/` in the rootfs ([03_bake_rootfs.sh](../scripts/03_bake_rootfs.sh)). [jetson_first_boot.sh](../scripts/jetson_first_boot.sh) installs it with `dpkg -i` before any third-party installer runs, so DKMS rebuilds compile against headers that match the running kernel.

### Layer 3: gates that hard-fail on drift

- **End of Phase 2:** [verify_vermagic.sh](../scripts/verify_vermagic.sh) `--build-tree` walks every `.ko` in the build tree and the out-of-tree module dirs, captures the expected vermagic, and fails on any drift.
- **Before flash:** [pre_flash_audit.sh](../scripts/pre_flash_audit.sh) invokes `verify_vermagic.sh --rootfs`, which scans `$ROOTFS/lib/modules/`. A single mismatch returns a non-zero exit and aborts the flash before any device write.
- **On the live target:** [verify_tuning.sh](../scripts/verify_tuning.sh) (Module Vermagic Sanity section) dumps the vermagic of `sl_zedx`, `metis`, and `max9296` and walks every `.ko` under `/lib/modules/$(uname -r)/`, reporting a mismatch if any module's vermagic does not match the running `uname -r`.

## Operational rules

These are inviolable. A single violation re-introduces the trap.

1. **Never `apt install` any `nvidia-l4t-kernel*` or `nvidia-l4t-bootloader` package.** [jetson_first_boot.sh](../scripts/jetson_first_boot.sh) holds and pins them to `-1`. If a prompt ever offers to upgrade these, decline.
2. **Never `insmod --force`.** The flag bypasses the vermagic check and typically loads a module that then corrupts kernel memory.
3. **Never use a `.ko` built outside the Docker container.** Identical source, toolchain, and kernel headers produce a vermagic match. Anything else is a gamble.
4. **Re-run Phase 2 if any of these change:** `LOCALVERSION` or any kernel `CONFIG_*` value; the Bootlin toolchain version; the Docker image (`make docker-build`); or any patch applied by [01_extract_and_patch.sh](../scripts/01_extract_and_patch.sh).
5. **Re-bake (Phase 3) and re-flash (Phase 4) after every Phase 2.** A new kernel paired with stale modules already in the rootfs is the most common drift scenario.

## Diagnosing a vermagic failure after deployment

Symptom: `dmesg | grep "Invalid module format"`, or a service that depends on a module fails to start.

```bash
# 1. Show the running kernel's release and vermagic context
uname -r
cat /proc/version

# 2. Show the rejected module's vermagic
modinfo /path/to/the.ko | grep vermagic

# 3. Walk every installed module on the target
sudo /opt/jetson-rt-stack/scripts/verify_tuning.sh
```

Adjust the path in step 3 to wherever the repo scripts are staged on the device. If any of `sl_zedx.ko`, `metis.ko`, or `max9296.ko` reports a vermagic that does not include the running `uname -r`, the rootfs and kernel are mismatched. Rebuild Phase 2, re-bake Phase 3, and re-flash.

## Appendix: where each rule is enforced

| Rule                                  | File                                                              |
|---------------------------------------|------------------------------------------------------------------|
| `LOCALVERSION=-tegra`                 | [02_build_kernel.sh:21](../scripts/02_build_kernel.sh#L21)        |
| `CONFIG_PREEMPT_RT=y`                 | [01_extract_and_patch.sh](../scripts/01_extract_and_patch.sh) plus `generic_rt_build.sh` |
| `CONFIG_MODVERSIONS=y`                | [01_extract_and_patch.sh:280](../scripts/01_extract_and_patch.sh#L280) |
| `CONFIG_MODULE_FORCE_LOAD` not set    | [01_extract_and_patch.sh:282](../scripts/01_extract_and_patch.sh#L282) |
| `apt-mark hold` of NVIDIA kernel pkgs | [jetson_first_boot.sh](../scripts/jetson_first_boot.sh)           |
| apt `Pin-Priority: -1`                | [jetson_first_boot.sh](../scripts/jetson_first_boot.sh)           |
| `EXPECTED_VERMAGIC` capture           | [02_build_kernel.sh](../scripts/02_build_kernel.sh) (after `l4t_update_initrd.sh`) |
| Build-tree vermagic gate              | [verify_vermagic.sh](../scripts/verify_vermagic.sh) `--build-tree` |
| Rootfs vermagic gate                  | [pre_flash_audit.sh](../scripts/pre_flash_audit.sh) (`--rootfs`)  |
| Headers `.deb` build                  | [02_build_kernel.sh](../scripts/02_build_kernel.sh) (`make bindeb-pkg`) |
| Headers `.deb` stage and install      | [03_bake_rootfs.sh](../scripts/03_bake_rootfs.sh), [jetson_first_boot.sh](../scripts/jetson_first_boot.sh) |
| Metis external-module build           | [02_build_kernel.sh](../scripts/02_build_kernel.sh) (axelera `M=`) |
| ZED X external-module build           | [02_build_kernel.sh](../scripts/02_build_kernel.sh) (stereolabs `M=`) |
| Live-target vermagic dump             | [verify_tuning.sh](../scripts/verify_tuning.sh) (Module Vermagic Sanity) |
| ZED SDK runtime-only install          | [install_zed_sdk.sh](../scripts/install_zed_sdk.sh)              |
