---
title: Build
layout: default
description: "Phase 1 (extract + patch) and Phase 2 (cross-compile) build mechanics, reproducibility guarantees, and BUILD_MANIFEST.json provenance."
nav_order: 10
---

# Build

This document covers the internals of Phase 1 (extract and patch) and Phase 2 (cross-compile): what each phase does, the environment it expects, how reproducibility is guaranteed, and how to recover from common failures. It is for anyone modifying or debugging the build itself. For first-time setup see [Quickstart]({{ '/QUICKSTART' | relative_url }}); for how the Makefile, scripts, and `versions.env` compose, see [Automation]({{ '/AUTOMATION' | relative_url }}).

The pipeline targets a Jetson Orin NX 16GB (p3767-0000 module on a p3768 Orin Nano devkit carrier) on L4T R36.4.3 / JetPack 6.2. Phase 2 cross-compiles a PREEMPT_RT kernel plus the Axelera Metis NPU and ZED X camera drivers inside a Docker container that locks the Bootlin toolchain. The image it produces is live-verified end to end on the reference device; measured camera and NPU throughput is in [Benchmarks]({{ '/BENCHMARKS' | relative_url }}).

## Standard flow

```bash
make doctor          # preflight (read-only)
make docker-build    # one-time
make extract         # Phase 1
make build           # Phase 2 (routes through Docker automatically)
```

Or all of the above plus baking:

```bash
make all             # extract → build → bake
```

## What Phase 1 does (`make extract`)

`scripts/01_extract_and_patch.sh`:

1. Extracts L4T BSP to `latest_jetson/Linux_for_Tegra/`.
2. Populates rootfs from `Tegra_Linux_Sample-Root-Filesystem_*.tbz2`.
3. Extracts kernel + OOT module sources from `public_sources.tbz2`.
4. Loads plugins (`scripts/lib/plugin.sh`) and calls `run_hook post_extract`:
   - **axelera plugin**: injects `axelera-driver/` sources, promotes Metis
     in-tree at `drivers/misc/axelera/` (Kconfig + Kbuild shim), stages
     udev rules, applies [voyager-sdk/axl-jetson.patch](../voyager-sdk/axl-jetson.patch)
     if present, then forces `LINK_WAIT_MAX_RETRIES` in `pcie-designware.h` to
     the value of `CONFIG_PCIE_LINK_WAIT_MAX_RETRIES` (200, pinned in
     [versions.env](../versions.env)) regardless. This patch raises PCIe
     link-training patience for Metis training reliability.
   - **zedx plugin**: injects `zedx-driver/` sources, applies R36.4 kernel
     patches, copies overlay DTS into `nv-public/`, fixes `dtbo-y`
     double-prefix bug in `nv-public/Makefile`, forces
     `-DCONFIG_SL_DESER_MAX9296` in `stereolabs/drivers/Makefile`, promotes
     ZED X in-tree at `drivers/media/i2c/zedx/`.
5. Calls `run_hook post_defconfig`: plugins append their `CONFIG_*` symbols
   to the kernel defconfig (Metis: `CONFIG_AXELERA_METIS=m`; ZED X:
   `CONFIG_VIDEO_ZEDX=m`, deserializer, DMABUF flags).
6. Runs NVIDIA's `generic_rt_build.sh enable` (conditional on
   `CONFIG_KERNEL_PREEMPT_RT=y`) to enable the RT patch set.

Each plugin hook is a no-op if the relevant vendor tree is absent. `make doctor` reports missing trees before any work starts. Stage every input (tarballs, vendor trees, ZED SDK installer) per [Third-party dependencies]({{ '/THIRD_PARTY' | relative_url }}).

Phase 1 is idempotent: every step is guarded by an existence check or `grep -q` before it does destructive work. It is safe to re-run after a partial failure.

## What Phase 2 does (`make build`)

`scripts/02_build_kernel.sh` runs **inside the Docker container**:

1. Sets `CROSS_COMPILE`, `ARCH=arm64`, `LOCALVERSION=-tegra`,
   `IGNORE_PREEMPT_RT_PRESENCE=1`.
2. Sets reproducibility env: `SOURCE_DATE_EPOCH` (HEAD commit time by
   default) and `LC_ALL=C`. See §Reproducibility below.
3. Compiles kernel `Image`.
4. Compiles modules, kernel sub-modules + in-tree Metis + in-tree ZED X +
   NVIDIA OOT modules.
5. Compiles DTBs.
6. Verifies `kernel/Image`, `metis.ko`, `sl_zedx.ko` are present.
7. Installs Image to `Linux_for_Tegra/kernel/Image`.
8. Installs modules to `$ROOTFS/lib/modules/`.
9. Installs DTBs to `Linux_for_Tegra/kernel/dtb/`.
10. **Manually compiles the ZED X overlay DTBO** (NVIDIA's build system
    silently skips `dtbo-y`). See [KERNEL_PATCHES.md]({{ '/KERNEL_PATCHES' | relative_url }}) §8.
