---
title: Configuration
layout: default
description: "The four configuration layers (versions.env pins, .config via menuconfig, bake-time env vars, on-device /etc/jetson-av/*.conf), the full Kconfig option reference, and the plugin system."
nav_order: 9
---

# Configuration

How to configure the build, for anyone customizing an image. Configuration lives in four layers; this page explains that model, then documents layer 2 (the build feature flags) and the plugin system in full.

## The four configuration layers

Every knob in the stack lives in one of four layers, ordered from "never touch" to "tune at runtime":

| Layer | What it holds | Documented |
|---|---|---|
| 1. `versions.env` (repo root) | Version pins: every version number, URL, tarball name, and hardware ID. Single source of truth; CI fails if any doc or script disagrees. | [Compatibility]({{ '/COMPATIBILITY' | relative_url }}) |
| 2. `.config` via `make menuconfig` | Feature flags (`CONFIG_*`): kernel options, camera profile, Metis, power profile, plugins. The committed profile is `defconfig`. | this page |
| 3. Bake/flash-time environment variables | Passed on the command line, consumed once: `SEED_USER` (headless login seed, at flash), `SEED_WIFI_SSID`/`SEED_WIFI_PSK` (NetworkManager profile, at bake), `WIFI_AUTOLOAD=1` (opt the vendor Wi-Fi driver into boot autoload, at bake). | [Flash]({{ '/FLASH' | relative_url }}), [Quickstart]({{ '/QUICKSTART' | relative_url }}) |
| 4. On-device `/etc/jetson-av/*.conf` | Read by the services at every boot, edit and reboot with no reflash: `power.conf` (`NVPMODEL_MODE`, clock clamps), `storage.conf`, `expectations.conf` (what `make verify` demands be alive). | [Fine-Tuning]({{ '/FINE_TUNING' | relative_url }}) |

The rest of this page is layer 2. The build uses [kconfiglib](https://github.com/ulfalizer/Kconfiglib), the Python reimplementation of the Linux kernel's Kconfig system, to manage build options. It brings the `menuconfig` TUI familiar from kernel builds to the firmware stack: one set of feature flags drives the kernel defconfig, the boot args, the plugins, and the rootfs staging.

## Quick start

```bash
pip install kconfiglib          # one-time, on host

make defconfig                  # apply committed defaults
make menuconfig                 # interactive TUI, change options, save
make savedefconfig              # write .config back to defconfig (commit this)
```

Then build normally:

```bash
make all
```

## How it works

`make menuconfig` writes `.config` to the repo root. Every script sources [`scripts/lib/config.sh`](../scripts/lib/config.sh), which loads `versions.env` (version pins) then `.config` (feature flags). Both are then available as shell variables:

```bash
# In any script, after sourcing config.sh:
if [ "${CONFIG_AXELERA_METIS:-y}" = "y" ]; then
    # Axelera integration enabled
fi
```

`.config` is gitignored: it is user-specific. The committed file is `defconfig`, which is the minimal diff from Kconfig defaults. Share build profiles by sharing `defconfig` files.

## Options

These are the build flags exposed by [`Kconfig`](../Kconfig). Defaults below match the committed `defconfig`; change them with `make menuconfig`. The `CONFIG_` prefix is how each flag appears in `.config` and in the scripts.

### Kernel

| Option | Default | Notes |
|---|---|---|
| `CONFIG_KERNEL_PREEMPT_RT` | y | Full PREEMPT_RT. Required for sub-100µs jitter. |
| `CONFIG_LOW_JITTER` | y | NO_HZ_FULL + isolcpus + RCU NOCB. Depends on PREEMPT_RT. |
| `CONFIG_ISOLATED_CORE_RANGE` | `"1-5"` | Injected into extlinux.conf boot args. |
| `CONFIG_CMA_SIZE_MBYTES` | 2048 | Kernel defconfig value only; the build passes NO `cma=` boot arg. On the Orin NX, `cma=2048M` fails to reserve ("cma: Failed to reserve 2048 MiB") and any cmdline `cma=` bypasses the device tree `linux,cma` pool, leaving zero CMA. nvgpu then fails its 64MB contiguous comptag allocation at GPU poweron and the GPU collapses ("Unable to recover GR falcon", no CUDA, nvpmodel cannot set any mode). With no `cma=` arg, the DT pool (256MB, stock-proven) takes over; live-verified CmaTotal=262144 kB with a fully healthy GPU. |

### Camera

| Option | Default | Notes |
|---|---|---|
| `CONFIG_CAMERA_ZEDX_MONO` | y | ZED Link Mono, MAX9296 deserializer. Requires `zedx-driver`. |
| `CONFIG_CAMERA_ZEDX_DUO` | n | ZED Link Duo, MAX96712 deserializer. Requires `zedx-driver`. |
| `CONFIG_CAMERA_NONE` | n | No camera. Disables all ZED X plugin hooks. |
| `CONFIG_DMABUF_ZEROCOPY` | y | Zero-copy pipeline. Requires a ZED X camera option. |

Status (2026-06-11): the ZED X stack is verified end to end on the device: pyzed opens the camera at HD1200@30, 29.5 FPS stereo with CUDA depth maps. The SPSC/daemon/ISP pieces are automated by `scripts/install_zedx_daemons.sh` (DRIVERS.md §1.4-1.5).

### AI Accelerator

| Option | Default | Notes |
|---|---|---|
| `CONFIG_AXELERA_METIS` | y | Axelera Metis M.2. Requires `axelera-driver`. |
| `CONFIG_METIS_POWER_CAP_W` | 18 | Brownout guard cap. Datasheet peak ~23W. |
| `CONFIG_PCIE_LINK_WAIT_MAX_RETRIES` | 200 | PCIe cold-boot patience for Metis link-training reliability, patched into `pcie-designware.h`. Stock L4T is 10. The effective value is the `versions.env` pin (`PCIE_LINK_WAIT_MAX_RETRIES=200`), which `scripts/lib/config.sh` bridges over the Kconfig symbol so the patch, audit, and display all use one source of truth. |
| `CONFIG_VOYAGER_SDK` | y | Stage Voyager SDK into rootfs. Requires `voyager-sdk`. Staged wheels are installed into `/opt/av-env` by the first-boot service only when the device has internet; until that provisioning completes online, `/opt/av-env` is not provisioned and `make verify`'s venv-import step fails. |

### Power

| Option | Default | Notes |
|---|---|---|
| `CONFIG_NVPMODEL_MAXN_SUPER` | y | mode 0, 157 TOPS. Live-verified: "NV Power Mode: MAXN_SUPER", CPU at 1.98GHz on all cores, EMC locked at max. Validate the carrier HV rail first: [Field Confirm Results]({{ '/FIELD_CONFIRM_RESULTS' | relative_url }}) §3.6. |
| `CONFIG_NVPMODEL_MAXN` | n | mode 3, 25W. Safe on any P3509-class carrier. |
| `CONFIG_NVPMODEL_15W` / `10W` | n | Reduced power modes (mode 2 = 15W, mode 1 = 10W). |

The flash installs the SUPER nvpmodel conf as the default table. Live-verified mode IDs on the device: 0 = MAXN_SUPER, 1 = 10W, 2 = 15W, 3 = 25W, 4 = 40W. The selected mode is written to `/etc/jetson-av/power.conf` as `NVPMODEL_MODE` and applied by the rt-tune service (default 0).

### Application Stack

| Option | Default | Notes |
|---|---|---|
| `CONFIG_ISAAC_ROS_SOURCE` | y | Build Isaac ROS from source. ~45 min per device. |
| `CONFIG_ISAAC_ROS_APT` | n | APT binary packages. Confirm apt coverage first: [Field Confirm Results]({{ '/FIELD_CONFIRM_RESULTS' | relative_url }}) §3.4. |
| `CONFIG_ISAAC_ROS_NONE` | n | Skip Isaac ROS entirely. |

Status (2026-06-11): the application stack (ROS 2 Humble, Isaac ROS 3.2 from NVIDIA apt, Nav2, MAVROS) is installed and verified on the reference device; the mission dry-run spawns all 6 nodes with correct core pinning. See RUNBOOK R18.

### Flight Controller

| Option | Default | Notes |
|---|---|---|
| `CONFIG_FCU_MAVROS` | y | Enable MAVLink / MAVROS integration. |
| `CONFIG_FCU_TTY` | `/dev/ttyTHS1` | Serial port. Do NOT use `/dev/ttyTHS0` (debug console). |
| `CONFIG_FCU_BAUD` | 921600 | Must match Pixhawk TELEM2 baud rate. |

## Named profiles

Save a profile with `make savedefconfig` and commit `defconfig`. To ship multiple profiles, save each one under a stable name:

```bash
cp defconfig defconfigs/layer1-only.defconfig     # no camera, no ROS
cp defconfig defconfigs/full-stack.defconfig      # everything
```

To load a profile, copy it to `defconfig`, then apply it:

```bash
cp defconfigs/layer1-only.defconfig defconfig
make defconfig
```

`make defconfig` always reads the `defconfig` file at the repo root, so swapping that file is how you switch profiles.

## Building without camera (Layer 1 only)

```bash
make menuconfig
# set Camera → CAMERA_NONE
# set AI Accelerator → keep AXELERA_METIS=y
make savedefconfig
make all
```

`make doctor` will not require `zedx-driver` or `zed-sdk` when `CAMERA_NONE=y`.

## Building without Axelera

```bash
make menuconfig
# disable AI Accelerator → AXELERA_METIS
make savedefconfig
make all
```

`make doctor` will not require `axelera-driver` or `voyager-sdk`.

## Plugin system

Each hardware integration (ZED X, Axelera) is a plugin in `plugins/<name>/`:

```
plugins/
  zedx/
    Kconfig      additional config options for ZED X
    plugin.sh    hook functions: doctor, post_extract, post_defconfig, pre_bake, post_bake
  axelera/
    Kconfig      additional config options for Axelera
    plugin.sh    hook functions: doctor, post_extract, post_defconfig, pre_bake
```

Plugins contain integration glue only; the vendor source trees are external (gitignored). Each plugin checks its own `CONFIG_` flags internally and is a no-op if the relevant feature is disabled.

### Custom plugin

To add support for additional hardware:

1. Create a directory anywhere with a `plugin.sh`:

```bash
mkdir -p /path/to/my-plugin
cat > /path/to/my-plugin/plugin.sh <<'EOF'
plugin_name() { echo "myhardware"; }

myhardware_doctor() {
    [ -d "/path/to/vendor/tree" ] || { echo "vendor tree missing"; return 1; }
}

myhardware_post_extract() {
    # inject sources, apply patches
}

myhardware_post_defconfig() {
    # append CONFIG_* to kernel defconfig
}

myhardware_pre_bake() {
    # stage files into $L4T_DIR/rootfs
}
EOF
```

2. Register in `.config`:

```
CONFIG_PLUGIN_CUSTOM_PATH="/path/to/my-plugin"
```

Or via `make menuconfig` → Plugins → Custom plugin directory path.

### Hook phases

| Hook | When called | Typical use |
|---|---|---|
| `doctor` | `make doctor` | validate prerequisites, give acquisition instructions |
| `post_extract` | after L4T extraction | inject vendor sources, apply patches, create in-tree shims |
| `post_defconfig` | after core CONFIG_ injection | append vendor-specific CONFIG_* symbols |
| `pre_bake` | before rootfs bake | stage calibration files, SDK installers, udev rules |
| `post_bake` | after rootfs bake | inject DTBO overlay into extlinux.conf |

All hooks are optional. Missing hooks are silently skipped.