11. Runs `l4t_update_initrd.sh` (best-effort). `nv-update-initrd` is installed into the rootfs by `apply_binaries.sh` at flash time ([04_flash_nvme.sh](../scripts/04_flash_nvme.sh)), which regenerates the boot initrd, so a build-time failure here is non-fatal.
12. **Builds `linux-headers-*.deb`** via `make bindeb-pkg`. Stages it at
    `Linux_for_Tegra/staging/kernel-headers/`.
13. Captures `EXPECTED_VERMAGIC` from a built `.ko`.
14. Runs `verify_vermagic.sh --build-tree`: fails the build on mismatch.
15. Writes `Linux_for_Tegra/BUILD_MANIFEST.json` capturing toolchain,
    git head, defconfig hash, vermagic, and timestamps.

## Cross-compile environment variables

When debugging directly inside `make docker-shell`, these are the env
vars Phase 2 expects:

```bash
export CROSS_COMPILE=/opt/aarch64--glibc--stable-2022.08-1/bin/aarch64-buildroot-linux-gnu-
export ARCH=arm64
export LOCALVERSION=-tegra
export IGNORE_PREEMPT_RT_PRESENCE=1
export KERNEL_HEADERS=$PWD/kernel/kernel-jammy-src
export SOURCE_DATE_EPOCH="$(git -C "$REPO_ROOT" log -1 --format=%ct)"
export LC_ALL=C
export LANG=C
```

## Targeted re-runs

| You changed | Run |
|---|---|
| A `CONFIG_*` flag via `make menuconfig` / `.config` | `make extract && make build && make bake` |
| A plugin hook or patch step | `make clean && make all` |
| Just userspace bake content (e.g. ZED SDK installer added) | `make bake` |
| Just need a fresh headers .deb | `make headers && make bake` |

When in doubt, run `make clean && make all` for a full rebuild.

## Verify: the audit gate

The audit gate is the verification step for a build. Run it after Phase 2 (and again after Phase 3 bake) to confirm the artifacts are internally consistent before any flash.

```bash
make audit       # runs scripts/pre_flash_audit.sh
```

It validates:

- Kernel `Image` version string contains `-tegra`.
- `PREEMPT_RT` strings present in the binary (when `CONFIG_KERNEL_PREEMPT_RT=y`).
- `CONFIG_DMABUF_HEAPS=y` either in the binary or the staged defconfig.
- `LINK_WAIT_MAX_RETRIES` in the source matches `CONFIG_PCIE_LINK_WAIT_MAX_RETRIES` (200, pinned in [versions.env](../versions.env)).
- `extlinux.conf` has `isolcpus`, `nohz_full` (matching `CONFIG_ISOLATED_CORE_RANGE`), and NO `cma=` argument (CMA comes from the device tree linux,cma pool; see TROUBLESHOOTING F-8).
- ZED X overlay `.dtbo` exists in `rootfs/boot/` (when camera is configured).
- **Vermagic of every `.ko` in `rootfs/lib/modules/` matches**
  `EXPECTED_VERMAGIC`.

**Exit 0 = green; exit 1 = at least one failure.** The gate is CI-friendly.

**Do not flash on failure.** [RUNBOOK.md]({{ '/RUNBOOK' | relative_url }}) §R4 has a per-failure decoder.

## Reproducibility

Goal: a build of commit `abc123` today produces the same kernel
`Image`, module `.ko`s, and `linux-headers-*.deb` as a build of
`abc123` next month, on a different host. Vermagic stability and
fleet-deployment auditability both depend on this.

What the build does to ensure it:

- **Locked toolchain in Docker.** `Dockerfile` pulls Bootlin
  `aarch64--glibc--stable-2022.08-1` from a fixed URL. Two builds
  inside that container use the same GCC, same glibc, same binutils.
  No host-toolchain leakage.
- **`SOURCE_DATE_EPOCH`.** `02_build_kernel.sh` exports it, defaulting
  to the **git HEAD commit time** of the repo. Every kernel feature
  that would otherwise embed `$(date)` honors this:
  - `__DATE__` / `__TIME__` / `__TIMESTAMP__`: gcc respects
    `SOURCE_DATE_EPOCH` since 7.x.
  - Kernel string tables that include build time use it if set.
  - `dpkg-buildpackage` (`bindeb-pkg`) uses it for `.deb` `Date:`
    fields.
  Override: `SOURCE_DATE_EPOCH=$(date +%s) make build`.
- **`LC_ALL=C` / `LANG=C`.** Forces deterministic ordering in `find` /
  `ls` / `sort` / `sed`. Without this, two hosts with different
  locales produce different module concatenation order, which changes
  the resulting binary.
- **Bind-mounted repo at a fixed path** inside the container
  (`/home/j/dev/custom_kernel`). Build artifacts encode this path in a few
  places (debug info, if enabled); a varying path leaks into the binary.
- **`BUILD_MANIFEST.json`** at end of Phase 2:

  ```json
  {
    "build_time_iso8601": "2026-05-06T17:32:08+00:00",
    "source_date_epoch":  "1715987520",
    "kernel_release":     "5.15.148-tegra",
    "expected_vermagic":  "5.15.148-tegra SMP preempt_rt mod_unload aarch64",
    "localversion":       "-tegra",
    "cross_compile":      "/opt/.../bin/aarch64-buildroot-linux-gnu-",
    "toolchain_gcc":      "aarch64-buildroot-linux-gnu-gcc 11.3.0",
    "defconfig_sha256":   "<sha256>",
    "git_head":           "<commit sha>",
    "git_state":          "clean",
    "headers_deb":        "linux-headers-..._arm64.deb"
  }
  ```

  `make logs` includes this. `make versions` prints it under "Last
  Build". Baked to `/etc/jetson-av-build.json` on every flashed device
  so `jetson-av-version` can show provenance.

### Verifying determinism

```bash
# Build A
make clean && make all
sha256sum latest_jetson/Linux_for_Tegra/kernel/Image > A.sha256

# Build B (different shell, fresh state, same commit)
make clean && make all
sha256sum latest_jetson/Linux_for_Tegra/kernel/Image > B.sha256

diff A.sha256 B.sha256          # → empty if reproducible
```

Common culprits if they differ:

- `SOURCE_DATE_EPOCH` not exported (check `make build` output for the
  printed value).
- `LC_ALL` not set in the calling shell (env leak into Docker).
- Different host time zones leaking into Phase 3 timestamps. Phase 3
  copies files; tar archives are the most common diff source.

### Fleet-deployment checksum

After a build, capture the artifacts you care about:

```bash
sha256sum \
    latest_jetson/Linux_for_Tegra/kernel/Image \
    latest_jetson/Linux_for_Tegra/kernel/dtb/*.dtbo \
    latest_jetson/Linux_for_Tegra/staging/kernel-headers/linux-headers-*.deb \
    > batch-NN.sha256
```

Sign it (`gpg --detach-sign`) and treat it as the authority for all
flashes in batch NN. Any device whose installed kernel hash drifts
from this file should be re-flashed before deployment.

### What is NOT reproducible (yet)

- **Phase 3 bake**: tar archives during baking embed file mtimes. If
  you need the rootfs reproducible too, set
  `--mtime=@$SOURCE_DATE_EPOCH --sort=name` on the relevant tar
  invocations. Currently we don't, because the rootfs flash path uses
  raw partition writes, not tarball verification.
- **Initrd**: `l4t_update_initrd.sh` is NVIDIA's tool; we don't
  control its determinism. The initrd is small and rarely the
  binary-diff target.
- **The Docker image itself**: apt-installed packages can change
  between `make docker-build` runs as Ubuntu's repo updates. Pinned
  package versions in the Dockerfile would address this (TODO).

## Manual fallback

If you cannot use Docker, Phase 2 can run directly on the host with the
same environment variables. The Docker container is preferred because it
locks the toolchain version.

```bash
cd latest_jetson/Linux_for_Tegra/source
make -C kernel -j$(nproc)
make modules -j$(nproc)
make dtbs -j$(nproc)
sudo -E make install -C kernel
sudo -E make modules_install INSTALL_MOD_PATH="../rootfs"
cd ..
sudo ./tools/l4t_update_initrd.sh
```

This path loses the reproducibility guarantees and risks vermagic drift
if the host GCC differs from Bootlin 2022.08-1. Do not use it for
production deployments.

## Troubleshooting

- `make build` fails with toolchain not found → `make docker-build` first.
- Vermagic gate fails at end of Phase 2 → some module did not build with
  the kernel's `make modules`. Most often a vendor Makefile assumed a
  specific KDIR. See [VERMAGIC_STRATEGY.md]({{ '/VERMAGIC_STRATEGY' | relative_url }}).
- `bindeb-pkg` fails → ensure `dpkg-dev` and `fakeroot` are in the
  Docker image (the default Dockerfile installs them).
- DTBO compile error → check `cpp` and `dtc` paths (the Docker image
  installs `device-tree-compiler`).

For symptom-first debugging see [TROUBLESHOOTING.md]({{ '/TROUBLESHOOTING' | relative_url }}).
