---
title: Full Tutorial
layout: default
description: "Long-form tutorial: every command, every failure mode, and every measured number for building the live-verified RT vision stack (Metis NPU + ZED X + NVMe) on Jetson Orin NX."
nav_order: 3
---

# use the metis m.2, zed x and nvme on a jetson orin nx 16gb, the long version

> *a comprehensive guide to running a full RT vision stack on the Jetson Orin NX 16GB, built from the original Axelera community bring-up guide.
> this version covers every command, every failure mode, and every measured number, from a stock board to live inference.*

---

## what this is

a complete recipe for taking a stock jetson orin nx 16gb and turning
it into a real-time vision platform:

- **custom preempt_rt kernel** with low-jitter tuning (measured
  cyclictest avg ~3µs on the isolated cores, max gated <100µs. run it
  headless, an interactive desktop session adds ~150µs ipi spikes)
- **axelera metis m.2** as the inference accelerator (in-tree driver,
  not oot, vermagic-safe). detection costs the jetson's gpu
  essentially nothing, which is the whole point
- **stereolabs zed x stereo camera** via the **zed link mono** capture
  card (max9296 deserializer)
- **nvme** boot + a btrfs data partition for recordings
- **dmabuf zero-copy pipeline** (design goal: camera → isp → npu with
  no cpu memcpy. the current voyager build still crosses through cpu
  copies; part 5 and DMABUF_ZEROCOPY.md have the status)

and then actually using it: inference on a local video file, inference
on the live camera, and a full sensor-fusion sample (npu detection +
gpu depth + point cloud + imu pose + skeleton tracking, concurrently)
with a reproducible benchmark harness behind every number.

verification status, so you know exactly what you're getting (live
checks on the reference unit, updated 2026-06-11): the kernel / rt /
metis / nvme / power-tuning baseline is verified on hardware. the zed x
capture path is verified live end-to-end: pyzed opens the camera
(HD1200@30), grabs 1920x1200 stereo frames at 29.5 fps
sustained, and computes cuda depth maps, after the SPSC/daemon pieces
from scripts/install_zedx_daemons.sh (drivers doc §1.4-1.5). the metis
inference path is verified live: voyager 1.6.1 runs yolov5s-v7-coco at
49.2 fps end-to-end on 1080p video at 13.7% cpu, the c++ samples reach
37-96 fps on the live camera depending on model and mode (yolov8l
single-core at the low end, yolov8s at svga at the top), and the
fusion sample holds 46-53 fps with every feature on. opencv-cuda is
built and cuda userspace passes 14/14 checks. one caveat: the
sustained-load hv-rail test for super mode has not run yet (part 4).

it's all in one repo:
**https://github.com/silicondoritos/jetson-rt-stack** (apache 2.0).

it builds on the original axelera bring-up guide and `axl-jetson.patch`
from the axelera team. 20 corrections relative to earlier versions of
this guide are documented in `VERIFICATION_REPORT.md` with source urls.

## measured performance, live on the reference unit (2026-06-11)

these are measurements, not projections: every number was taken on the
reference orin nx 16gb running this exact image. full tables, exact
commands, and expected outputs are in [SAMPLES.md](SAMPLES.md).

| metric | measured |
|---|---|
| yolov5s-v7-coco on 1080p video → metis, end-to-end (voyager `inference.py`) | **49.2 fps** at **13.7% cpu** |
| live zed x → metis, python demo (`demo_zedx_metis.py`) | 29.6 fps @ HD1200@30 (camera-limited) · 37.3 @ HD1200@60 · 53.3 @ SVGA@120 |
| live zed x → metis, c++ (`zedx_metis_infer`, headless) | 56.4 fps @ HD1200@60 · 74.7 @ SVGA@120 (yolov5s) · 57.4 / **95.7 fps** (yolov8s) · 37.9 @ HD1200@60 (yolov8l, single-core, npu-limited) |
| fusion sample (`zedx_metis_fusion`): npu detection + gpu depth + point cloud + imu-fused pose + skeleton tracking + per-object distance/velocity | **46-53 fps** @ HD1200@60 with yolov8s and `--depth-every 3..6`, every feature live · 37-39 fps with yolov8l (npu-bound) · bench harness sweep in [BENCHMARKS.md](BENCHMARKS.md) |
| gpu cost of detection | **zero**: ~24-25% GR3D during the c++ live run, all of it zed rectification + compositor |
| zed x stereo capture | 29.5 fps sustained 1920x1200 + cuda depth |
| power / thermals under full fusion | up to 17.3 W and 98% GR3D peak at depth-every-frame; ~60-61 C, no throttling |
| cyclictest, 10 s burst on isolated core 1, headless | avg ~3 µs, max gated <100 µs |
| boot to sshd | ~60 s |

### what you need

- a jetson orin nx 16gb (p3767 module, p3509-class carrier), an
  axelera metis m.2 (key m, 2280, gen3 x4), a zed x + zed link mono
  capture card, and an nvme drive
- a ubuntu 22.04 host (or docker on anything newer) with ~100 gb free
- the repo: **https://github.com/silicondoritos/jetson-rt-stack**
- the third-party pieces the repo can't ship: the nvidia l4t r36.4.3
  tarballs, the bootlin toolchain, `axelera-driver` + `voyager-sdk`
  (axelera support, account, no public url), `zedx-driver` (stereolabs nda), and
  the public zed sdk. what each one is, the pinned versions, and where
  to get them is in [THIRD_PARTY.md](THIRD_PARTY.md)

### if you only take four things from this post

1. **vermagic discipline** (part 2): no third-party `.ko` anyone ships
   will load on a `preempt_rt` kernel. promote drivers in-tree, ship a
   matching `linux-headers` .deb, and build the stereolabs modules as
   external modules with `KBUILD_EXTRA_SYMBOLS` pointing at the
   nvidia-oot + hwpm `Module.symvers` (or modpost dies "undefined!" and
   the camera silently ships absent).
2. **the dtbo trap** (part 2): nvidia's kernel build silently skips
   `dtbo-y` targets. your camera overlay can "build" for an hour and not
   exist. compile it yourself, then check the `.dtbo` is in `/boot/` and
   the `OVERLAYS` line is in `extlinux.conf`.
3. **`LINK_WAIT_MAX_RETRIES=200`** (part 2, §1.6): at the stock 10 pcie
   link-training retries the metis ghosts on cold boots and brownouts.
   200 trains it reliably.
4. **`GST_PLUGIN_FEATURE_RANK=nvv4l2decoder:NONE`** (part 5): nvidia's
   hardware decoder outputs NVMM-memory caps the axelera gstreamer
   elements can't consume, so every file/rtsp inference source dies
   `not-negotiated` until you force software decode.

---

## table of contents

scope: jetson orin nx 16gb (P3767 module, P3509-class carrier).
running metis (key M) + nvme (key M) + zed x (gmsl2) on the same
board, on a preempt_rt kernel, is the actual headline.

- [part 1: setup](#part-1-setup)
  - host machine
  - source archives (and the url that 404s now)
  - vendor trees (the one stereolabs doesn't publish)
  - the variables: what to set and where
- [part 2: the custom kernel](#part-2-the-custom-kernel)
  - phase 1: extract + patch
  - the defconfig, every knob, every reason
  - phase 2: build
  - the dtbo trap nobody warns you about
  - vermagic, the deep dive
- [part 3: drivers](#part-3-drivers)
  - axelera metis: in-tree, not oot (M.2 PCIe gen3 x4)
  - zed x + zed link mono (and the kernel-driver-source problem)
  - nvme, durable data partition
- [part 4: bake, flash, first boot](#part-4-bake-flash-first-boot)
- [part 5: inference](#part-5-inference)
  - opencv with cuda, the smoke test
  - step 1: a local video file (and the four traps on the way)
  - step 2: the live zed x camera, python then c++
  - step 3: full sensor fusion, every accelerator at once
- [part 6: validation](#part-6-validation)
- [part 7: troubleshooting catalog](#part-7-troubleshooting-catalog)
- [closing](#closing)

---

## part 1, setup

### who this is for

if you've got an orin nx 16gb, an axelera metis m.2, a zed x stereo
camera, and you want them all running on the same machine in a
real-time-tuned kernel, this is for you. if any of those is missing,
parts of this guide still apply but you'll skip the relevant sections.

all corrections relative to earlier guides are documented in
[VERIFICATION_REPORT.md](VERIFICATION_REPORT.md) with the vendor source
urls used to verify them. notable fixes: board target (`-super` is wrong
for orin nx), pcie retries (200, not 50), bootlin toolchain url (v3.0,
not v5.0), board target power profile, and vermagic discipline.

### host machine

ubuntu 22.04 lts only. some nvidia tools refuse to run on 24.04. the
build container is also ubuntu 22.04, so even if your host is newer
you can do this, but you need docker.

minimum:
- 16 gb ram (32 gb recommended for parallel kernel builds)
- 100 gb free disk on the partition that'll hold the workspace (200 gb
  if you want comfortable golden-image storage)
- direct usb-c cable to the jetson, not a hub, not an extender, not a
  docking station. i learned this twice.

packages:

```bash
sudo apt update
sudo apt install -y \
    build-essential bc bison flex git rsync zstd make openssl xxd \
    libssl-dev dpkg-dev qemu-user-static device-tree-compiler \
    nfs-kernel-server docker.io curl

sudo usermod -aG docker $USER
newgrp docker   # or log out and back in
```

if you're going to run `make doctor` (you should), it tells you which
of these are missing rather than letting the build fail two hours in.

### source archives

all l4t r36.4.3 archives live under `r36_release_v4.3/` on nvidia's cdn
(the toolchain url circulating in older guides with `v5.0` 404s, nvidia moved everything to v3.0):

```bash
mkdir -p ~/jetson_workspace && cd ~/jetson_workspace

# l4t bsp (bootloader, tools, scripts): ~1 gb
wget https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v4.3/release/Jetson_Linux_r36.4.3_aarch64.tbz2

# sample rootfs (ubuntu 22.04 jammy): ~1 gb
wget https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v4.3/release/Tegra_Linux_Sample-Root-Filesystem_r36.4.3_aarch64.tbz2

# public sources (kernel + oot modules): ~250 mb
wget https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v4.3/sources/public_sources.tbz2
```

these go next to the repo, not inside it. the `make extract` step
extracts them into `latest_jetson/`.

### vendor trees

four external trees that are NOT in the repo (they're gitignored):

| dir | source | required for |
|---|---|---|
| `axelera-driver/` | axelera customer portal (account) | metis kernel module |
| `voyager-sdk/` | axelera customer portal (account) | `axl-jetson.patch` + inference runtime pip wheels |
| `zedx-driver/` | stereolabs business / NDA, contact support | zed x in-tree driver (full vision stack) |
| `zed-sdk/` | [stereolabs.com/developers/release](https://www.stereolabs.com/developers/release) (public) | zed sdk userspace + pyzed (full vision stack) |

**on the zed x driver**: stereolabs doesn't publish the zed x kernel
driver as open source. they ship compiled `.deb` packages built against
the **stock** nvidia l4t kernel, those packages will not load on our
preempt_rt kernel because the vermagic won't match. you need the source
under a business / nda agreement. place it at `zedx-driver/` and the
plugin system promotes it in-tree automatically.

without `zedx-driver/` the baseline (metis + nvme) still builds and
works. `make doctor` will warn but won't fail. revisit when you have
source.

the full third-party inventory, these four trees plus the nvidia l4t
tarballs, the bootlin toolchain, and the pieces that are fetched
on-device later, is documented in [THIRD_PARTY.md](THIRD_PARTY.md)
with pinned versions and where to get each one. `versions.env` is the
single source of truth for the pins.

### confirming you have everything

```bash
git clone https://github.com/silicondoritos/jetson-rt-stack.git
cd jetson-rt-stack

# stage the trees (gitignored)
mv ../axelera-driver  .         # required, metis kernel module
mv ../voyager-sdk     .         # required, patch + inference runtime
mv ../zedx-driver     .         # required for full vision stack (zed x camera)
mv ../zed-sdk         .         # required for full vision stack (zed sdk userspace)

# stage the tarballs at the repo root (also gitignored)
mv ../Jetson_Linux_r36.4.3_aarch64.tbz2                          .
mv ../Tegra_Linux_Sample-Root-Filesystem_r36.4.3_aarch64.tbz2    .
mv ../public_sources.tbz2                                        .

# preflight
make doctor
```

`make doctor` walks every prereq and tells you what's missing with the
exact remediation command. green or yellow is fine; red means stop.

### the variables: what to set and where

four layers of configuration, from "never touch" to "touch every
flash". knowing which layer a knob lives in saves a lot of grep.

**1. `versions.env`, the pin manifest (repo root).** every version
number, url, tarball name, and hardware id is pinned here, and CI
fails the build if any doc or script disagrees with it. the entries
you'd actually change:

```sh
TARGET_BOARD=jetson-orin-nano-devkit   # orin nx 16gb on P3509-class carrier.
                                       # NOT -super (that's the orin NANO table)
TARGET_STORAGE_DEV=nvme0n1p1           # boot device the flasher writes
EXTERNAL_AXELERA_DRIVER=axelera-driver # the four vendor tree dirs from above;
EXTERNAL_VOYAGER_SDK=voyager-sdk       # rename these if you stage the trees
EXTERNAL_ZEDX_DRIVER=zedx-driver       # under different names
EXTERNAL_ZED_SDK=zed-sdk
ZED_SDK_INSTALLER_GLOB=ZED_SDK_Tegra_*.run  # matched inside zed-sdk/
VOYAGER_PYPI_URL=...api/pypi/axelera-pypi/simple  # don't trim the suffix
```

the rest (l4t version, toolchain, pytorch index,
`PCIE_LINK_WAIT_MAX_RETRIES`, the rt boot args) are pins with verified
reasons attached as comments;
change them only with a reason of your own.

**2. `.config` via `make menuconfig`, the feature flags.** the repo's
own build system uses kconfiglib, so you get the kernel's menuconfig
TUI for the firmware options too (`pip install kconfiglib` once). to
be clear: this `.config` lives at the repo root and is a separate
namespace from the kernel defconfig in part 2, even though the symbols
look alike (`CONFIG_AXELERA_METIS=y` here means "enable the metis
integration"; `CONFIG_AXELERA_METIS=m` there means "build the kernel
module"). the flags that matter for this stack:

```
CONFIG_AXELERA_METIS=y          # metis driver in-tree (needs axelera-driver/)
CONFIG_VOYAGER_SDK=y            # stage voyager into the rootfs (needs voyager-sdk/)
CONFIG_METIS_POWER_CAP_W=18     # brownout-guard cap; datasheet peak ~23W
CONFIG_CAMERA_ZEDX_MONO=y       # zed link mono / max9296 (needs zedx-driver/)
CONFIG_CAMERA_NONE=y            # ...or build the metis+nvme baseline, no camera
CONFIG_NVPMODEL_MAXN_SUPER=y    # power profile baked as the default
CONFIG_ISOLATED_CORE_RANGE="1-5"
```

`.config` is gitignored (user-specific); `defconfig` is the committed
profile. `make defconfig` applies it, `make savedefconfig` writes your
changes back. full table in [CONFIGURATION.md](CONFIGURATION.md).

**3. bake/flash-time environment variables.** passed on the command
line, consumed once:

```bash
SEED_USER=j make flash            # seed the default user (kills the oem wizard;
                                  # SEED_USER="" opts out, see part 4)
SEED_WIFI_SSID=net SEED_WIFI_PSK=secret make bake   # stage a NetworkManager profile
WIFI_AUTOLOAD=1 make bake         # opt the vendor wifi driver into boot autoload
```

**4. on-device config, `/etc/jetson-av/*.conf`.** read at every boot
by the services, no reflash needed: `power.conf` (`NVPMODEL_MODE`,
gpu/emc clamps, `AXELERA_POWER_LIMIT_W`), `storage.conf` (`NVME_VWC`),
`expectations.conf` (`EXPECT_METIS` / `EXPECT_ZED_X`, what `make
verify` demands be alive). all covered where they come up below.

---

## part 2, the custom kernel

this is the heart of it. four distinct things happen here:

1. extract l4t and inject vendor sources (phase 1 / `make extract`)
2. patch defconfig + apply pcie retry / max9296 fixes (phase 1)
3. cross-compile inside docker (phase 2 / `make build`)
4. compile the zed x dtbo because nvidia's build system silently
   skips it (phase 2)

### phase 1: extract + patch

```bash
make extract
```

what `scripts/01_extract_and_patch.sh` does, with rationale:

#### 1.1 unpack the bsp

```bash
tar xf Jetson_Linux_r36.4.3_aarch64.tbz2
sudo tar xpf Tegra_Linux_Sample-Root-Filesystem_r36.4.3_aarch64.tbz2 \
    -C Linux_for_Tegra/rootfs/
tar xf public_sources.tbz2 -C .

cd Linux_for_Tegra/source
tar xf kernel_src.tbz2
tar xf kernel_oot_modules_src.tbz2
tar xf nvidia_kernel_display_driver_source.tbz2
```

note: the rootfs extract needs `sudo` because it preserves device
nodes. on a host without passwordless sudo, the script prints exactly
what to run and exits, no half-done state.

#### 1.2 inject vendor sources

```bash
# zed x driver tree (only if you have source)
cp -r ../zedx-driver/src/kernel/stereolabs   Linux_for_Tegra/source/
cp -r ../zedx-driver/src/hardware/stereolabs Linux_for_Tegra/source/hardware/

# axelera driver tree
sudo rsync -av --exclude='.git' \
    ../axelera-driver/ \
    Linux_for_Tegra/source/axelera/axelera-driver/

# axelera udev rules (so the runtime can find /dev/axelera*)
sudo cp ../axelera-driver/udev/72-axelera.rules \
    Linux_for_Tegra/rootfs/etc/udev/rules.d/
```

#### 1.3 apply the zed x r36.4 patches

these are only present if you have stereolabs source. they integrate
the zed x driver into the nvidia kernel oot build tree:

```bash
for patch in ../zedx-driver/nvidia_kernel/kernel_patches/R36.4/0*.patch; do
    if [[ "$patch" != *"zedbox"* ]]; then
        patch -p2 -N -d Linux_for_Tegra/source < "$patch" || true
    fi
done
```

#### 1.4 fix the dtbo prefix bug

the zed x patches register dtbo overlays with a path prefix that
nvidia's makefile **also** adds. you get a doubled path
(`t23x/nv-public/t23x/nv-public/...`), the dtbo silently doesn't build:

```bash
sed -i 's|dtbo-y += \$(makefile-path)/\(.*-sl-overlay\.dtbo\)|dtbo-y += \1|g' \
    Linux_for_Tegra/source/hardware/nvidia/t23x/nv-public/Makefile
```

#### 1.5 the max9296 vs max96712 silent-corruption fix

**Note:** zed link mono uses the **max9296** gmsl2
deserializer. there's a similar product (zed link duo / quad) that
uses **max96712**. if you select the wrong deserializer, the camera
**still works** at 30fps with no errors in dmesg, frames look right, but **stereo depth is garbage and slam drifts**. silent data
corruption.

we enforce the choice in two places. first, in the defconfig (next
section): `CONFIG_SL_DESER_MAX9296=m`,
`# CONFIG_SL_DESER_MAX96712 is not set`.

second, the vendor's `drivers/Makefile` hardcodes a `-D` flag that the
defconfig doesn't override. we sed it:

```bash
sed -i 's/-DCONFIG_SL_DESER_MAX96712/-DCONFIG_SL_DESER_MAX9296/g' \
    Linux_for_Tegra/source/stereolabs/drivers/Makefile
```

both changes must be in place. one without the other = corrupted
frames.

#### 1.6 the pcie patience patch, `LINK_WAIT_MAX_RETRIES`

**Note:** the metis is invisible to `lspci` on cold boot.
`lspci -d 1f9d:` returns nothing. modprobe says the device isn't
there. once the system has been warm for a while, it just appears.

root cause: nvidia's pcie link-training timeout in
`drivers/pci/controller/dwc/pcie-designware.h` is `10` retries by
default. that's enough at room temp from a stable bench psu. it is
**not enough** on an autonomous platform with a brief brownout during
arming, or on a cold day where the dc-dc converter takes 50ms longer to
settle.

the original `axl-jetson.patch` from axelera bumped it to 50. that
worked on my bench, but **at -10°C from a flight battery i still saw
ghost-on-cold-boot**. so:

```bash
PCIE_HEADER="Linux_for_Tegra/source/kernel/kernel-jammy-src/drivers/pci/controller/dwc/pcie-designware.h"
sed -i 's/#define LINK_WAIT_MAX_RETRIES\t[0-9]*/#define LINK_WAIT_MAX_RETRIES\t200/g' "$PCIE_HEADER"
```

`200` is what trains the metis reliably across cold boots and brownouts.
the script forces it regardless of whether `axl-jetson.patch` ran first.

### the defconfig, every knob, every reason

now we append our additions to
`Linux_for_Tegra/source/kernel/kernel-jammy-src/arch/arm64/configs/defconfig`.
this is the longest, densest part of the whole pipeline. broken into
thematic groups:

#### real-time core

```
CONFIG_PREEMPT_RT=y
CONFIG_NO_HZ_FULL=y
CONFIG_HZ_1000=y
# CONFIG_HZ_250 is not set
CONFIG_CPU_ISOLATION=y
CONFIG_RCU_NOCB_CPU=y
CONFIG_IRQ_FORCED_THREADING=y
CONFIG_HIGH_RES_TIMERS=y
CONFIG_HZ=1000
CONFIG_RCU_BOOST=y
CONFIG_RCU_BOOST_DELAY=500
# CONFIG_PREEMPT_DYNAMIC is not set
# CONFIG_NO_HZ_IDLE is not set
# CONFIG_NUMA_BALANCING is not set
# CONFIG_SCHED_AUTOGROUP is not set
# CONFIG_LATENCYTOP is not set
CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE=y
# CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL is not set
# CONFIG_CPU_FREQ_GOV_ONDEMAND is not set
# CONFIG_CPU_FREQ_GOV_CONSERVATIVE is not set
```

key insights here:

- **`PREEMPT_RT`** is the real-time patch (now upstream in 5.15+).
  spinlocks become sleepable, threaded irq handlers are mandatory.
- **`NO_HZ_FULL`** + **`CPU_ISOLATION`** + **`RCU_NOCB_CPU`** must move
  together. set isolcpus boot arg to the same set as nohz_full and
  rcu_nocbs (we use cores 1-5). drop any one of the three and the
  scheduler / timer / rcu callbacks reintroduce jitter on the
  "isolated" cores.
- **`RCU_BOOST`**: when a high-priority rt task is waiting for an rcu
  grace period, the priority of the rcu reader gets temporarily
  boosted so it can release. without this, rt tasks can stall up to
  10ms behind low-priority kernel threads.
- **`PREEMPT_DYNAMIC` off**: forces fixed preempt_rt instead of
  switchable mode.
- **`NUMA_BALANCING` off**: orin nx is single-numa; balancing wastes
  cycles for nothing.
- **`LATENCYTOP` off**: per-task tracking has measurable overhead.

#### dmabuf zero-copy pipeline

```
CONFIG_SYNC_FILE=y
CONFIG_SW_SYNC=y
CONFIG_DMABUF_HEAPS=y
CONFIG_DMABUF_SYSFS_STATS=y
CONFIG_DMABUF_HEAPS_SYSTEM=y
CONFIG_DMABUF_HEAPS_CMA=y
CONFIG_CMA_SIZE_MBYTES=2048
```

**Note (this one cost us the GPU):** earlier revisions of this guide
said to set `CONFIG_CMA_SIZE_MBYTES=2048` in the defconfig AND pass
`cma=2G` as a kernel boot arg, "belt-and-suspenders". the boot arg is
actively harmful on the orin nx, do NOT pass it. live-verified failure
chain: `cma=2048M` fails to reserve ("cma: Failed to reserve 2048 MiB"),
and a cmdline `cma=` also bypasses the device tree's `linux,cma` pool,
so the system runs with ZERO cma. nvgpu needs a 64 mb physically
contiguous comptag allocation at gpu poweron (`ga10b_cbc_alloc_comptags`);
with zero cma it fails ("DMA alloc FAILED: [sysmem] size=64225280 ...
PHYSICALLY_ADDRESSED"), which cascades into "Unable to recover GR
falcon", a FECS context switch init error, no CUDA, no gpu devfreq, and
nvpmodel unable to set any power mode (it reads the gpu frequency
table).

the fix: pass NO `cma=` boot arg at all. the device tree `linux,cma`
pool (256 mb, nvidia-sized, proven on the stock image) takes over.
verified after the fix: `CmaTotal: 262144 kB`, zero nvgpu errors across
the whole boot, gpu devfreq present, `/dev/nvgpu/igpu0` nodes present,
gpu at 918 mhz. the defconfig `CONFIG_CMA_SIZE_MBYTES=2048` line stays
as a fallback default only; on this board the dt pool governs. the
"~1.4 gb sustained" sizing for the full 4k stereo pipeline from earlier
drafts is a projection, not a measurement; if the 256 mb pool ever
proves too small, resize the dt `linux,cma` node, never the cmdline.

#### pcie always-on + aer

```
# CONFIG_PCIEASPM is not set
CONFIG_PCIEPORTBUS=y
CONFIG_PCIEAER=y
CONFIG_PCIE_DPC=y
CONFIG_PCIEAER_INJECT=m
```

**Note:** pcie aspm (active state power management) lets the
link drop to l1/l1.x sleep when idle. on the metis, that means a
50µs wakeup penalty on the next dma transfer. for inference at every
frame, that's a real budget hit. and the wakeup itself is a
correctable error event. we disable aspm at three layers:
defconfig (compile-time), `pcie_aspm=off` boot arg, and per-device
`/sys/bus/pci/devices/*/power/control = on` at every boot.

`PCIEPORTBUS` + `PCIEAER` + `PCIE_DPC`: the **advanced error reporting** subsystem reports
correctable / non-fatal / fatal pcie errors via
`/sys/bus/pci/devices/*/aer_dev_*`. without these configs, those
counters don't exist and you have no visibility into pcie health. on a
power rail with brief sags, you'll see correctable errors before you
see metis disappear from `lspci`. the
`jetson-av-pcie-aer-monitor.service` polls these and emits black-box
events on increases. when something goes wrong post-flight, you can
correlate "metis disappeared at T+1247s" with "aer correctable +3 at
T+1245s" and know the root cause was electrical, not driver.

#### armv8.5 silicon dominion

```
CONFIG_ARM64_PTR_AUTH=y
CONFIG_ARM64_BTI=y
CONFIG_ARM64_BTI_KERNEL=y
CONFIG_CRYPTO_AES_ARM64_CE=y
CONFIG_CRYPTO_SHA512_ARM64=y
CONFIG_KERNEL_MODE_NEON=y
```

cortex-a78ae has hardware pointer authentication (cve mitigation),
branch target identification (cfi), and crypto extensions. all three
free; turn them on.

#### memory + cgroups v2 (for systemd cpuset pinning)

```
CONFIG_TRANSPARENT_HUGEPAGE=y
CONFIG_TRANSPARENT_HUGEPAGE_MADVISE=y
CONFIG_HUGETLB_PAGE=y
CONFIG_USERFAULTFD=y
CONFIG_PAGE_REPORTING=y
# CONFIG_ZSWAP is not set
# CONFIG_ZRAM is not set

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

`CGROUP_BPF` + `CPUSETS` are what `systemd-run --scope -p AllowedCPUs=4-5`
uses to actually pin cuvslam to cores 4-5. without these the constraint
is silently ignored.

`ZSWAP` and `ZRAM` off: compression in the swap path is a no-no for rt
(the bake also masks `nvzramconfig.service` so nothing re-enables it).
the flip side: a freshly baked image has NO swap at all, and on-device
CUDA extension builds (`nvcc`/`cicc` fan out at ~2 gb resident per
source file) can get OOM-killed on the 16 gb module. the remedy is a
low-swappiness NVMe swapfile, never zram; the full recipe is in the
troubleshooting catalog (part 7, and TROUBLESHOOTING B-7).

#### networking + i/o (nvme, async i/o, serial peripherals)

```
CONFIG_NET_SCH_FQ=m
CONFIG_TCP_CONG_BBR=m
CONFIG_DEFAULT_TCP_CONG="bbr"
CONFIG_BPF_JIT=y
CONFIG_BPF_JIT_ALWAYS_ON=y

CONFIG_BLK_MQ_PCI=y
CONFIG_NVME_MULTIPATH=y
CONFIG_NVME_HWMON=y
CONFIG_IO_URING=y
CONFIG_USB_SERIAL_FTDI_SIO=m
CONFIG_USB_SERIAL_CP210X=m
CONFIG_USB_ACM=m
CONFIG_USB_USBNET=m
CONFIG_USB_NET_RNDIS_HOST=m
CONFIG_USB_NET_CDCETHER=m
```

- `NET_SCH_FQ` + `BBR`: fair-queue qdisc on the primary nic so one
  bursting flow can't starve everything else; `jetson_rt_tune.sh`
  applies it every boot.
- `NVME_HWMON`: temperature monitoring for the boot ssd.
- `IO_URING`: async i/o for recording at high rates.
- the usb-serial / usb-net modules cover ftdi, silabs and cdc-acm
  serial peripherals plus usb-ethernet sticks, so field hardware
  enumerates without a kernel rebuild.

#### security / hardening (no rt cost)

```
CONFIG_HARDENED_USERCOPY=y
CONFIG_FORTIFY_SOURCE=y
CONFIG_STACKPROTECTOR_STRONG=y
CONFIG_RANDOMIZE_BASE=y
CONFIG_RANDOMIZE_MODULE_REGION_FULL=y
CONFIG_INIT_STACK_ALL_ZERO=y
# CONFIG_DEVMEM is not set
# CONFIG_LEGACY_PTYS is not set
```

**Note:** `# CONFIG_DEVKMEM is not set` was in my defconfig
for months. **devkmem was removed from upstream linux in 5.13.** the
symbol doesn't exist in 5.15. kconfig silently ignores unknown
symbols, so my "we have devkmem off" was a no-op. doesn't matter
functionally (it's already off), but it's emblematic of a class of
silent misconfiguration. now flagged in the defconfig as a comment.

#### resilience / kdump / tpm

```
CONFIG_KEXEC=y
CONFIG_KEXEC_FILE=y
CONFIG_CRASH_DUMP=y
CONFIG_PROC_VMCORE=y
CONFIG_SECURITY=y
CONFIG_SECURITY_YAMA=y
CONFIG_SECURITY_LOCKDOWN_LSM=y
CONFIG_LSM="yama,lockdown,integrity"
CONFIG_TCG_TPM=y
CONFIG_TCG_TIS=y
CONFIG_HW_RANDOM_TPM=y
```

**Note:** i had `CONFIG_TPM_HW_RANDOM=y` in my defconfig for
months. **the actual symbol is `CONFIG_HW_RANDOM_TPM`** (in
`drivers/char/hw_random/Kconfig`, not `drivers/char/tpm/Kconfig`).
kconfig silently ignored my line and we got zero entropy from the
tpm. a friend ran a static analysis pass against `torvalds/linux@v5.15`
and found 15 things like this; they're all in
[VERIFICATION_REPORT.md](VERIFICATION_REPORT.md).

#### module discipline

```
CONFIG_MODVERSIONS=y
CONFIG_MODULE_SRCVERSION_ALL=y
# CONFIG_MODULE_FORCE_LOAD is not set
```

`MODVERSIONS` adds per-symbol crc checks **on top of** vermagic. this
is stricter, even if vermagic happens to match, mismatched symbol
crcs are rejected. `MODULE_FORCE_LOAD` off means there's literally no
escape hatch for `insmod --force`. that's a feature, not a bug.

#### in-tree axelera metis + zed x

```
CONFIG_AXELERA_METIS=m

CONFIG_VIDEO_ZEDX=m
CONFIG_VIDEO_ZEDX_AR0234=m
CONFIG_VIDEO_ZEDX_IMX678=m

CONFIG_SL_DESER_MAX9296=m
# CONFIG_SL_DESER_MAX96712 is not set
```

these only fire if `scripts/01_extract_and_patch.sh` generated the
in-tree shims under `drivers/misc/axelera/` and
`drivers/media/i2c/zedx/`. see part 3 for the actual code.

#### debug stripping (every cycle counts)

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
```

**Note:** with `KASAN` + `FUNCTION_GRAPH_TRACER` +
`PROVE_LOCKING` enabled (the default debug setup nvidia ships), my
cyclictest max latency was **180-220 µs**. with all debug stripped,
i'm at **30-50 µs**. that's the difference between "this works for
manual control" and "this can autonomously avoid an obstacle at 20
m/s". turn it off.

#### final phase 1 step

`./generic_rt_build.sh "enable"`: this is nvidia's helper that flips
a few additional `CONFIG_PREEMPT_*` options that the rt patch expects.
it runs after our defconfig appends. if you skip it, the build will
warn about preempt_rt being requested but not fully active.

### phase 2: build inside docker

```bash
make docker-build   # one-time: builds the cross-compile container
make build          # runs scripts/02_build_kernel.sh inside docker
```

inside the container:

```bash
export CROSS_COMPILE=/opt/aarch64--glibc--stable-2022.08-1/bin/aarch64-buildroot-linux-gnu-
export ARCH=arm64
export LOCALVERSION=-tegra
export IGNORE_PREEMPT_RT_PRESENCE=1
export KERNEL_HEADERS=$PWD/kernel/kernel-jammy-src
export SOURCE_DATE_EPOCH=$(git -C "$REPO_ROOT" log -1 --format=%ct)
export LC_ALL=C
export LANG=C

# build
make -C kernel -j$(nproc)
make modules -j$(nproc)
make dtbs -j$(nproc)

# install
sudo -E make install -C kernel
INSTALL_MOD_PATH=$ROOTFS sudo -E make modules_install
```

the env vars matter:

- **`LOCALVERSION=-tegra`**: the suffix that ends up in
  `uname -r` (`5.15.x-tegra`). everything that follows
  identifies "this kernel" by this string.
- **`SOURCE_DATE_EPOCH`**: pinning to the git head commit time so two
  builds of the same commit produce byte-identical artifacts. this is
  what makes `make release` deterministic and the golden-image flow
  reproducible.
- **`LC_ALL=C` / `LANG=C`**: stops `find` / `ls` / `sort` from
  ordering files differently on hosts with different locales.

### the dtbo trap nobody warns you about

**Note:** nvidia's kernel build system silently skips
`dtbo-y` targets. that's right, you can put your overlay in
`drivers/.../Makefile` as `dtbo-y += my-overlay.dtbo`, run `make dtbs`
for an hour, and ship a kernel with no overlay. nothing in the build
output mentions it. the `*.dtbo` file just isn't there.

i lost a weekend to this.

the cause is two-layered:

1. `kernel-devicetree/scripts/Makefile.lib` adds `dtb-y` to `always-y`
   but doesn't do the same for `dtbo-y`. registered, never built.
2. the zed x overlay dts uses `#ifdef BUILDOVERLAY` to conditionally
   emit the `/dts-v1/; /plugin/;` header. without `-DBUILDOVERLAY`,
   you get a malformed empty dtbo even if you trick the build into
   compiling it.
3. **AND**: dtc 1.5.x (what ubuntu 20.04 ships in the docker container)
   reports false-positive `duplicate_label` errors on overlay dts files.
   the kernel's in-tree `dtc` handles this; the host system `dtc`
   needs `-f` to force.

so we bypass the whole nvidia mess and compile the dtbo directly:

```bash
DTC_BIN="$SOURCE/kernel/kernel-jammy-src/scripts/dtc/dtc"
HW_NV="$SOURCE/hardware/nvidia"
ZED_DTS="$HW_NV/t23x/nv-public/tegra234-p3768-camera-zedlink-mono-sl-overlay.dts"
ZED_DTBO="$L4T/kernel/dtb/tegra234-p3768-camera-zedlink-mono-sl-overlay.dtbo"

cpp -E \
    -DBUILDOVERLAY \
    -DLINUX_VERSION=600 \
    -DTEGRA_HOST1X_DT_VERSION=2 \
    -x assembler-with-cpp -nostdinc \
    -I"$HW_NV/t23x/nv-public" \
    -I"$HW_NV/t23x/nv-public/include/kernel" \
    -I"$HW_NV/t23x/nv-public/include/nvidia-oot" \
    -I"$HW_NV/t23x/nv-public/include/platforms" \
    -I"$HW_NV/tegra/nv-public" \
    -I"$SOURCE/kernel/kernel-jammy-src/include" \
    -o /tmp/zedlink-mono.dts.tmp \
    "$ZED_DTS"

# -@ enables the __symbols__ node for overlay label resolution.
# -f suppresses the dtc 1.5.x false-positive errors.
$DTC_BIN -@ -f -I dts -O dtb -o "$ZED_DTBO" /tmp/zedlink-mono.dts.tmp
```

`scripts/02_build_kernel.sh:57-83` has the actual code. **always
verify the dtbo exists after build**:

```bash
ls -lh latest_jetson/Linux_for_Tegra/kernel/dtb/tegra234-p3768-camera-zedlink-mono-sl-overlay.dtbo
# should be ~79 kb. if it's 0 bytes or missing, your dtbo didn't compile.
```

`scripts/pre_flash_audit.sh` checks this; don't flash without it.

### linux-headers-*.deb, the secret weapon

at the end of phase 2 we run `make bindeb-pkg` to produce a
`linux-headers-5.15.x-tegra_*.deb` and stash it under
`Linux_for_Tegra/staging/kernel-headers/`. phase 3 bakes it into
`/opt/kernel-headers/` on the rootfs, and `jetson_first_boot.sh`
`dpkg -i`'s it before any third-party installer runs. result:
`/usr/src/linux-headers-$(uname -r)/` is populated, and dkms-based
installers (zed sdk, voyager) can rebuild against our exact kernel.

without this, every dkms install is a vermagic mismatch waiting to
happen.

### vermagic, the deep dive

i need to spend a full section on this because it's the single biggest
source of "why doesn't my driver load" pain on a custom rt kernel.

#### what vermagic actually is

every `.ko` carries a 64-byte string in its `__module_vermagic`
section. the format is approximately:

```
<UTS_RELEASE> SMP <preempt_mode> mod_unload <arch>
```

for our kernel:

```
5.15.148-tegra SMP preempt_rt mod_unload aarch64
```

when `insmod` loads a `.ko`, the kernel reads the embedded vermagic
and compares it byte-for-byte to its own. **any difference → "Invalid
module format". no retry, no useful error message.**

the inputs that change vermagic:

- `UTS_RELEASE` = `KERNELVERSION + LOCALVERSION`: our `-tegra`
  is the anchor
- preempt mode, `preempt_rt` for us, `preempt` for stock nvidia
- `MODULE_UNLOAD`: `y` for us
- arch, `aarch64`

`CONFIG_MODVERSIONS=y` adds a stricter check on top: each symbol the
module imports must have a crc matching the kernel's exported-symbol
crc. mismatch = rejection even if vermagic matches.

#### why this hits us hardest

three knobs combined make our vermagic uniquely incompatible with
anything anyone ships:

1. **`LOCALVERSION=-tegra`**: stock l4t doesn't have this
2. **`CONFIG_PREEMPT_RT=y`**: stock l4t is `preempt`, not `preempt_rt`
3. **bootlin gcc 11.3**: different toolchain fingerprint than
   nvidia's build

so:

| where the .ko comes from | will it load on our kernel? |
|---|---|
| stock `nvidia-l4t-kernel-modules.deb` | **NO** (preempt vs preempt_rt) |
| stereolabs zed x deb | **NO** (built against stock nvidia kernel) |
| pre-built axelera metis from a community link | **NO** |
| voyager sdk's `install.sh --driver` (dkms rebuild on target) | **CONDITIONAL**: only if our headers .deb is installed first |
| our phase 2 build (kernel + in-tree drivers) | **YES** (single source of truth) |

#### the three-layer defense

1. **in-tree where possible**. metis driver lives at
   `drivers/misc/axelera/`; zed x lives at `drivers/media/i2c/zedx/`.
   the kernel's own `make modules` builds both with the same toolchain
   + headers + module.symvers as the kernel. vermagic match guaranteed.
2. **ship matching headers .deb** in the rootfs at `/opt/kernel-headers/`
   and dpkg-i it at first-boot. third-party installers find headers
   under `/usr/src/linux-headers-$(uname -r)/` and dkms succeeds.
3. **gates that hard-fail**. `verify_vermagic.sh --build-tree` runs at
   end of phase 2. `pre_flash_audit.sh` gates flashing. `verify_tuning.sh`
   on the live target walks every `.ko` under `/lib/modules/$(uname -r)/`
   and reports any mismatch.

#### things people will tell you to do that are wrong

- **"just `insmod --force`"**: no. our kernel has
  `CONFIG_MODULE_FORCE_LOAD` not set, so the kernel doesn't even
  accept the flag. but even on a kernel that did, force-loading a
  vermagic-mismatched module corrupts kernel memory in non-obvious
  ways and you'll crash 20 minutes later in unrelated code.
- **"just `apt install nvidia-l4t-kernel-modules`"**: no. our
  first-boot script holds these packages and pins them to
  `Pin-Priority: -1`. for good reason. they're built against stock
  nvidia kernel.
- **"just rebuild dkms"**: only safe if you have our matching
  headers .deb installed first. otherwise dkms picks up whatever's at
  `/usr/src/linux-headers-$(uname -r)/` and that's what stock
  nvidia-l4t-kernel-headers ships, which is the wrong vermagic.

if your `lsmod | grep <some-driver>` is empty after first boot,
**always** check vermagic before doing anything else:

```bash
modinfo /lib/modules/$(uname -r)/.../driver.ko | grep vermagic
uname -r
# the vermagic must contain uname -r byte-for-byte.
```

---

## part 3, drivers

### axelera metis: in-tree, not oot

the axelera bring-up guide treats metis as an out-of-tree (oot)
module, clone the driver tree, run its `make`, hope vermagic matches.
that path is fragile under preempt_rt because oot makefiles often
ignore your `CROSS_COMPILE` env or pick up host headers.

instead, we promote metis to in-tree. phase 1 generates a thin
kconfig + kbuild shim under `drivers/misc/axelera/`:

```
drivers/misc/axelera/
├── Kconfig                   ← defines CONFIG_AXELERA_METIS
├── Makefile                  ← obj-$(CONFIG_AXELERA_METIS) += metis-wrapper/
├── metis-src                 ← symlink → source/axelera/axelera-driver/
└── metis-wrapper/
    └── Makefile              ← include $(VENDOR_DIR)/Makefile
```

the symlink keeps the canonical vendor source under `source/axelera/`,
where any vendor patches we apply still flow through. the wrapper
makefile delegates to the vendor's makefile but runs it under the
kernel's own build environment (`KERNELRELEASE`, `srctree`,
`CROSS_COMPILE`).

phase 1 also wires `drivers/misc/Kconfig` and `drivers/misc/Makefile`:

```
# drivers/misc/Kconfig (insert before final endmenu)
source "drivers/misc/axelera/Kconfig"

# drivers/misc/Makefile (append)
obj-$(CONFIG_AXELERA_METIS) += axelera/
```

with `CONFIG_AXELERA_METIS=m` in defconfig, `make modules` produces
`metis.ko` automatically with the kernel's vermagic.

#### axelera pci vendor id

**Note:** the axelera metis pci vendor:device id is
**`1f9d:1100`**. for **months** i had `1d60` everywhere, in
brownout-guard, in verify scripts, in dmesg-grep filters. `lspci -d :1d60:`
silently returned nothing because nothing on the bus had vendor `1d60`.
i thought metis was ghosting; actually my queries weren't matching.
confirmed against an [axelera community
thread](https://community.axelera.ai/metis-pcie-7/axelera-metis-pcie-ai-accelerator-not-recognized-by-lspci-145).
`lspci -d 1f9d:` is the right query.

while we're on it: the metis m.2 form factor is **m.2 2280** (full
length), pcie **gen3 x4**: not 2230 / gen4 x2 as some secondary
sources suggest. confirmed against the
[axelera datasheet](https://axelera.ai/hubfs/Axelera_February2025/pdfs/axelera-ai-m2-ai-edge-accelerator-module.pdf).
plan your carrier accordingly.

#### udev rules

`72-axelera.rules` is staged into `rootfs/etc/udev/rules.d/` by phase
1. it names the metis device node predictably so the runtime can find
it without scanning `/dev/pci*`.

#### voyager sdk userspace

new in 1.6: the voyager sdk ships as **pip wheels**, not as
`install.sh --driver`. the legacy install path still exists but the
wheels are the recommended route on a vermagic-safe kernel:

```bash
pip install axelera-rt axelera-devkit \
    --extra-index-url https://software.axelera.ai/artifactory/api/pypi/axelera-pypi/simple
```

**Note:** the url **must** include `/api/pypi/<repo>/simple`,
pip's index api requires that path. the bare
`/artifactory/axelera-pypi/` we used originally returns 404.

`jetson_first_boot.sh` runs this in `/opt/av-env` (a python venv we
own) and pins `numpy<2.0.0` because voyager has not yet certified
numpy 2.x as of 1.6.

the wheels get you the runtime. the app framework (`inference.py`, the
gstreamer pipeline, the live demos) needs four more steps that each
have a trap. the live-verified procedure is in part 5.

### zed x stereo + zed link mono

the in-tree shim mirrors the metis approach but at
`drivers/media/i2c/zedx/`:

```
drivers/media/i2c/zedx/
├── Kconfig
├── Makefile
├── zedx-src                  ← symlink → source/stereolabs/
└── zedx-wrapper/
    └── Makefile
```

`Kconfig` exposes:

```
CONFIG_VIDEO_ZEDX=m              # top-level
CONFIG_VIDEO_ZEDX_AR0234=m       # onsemi AR0234 sensor
CONFIG_VIDEO_ZEDX_IMX678=m       # Sony IMX678 sensor
CONFIG_SL_DESER_MAX9296=m        # ZED Link Mono deserializer (REQUIRED)
CONFIG_SL_DESER_MAX96712=n       # ZED Link Duo/Quad deserializer (DO NOT enable)
```

**this only works if you have stereolabs source.** see part 1 for the
rant about stereolabs not publishing the source publicly. without
source, the in-tree shim is harmless, it just produces nothing
because there's nothing under `zedx-src/`.

#### isp calibrations

`zedx-driver/ISP/*.isp` files are baked into
`/var/nvidia/nvcam/settings/` by phase 3. nvidia's `nvcam` daemon
loads them at boot to tune the isp pipeline (exposure, white balance,
lens shading) for the specific sensor. without these, the camera
still works but the colors are off and visual SLAM tracking degrades.

related: stock l4t r36.4.x ships a `libnvisppg.so` that renders the
zed x **soft / not crisp** even with correct calibrations. stereolabs
ships a patched library at `zedx-driver/nvidia_364_fix/<l4t version>/`;
`scripts/install_zedx_daemons.sh` installs it via `dpkg-divert` so the
stock copy survives and apt upgrades don't clobber the fix
(troubleshooting catalog H-5).

#### the dtbo

the zed x overlay registers the camera with the tegra device tree.
`tegra234-p3768-camera-zedlink-mono-sl-overlay.dtbo` is compiled by
phase 2 (the cpp + dtc workaround above) and registered in
`extlinux.conf`:

```
APPEND ${cbootargs} ...
OVERLAYS /boot/tegra234-p3768-camera-zedlink-mono-sl-overlay.dtbo
```

cboot applies the overlay during boot. without it, the camera doesn't
appear in `/dev/video*` even if the driver loads.

#### testing the camera

```bash
# v4l2 enumeration
v4l2-ctl --list-devices

# 5-second nvmm capture (bypasses memcpy)
sudo gst-launch-1.0 -v nvarguscamerasrc num-buffers=150 ! \
    'video/x-raw(memory:NVMM),width=1920,height=1080,framerate=30/1' ! \
    fakesink
```

if `v4l2-ctl --list-devices` shows nothing for zed x: the overlay
didn't apply. check `/boot/extlinux/extlinux.conf` for the `OVERLAYS`
line and that the `.dtbo` exists in `/boot/`.

once the sdk userspace + daemons are installed, the repo ships
ready-made samples (expected outputs in [SAMPLES.md](SAMPLES.md);
`sg zed -c` covers the group membership until you re-login):

```bash
# open + identify + one frame (~5 s)
sg zed -c '/opt/av-env/bin/python examples/zedx_grab.py'

# cuda depth map (~10 s)
sg zed -c '/opt/av-env/bin/python examples/zedx_depth.py'

# live stereo window, left | right
DISPLAY=:0 sg zed -c '/opt/av-env/bin/python examples/zedx_stereo_view.py'
```

measured on the reference unit: 29.5 fps sustained stereo 1920x1200 at
HD1200@30 with cuda depth.

#### zed sdk userspace

the zed sdk `.run` installer is a closed-source binary. it installs
the userspace libs to `/usr/local/zed/`. **it tries to dkms-install
`sl_zedx.ko` against the running kernel.** if our headers .deb is
present, dkms will succeed (with a vermagic-correct module that ends
up shadowing our in-tree one, harmless). if not, dkms fails.

**`skip_drivers` does not exist.** the documented flags are `silent`,
`runtime_only`, `skip_python`, `skip_cuda`, `skip_tools`,
`skip_od_module`, `skip_hub`, `nvpmodel=0`. passing `skip_drivers`
is silently ignored and the dkms path still runs.
`scripts/install_zed_sdk.sh` uses the correct flags:

```bash
"$INSTALLER" -- silent runtime_only skip_python skip_cuda skip_tools \
                  skip_od_module skip_hub nvpmodel=0
```

then we install pyzed into our venv via the official helper:

```bash
/opt/av-env/bin/python /usr/local/zed/get_python_api.py
```

**Note: the sdk installer leaves three gaps on this kernel.** all three
are closed by `scripts/install_zedx_daemons.sh` (drivers doc §1.5),
and the camera does not open until they are:

1. **BMI088 IMU + SPSC kernel modules** (`bmi088.ko`, `bmi_spsc.ko`)
   built against our kernel. zed sdk ≥5.x refuses to open the camera
   without them: `CAMERA MOTION SENSORS NOT DETECTED` /
   `No camera-to-SPSC mappings found` (troubleshooting H-6).
2. **the vendor daemons** (the privileged SPSC broker the sdk talks
   to), built and installed as systemd units.
3. **the patched `libnvisppg.so`** for the stock-r36.4.x soft-image
   problem (H-5, see the isp note above).

run it once after the sdk install, re-login for the `zed` group, and
the samples below work.

### nvme

nothing exotic on the nvme side, l4t's flash flow handles it. the
kernel configs above (`NVME_MULTIPATH`, `NVME_HWMON`, `BLK_MQ_PCI`)
give us multipath, temperature monitoring, and per-cpu queue
distribution.

we DO add a btrfs data partition for black-box recordings. `phase 7`'s
`install_data_partition.sh` does this:

1. detect free space at the end of `/dev/nvme0n1`
2. if ≥100 gb free: `parted` adds a btrfs partition there
3. if not: 200gb sparse loop file at `/opt/jetson-av-data.btrfs`
4. mount with `compress=zstd:3,noatime,space_cache=v2,autodefrag`
5. install a `jetson-av-btrfs-scrub.timer` that runs `btrfs scrub`
   weekly (sunday 03:00 + 2h randomized delay)

what you get on a single drive:

- block-level crc32c bit-rot detection (silent corruption → i/o error)
- ~2x compression on jsonl event logs and ros 2 bag files
- atomic snapshots per flight (btrfs subvolume)
- weekly scrub catches bad blocks before mid-mission

what you don't get yet: cross-drive redundancy. when you add a second
nvme, the same script supports `DATA_RAID=1` for in-place btrfs raid1
conversion (preserves data; mirrors data + metadata; self-heals on
scrub).

#### nvme write cache policy

`/etc/jetson-av/storage.conf`:

```sh
NVME_VWC=off    # off=durable | on=fast | skip=device default
```

`off` flips the volatile write cache via
`nvme set-feature -f 6 -v 0`. costs ~2x sequential write throughput;
gains data durability across sudden power-cut. **for black-box mode
you want this off.**

a udev rule applies the policy on every nvme enumeration so it
survives reboots (vwc setting is volatile in nvme).

---

## part 4, bake, flash, first boot

### phase 3: bake

```bash
make bake
```

what `scripts/03_bake_rootfs.sh` does:

- copy voyager-sdk into `/home/j/voyager-sdk` on the rootfs
- copy axelera udev rules into `rootfs/etc/udev/rules.d/`
- copy zed x isp `.isp` files into `/var/nvidia/nvcam/settings/`
- copy `BUILD_MANIFEST.json` (commit, vermagic, toolchain, defconfig
  hash) into `/etc/jetson-av-build.json` so every flashed device can
  identify its build via `jetson-av-version` cli
- copy `/usr/local/bin/jetson-av-version` cli
- copy first-boot + per-boot rt-tune + verify scripts
- install systemd services (`jetson-first-boot.service`,
  `jetson-rt-tune.service`, etc.)
- copy `linux-headers-*.deb` into `/opt/kernel-headers/`
- copy zed sdk `.run` installer + wrapper into `/opt/zed-sdk/` (if
  present)
- copy phase 5 (av stack) + phase 7 (resilience) scripts into
  `/home/j/phase5/` and `/home/j/phase7/`
- stage the Wi-Fi driver policy: blacklist the in-kernel `rtw88`
  modules in favor of the vendor `rtl8822ce`; the vendor driver's
  autoload is opt-in (`WIFI_AUTOLOAD=1` at bake time). a
  NetworkManager auto-connect profile is staged (`SEED_WIFI_SSID` /
  `SEED_WIFI_PSK`) so no manual network setup is needed.
  never force-load a probing driver via `/etc/modules-load.d/`: a hung
  probe there runs at sysinit and blocks ssh/getty forever while the
  kernel still answers ping
- inject rt boot args into `extlinux.conf`:
  `root=/dev/nvme0n1p1 rootwait rootfstype=ext4 nohz_full=1-5 isolcpus=1-5 rcu_nocbs=1-5 irqaffinity=0 efi=noruntime pcie_aspm=off`
  (deliberately NO `cma=` arg; see the cma note in part 2. the bake
  also strips any stale `cma=` left by older revisions)
- register the zed x dtbo overlay

the ZED X camera overlay is **verified live on this image**
(2026-06-11): the stereo pair enumerates on the in-tree driver and pyzed
captures at 29.5 fps with cuda depth. verify the camera with
`v4l2-ctl --list-devices` once the ZED SDK userspace is installed (a
separate on-device step, see part 3).

### the audit gate

```bash
make audit
```

`scripts/pre_flash_audit.sh` is a hard fail-or-pass gate. it walks:

- kernel image is `-tegra` (string in the binary)
- `PREEMPT_RT` strings present
- `CONFIG_DMABUF_HEAPS=y` either in the binary or the staged defconfig
- `LINK_WAIT_MAX_RETRIES=200` in the source header
- `extlinux.conf` has `isolcpus=1-5`, `nohz_full=1-5`, and NO `cma=`
  boot arg (a cmdline `cma=` bypasses the device tree cma pool and
  breaks gpu init, see part 2)
- zed x overlay `.dtbo` exists in `rootfs/boot/`
- vermagic is consistent across every `.ko` in `rootfs/lib/modules/`

exit 0 = green; exit 1 = at least one failure.
**don't flash on failure.** this gate has caught me from shipping a
broken image at least three times.

### phase 4: flash

put the jetson into recovery mode (short rec + gnd, plug usb-c into
the **rear** motherboard port, not a hub), then:

```bash
make flash
```

what happens:

```bash
sudo ./tools/l4t_flash_prerequisites.sh
sudo ./apply_binaries.sh

# auto-detect the apx device (USB ID 0955:7323) for 60s, fall back to prompt
# rndis udev rule (so the gadget shows up as usb0)
# then:
sudo ./tools/kernel_flash/l4t_initrd_flash.sh \
    --external-device nvme0n1p1 \
    -c tools/kernel_flash/flash_l4t_t234_nvme.xml \
    -p "-c bootloader/generic/cfg/flash_t234_qspi.xml" \
    --showlogs --network usb0 \
    jetson-orin-nano-devkit internal
```

**Board target:** the correct target for orin nx 16gb (P3767 module on
a P3509-class carrier) is `jetson-orin-nano-devkit` (aliases
`p3509-a02+p3767-0000.conf`). **do not use
`jetson-orin-nano-devkit-super`**, that is a power-table variant for
the orin NANO devkit, not orin nx.

if you flash with `-super` on orin nx 16gb, the flash itself
"succeeds" but the device boots with the wrong power profile and you
get ~30% reduced cpu/gpu clocks plus weird thermal behavior. it's the
hardest kind of bug to diagnose because nothing fails loud.

`make doctor` validates `TARGET_BOARD` against the extracted l4t tree
and lists alternatives if it can't find your value.

#### apply_binaries clobbers the custom kernel

**Note:** `apply_binaries.sh` reinstalls the **stock** nvidia kernel
and modules into the rootfs. run on its own, it would silently undo
phase 2 and ship a stock `preempt` kernel with our extlinux. the flash
script backs up the custom RT kernel + modules before `apply_binaries`
and restores them over the stock files afterward, behind a vermagic
gate. if the gate trips, the script aborts before any device write.

#### the initrd carries its own early-boot modules

**Note:** the initrd ships its own copy of the early-boot modules, and
on a preempt_rt kernel those copies must themselves be `preempt_rt`
(or the driver must be built-in), or the device cannot mount its root.
because we build NVMe and PCIe in (`=y`, see the defconfig), no
`nvme.ko` is needed in the initrd at all. the flash script regenerates
the initrd and strips the now-built-in modules from `nv-update-initrd`'s
list. a vermagic gate **and** an initrd gate both run before any device
write; either one aborts the flash if something is inconsistent.

#### root=/dev/nvme0n1p1, not mmcblk0p1

**Note:** the board eMMC default is `root=/dev/mmcblk0p1`. on an
NVMe-only Orin NX that device does not exist, so the kernel waits
forever on `rootwait` for a disk that never appears. there is no error,
just a hang after the boot messages. our extlinux sets
`root=/dev/nvme0n1p1` explicitly, and phase 1 also appends it to the
`p3767.conf.common` `CMDLINE_ADD`.

### first boot

after flash:
1. power off the jetson
2. **remove the recovery jumper** (don't leave the rec/gnd short in
   place)
3. power on

**Note: a blank HDMI screen during boot is normal on Orin.** between
"Exiting boot services" and the desktop you get nothing on the display.
`FRAMEBUFFER_CONSOLE` is off, and `earlycon=efifb` does not help because
the GOP framebuffer is torn down at ExitBootServices. do not read the
dark screen as a failed boot. the real "did it boot" signal is the USB
device-mode gadget (`0955:7020` in `lsusb`): it appears at
`192.168.55.1` (and a `ttyACM` serial console) over the USB-C cable.
judge the boot in that order: gadget, then ping `192.168.55.1`, then
`ssh j@192.168.55.1`. a healthy boot reaches ssh in about 60 seconds.

**Note: the first-boot wizard trap.** `apply_binaries.sh` re-creates
the `/etc/systemd/system/default.target -> nv-oem-config.target`
symlink on EVERY flash. an unseeded flash therefore boots into the
oem-config first-boot wizard, which waits for input BEFORE sshd starts,
with the usb gadget up and answering ping: it looks exactly like a
hang. `04_flash_nvme.sh` now seeds a default user via
`l4t_create_default_user.sh` (the only step that removes the wizard):
`SEED_USER=j` unless explicitly overridden, `SEED_USER=""` opts out.
the flash script hard-fails if the wizard symlink survives seeding.

`jetson-first-boot.service` runs (~3-5 min). what it does, in order:

1. **`personalize_first_boot.sh`**: regenerate ssh host keys, set
   hostname (from `/etc/jetson-av-fleet/device.conf` if staged, else
   from mac), optionally write systemd-networkd file for static ip.
   **Note:** i shipped 5 jetsons without this once. every one
   of them booted with **identical ssh host keys** (baked into the
   stereolabs-flavored rootfs). the moment they were on the same
   network, ssh "host key changed" warnings cascaded everywhere.
   personalize first, always.
2. **apt-mark hold + Pin-Priority -1** for all `nvidia-l4t-kernel*`
   and bootloader packages. **Note:** `apt-mark hold` alone
   is not enough. `apt install nvidia-l4t-kernel-modules=<version>`
   overrides hold. only `Pin-Priority: -1` in
   `/etc/apt/preferences.d/` actually rejects the package.
3. **install our `linux-headers-*.deb`** so dkms-based installers find
   matching headers under `/usr/src/linux-headers-$(uname -r)/`.
4. **build /opt/av-env venv** with `numpy<2.0.0`, pytorch 2.8.0 from
   jetson wheels, voyager sdk pip wheels.
5. **run zed sdk installer** (if `.run` is staged at `/opt/zed-sdk/`)
   in `silent runtime_only skip_python skip_cuda skip_tools
   skip_od_module skip_hub nvpmodel=0` mode.
6. **inject rt boot args** into `extlinux.conf` (idempotent, only
   adds if not present).
7. **run phase 7 (resilience) installer**: see below.
8. **run phase 5 (av stack) installer**: the opencv-cuda build below,
   plus the ros 2 layer ([AV_STACK.md](AV_STACK.md)).

**Note: steps 4, 5, 7 and 8 need internet.** the service re-runs on
every boot and finishes the remaining steps once the device has a
network connection (an ethernet cable is the easy route). a first boot
without network still brings up the kernel / rt /
metis / ssh baseline; the unfinished steps degrade into a logged
failure instead of a wedge (the first-boot unit carries a 1800s start
timeout, the other nv oneshots 120s). this deferral behavior is
live-proven: the reference unit's first boot ran offline, provisioning
deferred cleanly, and once the unit got a wired connection it
completed. `/opt/av-env` is provisioned, voyager 1.6.1 is confirmed
live (the `axdevice --set-power-limit` flag the brownout guard calls is
verbatim in `--help`), and `verify_opengl_cuda.sh` passes 14/14 with
renderer `NVIDIA Tegra Orin (nvgpu)`.

### phase 7, platform hardening

every meaningful piece runs as a systemd service so it survives
restart-after-failure scenarios. installed by
`scripts/install_uav_phase7.sh`, live-verified active on the reference
unit (2026-06-11). the three that earn their keep on this stack:

| service | what it does |
|---|---|
| `jetson-brownout-guard.service` | caps metis at 18W via `axdevice`, polls `lspci -d 1f9d:` every 5s, runs pcie rescan on disappearance |
| `jetson-av-pcie-aer-monitor.service` | polls `aer_dev_*` counters every 5s, emits black-box events on increases |
| `jetson-blackbox.service` | per-session `/var/log/jetson-av/` recording dir with jsonl event log + sha256 hash chain |

all three write events into `/var/run/jetson-av-events` (named pipe),
which the black-box recorder drains into `events.jsonl`. post-mortem
you can correlate "metis disappeared at T+1247s" with "aer correctable
+3 at T+1245s" and know the root cause was electrical, not driver.

the rest of phase 7 is conventional hardening (hardware watchdog,
persistent journald, `/tmp` on tmpfs, logrotate, chrony, ssh key-only,
ufw, smartmontools); the full table is in
[UAV_RESILIENCE.md](UAV_RESILIENCE.md).

### phase 5, opencv with cuda (what the samples need)

(naming note: "phase 5" is the install scripts' numbering,
`install_av_phase5.sh`; it has nothing to do with this post's part 5.)
phase 5 also installs the larger ros 2 / isaac ros layer (documented
in [AV_STACK.md](AV_STACK.md)); the piece part 5 of this post depends
on is the opencv build:

1. **`build_opencv_cuda.sh`**: clones opencv 4.10 + opencv_contrib,
   builds with `-DWITH_CUDA=ON -DWITH_CUDNN=ON -DOPENCV_DNN_CUDA=ON
   -DCUDA_ARCH_BIN=8.7 -DWITH_GSTREAMER=ON -DWITH_NVCUVID=ON
   -DPYTHON3_EXECUTABLE=/opt/av-env/bin/python`. caches the result as
   a `.deb` at `/opt/opencv-cache/` so re-flashing N units doesn't
   rebuild N times, units 2..N pull from the cache.

   **Note:** `apt install python3-opencv` ships **without
   cuda**. every `cv2.cuda.*` call returns 0 cuda devices.
   `cv2.dnn.setPreferableTarget(cv2.dnn.DNN_TARGET_CUDA)` silently
   runs on cpu. for RT vision workloads that's a 10-30x slowdown. you must
   build from source. the c++ fusion sample's `cv::cuda` preprocessing
   needs this build too.

2. **`verify_opengl_cuda.sh`**: confirms libegl_nvidia, glxinfo
   renderer, nvcc, cuda probe binary, trtexec, vpi, libcudnn9,
   `cv2.cuda.getCudaEnabledDeviceCount() > 0`. 14/14 on the reference
   unit.

### per-boot rt tune

`jetson-rt-tune.service` runs **every** boot (these settings are
volatile by hardware design):

```bash
nvpmodel -m $NVPMODEL_MODE        # default 0=MAXN_SUPER (super conf table)
jetson_clocks                     # lock all clocks to max
echo $LOCK_CPU_GOV > .../scaling_governor   # default performance
echo $GPU_TARGET > /sys/class/devfreq/17000000.gpu/{min,max}_freq
echo $EMC_MAX > /sys/kernel/debug/bpmp/debug/clk/emc/rate
echo $FAN_PWM > /sys/devices/platform/pwm-fan/...

# scheduler tuning (CFS knobs: these sysctls DO NOT EXIST on PREEMPT_RT,
# so they are best-effort; an unguarded failure here under set -e used
# to abort the whole service and leave the board untuned)
sysctl -qw kernel.sched_min_granularity_ns=100000 || true
sysctl -qw kernel.sched_wakeup_granularity_ns=100000 || true
sysctl -qw kernel.sched_migration_cost_ns=50000 || true

# transparent hugepages (sysfs path absent in this kernel config,
# also best-effort for the same reason)
echo always > /sys/kernel/mm/transparent_hugepage/enabled || true
echo madvise > /sys/kernel/mm/transparent_hugepage/defrag || true

# pcie always-on
for f in /sys/bus/pci/devices/*/power/control; do echo on > $f; done

# irq pinning
# - core 0: os, nvme, watchdog
# - core 1: metis irqs + inference
# - cores 2-3: zed x csi/vi + ros wrapper (grab/resize/publish need two cores)
# - cores 3-5: slam, nav2, blackbox
# all other Tegra IRQs (host1x, nvenc, nvdec, isp, mipi-cal, vic, nvgpu)
# default to mask 0xC1 (cores 0, 6, 7) so they don't land on isolated cores

# fair-queue qdisc on primary nic for dds multicast
tc qdisc replace dev $PRIMARY_IF root fq

# oom shield for axelera runtime
echo -1000 > /proc/$AXELERA_PID/oom_score_adj
```

**Note:** the gpu devfreq path on r36.x is
`/sys/class/devfreq/17000000.gpu`. **on r35.x it was
`/sys/class/devfreq/17000000.ga10b`.** my script had `.ga10b` for
months. on r36.4.3 the path doesn't exist; the gpu lock silently
no-op'd; gpu was running at scaled-down clocks under load. the
current script tries `.gpu` first, falls back to `.ga10b` for r35.x
support.

`/etc/jetson-av/power.conf` is a single source of truth read by both
rt-tune and the brownout guard:

```sh
NVPMODEL_MODE=0         # super conf table: 0=MAXN_SUPER 1=10W 2=15W 3=25W 4=40W
GPU_MAX_FREQ_HZ=        # empty=hw max; 800000000 to leave EMC bandwidth for Metis
EMC_FREQ_HZ=            # empty=hw max
LOCK_CPU_GOV=performance
FAN_PWM=255
AXELERA_POWER_LIMIT_W=18
```

**Note on mode ids:** the flash installs the orin nx SUPER nvpmodel
conf as the default table, and the ids above are live-verified against
it: `0=MAXN_SUPER, 1=10W, 2=15W, 3=25W, 4=40W`. earlier revisions of
this guide said "mode 4 = MAXN_SUPER"; on the super table mode 4 is the
fixed 40w profile, so that setting silently downgraded the board on
every boot. with mode 0 active the device reports
`NV Power Mode: MAXN_SUPER`, cpu at 1.98 ghz on all cores, emc locked
at max.

maxn_super is the jetpack 6.2 "super mode": up to 157 int8 tops on
the orin nx 16gb. honest caveat: super mode being active on the bench
is not the same as flight-qualified. the safety-critical sustained-load
hv-rail test (field confirm 3.6: 10 minutes under load, v_in ≥10.5v on
a 12v supply, 5v rail ≥4.85v, no tegrastats throttle markers) has not
been run yet. **don't fly on super mode until it passes**; set
`NVPMODEL_MODE=3` (25w) in `power.conf` to hold the board down in the
meantime.

reference budgets:

| profile | nvpmodel | metis cap | gpu | total typical | total peak |
|---|---|---|---|---|---|
| **default** | 0 (maxn_super) | 18w | uncapped | ~45w | ~65w |
| conservative (smaller psu) | 2 (15w) | 15w | 800mhz cap | ~22w | ~33w |
| bench / wall-powered | 0 (maxn_super) | 23w (no cap) | uncapped | ~38w | ~55w |

---

## part 5, inference

this is the payoff, and the order matters: first prove the npu on a
local video file (no camera variables in play), then point it at the
live zed x, then turn every accelerator on at once. each step was
verified live on the reference unit and each one has its own traps.

### opencv with cuda, the smoke test

i covered the build in part 4. before blaming anything else, confirm
the application code actually sees cuda:

```python
import cv2
print('OpenCV:', cv2.__version__)
print('CUDA devices:', cv2.cuda.getCudaEnabledDeviceCount())
print('Has CUDA in build:', 'CUDA' in cv2.getBuildInformation())

# run yolo with dnn_cuda backend
net = cv2.dnn.readNet("/opt/jetson-av/models/yolo.onnx")
net.setPreferableBackend(cv2.dnn.DNN_BACKEND_CUDA)
net.setPreferableTarget(cv2.dnn.DNN_TARGET_CUDA_FP16)
```

if `cv2.cuda.getCudaEnabledDeviceCount()` is 0, opencv was rebuilt
without `-DWITH_CUDA=ON` somewhere. `cv2.getBuildInformation()` shows
the actual flags.

### step 1: inference on a local video file (and the four traps on the way)

start here even if you only care about the camera: a video file is a
deterministic input, so it isolates the npu + runtime from the whole
camera stack. if this step works, every later failure is a camera
problem, not a metis problem.

the headline: **yolov5s-v7-coco at 49.2 fps end-to-end** on a 1080p
video at **13.7% cpu** (the metis does the work), measured live on the
reference unit 2026-06-11 via voyager's `inference.py` and the sample
media shipped in the voyager checkout. getting there took more than
the pip wheels, and every one of these cost real time:

1. **the app framework isn't in the wheels.** `axelera.app` lives in
   the voyager-sdk checkout, not in `axelera-rt`/`axelera-devkit`.
   install `requirements.application.txt` into `/opt/av-env`, **minus
   `opencv-python`** (it shadows your cuda cv2 build; one `pip install`
   and `cv2.cuda` is gone, troubleshooting P-6) **and minus `pyopencl`**
   (no opencl runtime on jetson; skipping it is a harmless warning).
2. **the gstreamer operators are a source build.** `make operators` in
   the voyager checkout with `AXELERA_RUNTIME_DIR` pointing at the
   venv's `site-packages/axelera`. extra apt deps found by trial on l4t
   r36.4.3: `ninja-build opencl-headers ocl-icd-opencl-dev libsimde-dev`.
3. **the decode workaround.** file/rtsp sources die `not-negotiated`:
   nvidia's `nvv4l2decoder` outputs NVMM-memory caps the axelera
   elements can't consume. run with
   `GST_PLUGIN_FEATURE_RANK=nvv4l2decoder:NONE` to force software
   decode. camera-generator sources (the zed x demo) are unaffected.
   true nvmm/dmabuf zero-copy into the axelera elements doesn't
   negotiate on this voyager build and remains a design goal
   ([DMABUF_ZEROCOPY.md](DMABUF_ZEROCOPY.md)).
4. **the first run compiles the model.** ~17 minutes for yolov5s,
   then cached. related trap: the app api
   (`create_inference_stream`) defaults to `aipu_cores=1`, which is a
   *different artifact* than `inference.py`'s 4-core default. pass
   `aipu_cores=4` or you trigger a full recompile.

the working invocation:

```bash
cd ~/voyager-sdk
GST_PLUGIN_FEATURE_RANK=nvv4l2decoder:NONE PYTHONPATH=$PWD DISPLAY=:0 \
  /opt/av-env/bin/python inference.py yolov5s-v7-coco media/h264/traffic1_1080p.mp4
# summary: ~49 fps end-to-end, <15% cpu
```

### step 2: the live zed x camera, python then c++

this is the part i'd actually demo. all commands + expected outputs in
[SAMPLES.md](SAMPLES.md). two ways to drive the camera into the npu,
in increasing order of throughput:

**python: live zed x → metis** (`scripts/demo_zedx_metis.py`, runs the
camera as a voyager frame generator):

| camera mode | end-to-end fps | limiter |
|---|---|---|
| HD1200@30 | 29.6 | camera frame rate |
| HD1200@60 (default) | 37.3 | python copy chain (pyzed→numpy→BGR) |
| SVGA@120 | **53.3** | npu pipeline |

the HD1200@60 gap to the npu's ~49 fps video rate is the cpu copies in
the frame generator. see the zero-copy note above.

**c++: `examples/zedx_metis_cpp/zedx_metis_infer`**: same pipeline
without the app framework: zed sdk grab, host letterbox + int8
quantize, batch-4 model on the metis via `libaxruntime`, host decode +
nms. supports yolov5s (anchor decode) and yolov8s (anchor-free dfl
decode), auto-detected from the artifact. measured headless 2026-06-11:

| camera mode | yolov5s c++ | yolov8s c++ | python (v5) |
|---|---|---|---|
| HD1200@30 | 30.0 | - | 29.6 |
| HD1200@60 | **56.4** | **57.4** | 37.3 |
| SVGA@120 | **74.7** | **95.7** | 53.3 |

with display at HD1200@60: ~47 fps yolov8s / ~35 fps yolov5s. and the
number that matters for an av stack: **the detector costs zero gpu**:
~25% GR3D during the live run, all of it zed rectification +
compositor. the gpu is entirely free for depth, slam, and mapping.

three model artifacts deploy out of the box: `yolov5s-v7-coco` and
`yolov8s-coco` run batch-4 (one frame per aipu core); `yolov8l-coco`
(~52.9 coco map, the accurate one) is big enough that the compiler only
fits one copy, so it runs single-core batch-1: 37.9 fps at HD1200@60,
npu-limited. the samples auto-resolve the `4/`, `2/`, or `1/` core
artifact dir, so `--model yolov8l-coco` just works.

### step 3: full sensor fusion, every accelerator at once

**`zedx_metis_fusion`** (same cmake build) is the finished thing: a
3-stage pipeline that keeps the gpu, the npu, and the cpu busy
concurrently, detection still off the gpu:

- **metis npu**: yolov5/v8 detection (auto-detected per model)
- **gpu/cuda**: zed rectification + NEURAL_LIGHT stereo depth + xyz
  point cloud + the `preprocess.cu` letterbox/int8-quantize kernel
- **gpu/dla**: skeleton/body tracking via the zed ai module
  (`HUMAN_BODY_FAST`, BODY_18, fp16), independent of the metis;
  `--no-bodies` turns it off
- **imu**: sdk-fused world pose + raw rates on the hud, plus a
  bottom-left isometric gizmo drawing the live linear-acceleration
  3-vector (gravity at rest, deviating as the camera moves)
- **cpu**: decode + nms, the 3d fusion, and an IoU tracker that gives
  every box a stable id, velocity, and time-to-collision. per
  detection it samples the point-cloud patch and labels the box with
  the median distance

boxes are color-coded per class; persons get a red head band with its
own distance so a planner can treat it as a keep-out zone; skeletons
draw as cyan bones + yellow joints with a track id. all buffers
preallocated, zero per-frame allocation.

```bash
cd examples/zedx_metis_cpp
cmake -B build && cmake --build build       # ~30 s
# all features, fast and smooth (runs until Esc; --seconds N caps it):
DISPLAY=:0 sg zed -c './build/zedx_metis_fusion --model yolov8s-coco --depth-every 3'
```

**`--depth-every N` is the single biggest tuning lever**, and it's how
the fusion app stopped being gpu-capped. the only heavy igpu consumers
are stereo depth (computed inside `grab()`) and the body net; left at
every-frame they gate the whole pipeline. `--depth-every N` runs them
on every Nth grab while detection, display, and pose run every frame.
nothing is lost: the last depth slab and skeletons carry forward and
the tracker smooths distance/velocity/ttc between refreshes. the bench
harness puts yolov8s fusion at HD1200@60 at **35 fps** with depth
every frame and **53 fps** at every 6th, all features live; `N=3` is
the recommended balance. yolov8l is the exception: it caps at 37-39
fps regardless of cadence because its single-core metis inference, not
depth, is the bottleneck. skeletons are a real but modest cost
(`--no-bodies` at N=3: ~44 vs ~46 fps, gpu peak 77% vs 86%).

useful flags beyond that: `--record out.mp4` writes an annotated h.264
mp4 through the orin's hardware **nvenc** encoder (gstreamer, with a
software fallback), `--record-fps N` tags the file with the run's
sustained rate so playback is realtime, `--headless` drops the window
for max throughput, and `--publish HOST:PORT` streams detections as
udp json for whatever consumes them.

power and thermals under the full load: up to **17.3 W** and 98% GR3D
peak at depth-every-frame, ~60-61 C with no throttling. detector-only
runs sit at 13.5-14 W and ~24% GR3D.

every number above is reproducible: `scripts/bench_zedx_metis.sh`
sweeps the configurations headless and
`scripts/plot_zedx_metis_bench.py` renders the charts, both committed
with the raw csv in [BENCHMARKS.md](BENCHMARKS.md). the full
architecture walkthrough (the 3-stage pipeline, `--aipu-cores`
semantics, the flag reference, the udp schema) is in
[ZEDX_METIS_CPP.md](ZEDX_METIS_CPP.md).

**beyond the samples**: the same hardware also runs a full ros 2
humble + isaac ros mission graph (zed wrapper, the detect node
publishing `/detections`, cuvslam, nav2) live under systemd, with the
metis detection still off the gpu. that layer is its own post; the
install, the live-verified graph run, and the dds tuning numbers are
in [AV_STACK.md](AV_STACK.md).

### axrun, for ad-hoc inference runs

the boot-time services do proper core pinning on their own. anything
you launch by hand, including every sample in this part, should land
on the right core too; the `axrun` wrapper does it for you:

```bash
# default: core 1, oom-shielded, no rt priority
axrun /opt/av-env/bin/python scripts/demo_zedx_metis.py

# rt priority for hard-deadline loops
axrun --rt --cpu 1 ./hard_realtime_loop
```

without it, your interactive run lands on whatever core the scheduler
picks, often a non-isolated one, and you get ±300µs jitter for no
reason.

a note on model artifacts, because earlier drafts of this guide got it
wrong: voyager 1.6 deploy artifacts are **relocatable directories**
with a `.axnet` runtime descriptor inside, not single `.ax` files.
compile once with `deploy.py <network> --aipu-cores 4` (anywhere:
artifacts copy across machines) and point the c++ samples at the
staged copy with `--model-root` if it lives outside the voyager
checkout.

---

## part 6, validation

### the validation gauntlet

```bash
make verify
```

ssh's to the jetson and runs `verify_tuning.sh` which:

- **kernel identity**: `uname -r` ends in `-tegra`
- **cpu isolation**: `/sys/devices/system/cpu/isolated == 1-5`
- **tickless mode**: `nohz_full=1-5` in `/proc/cmdline`
- **cma reservation**: `CmaTotal` matches the device tree pool
  (262144 kB / 256 mb on this image) and `/proc/cmdline` contains no
  `cma=` override (a cmdline `cma=` zeroes the pool and breaks gpu
  init, see part 2)
- **vermagic on every loaded `.ko`**: walks
  `/lib/modules/$(uname -r)/` via `find -name '*.ko*'`, modinfo each,
  fail if any module's vermagic doesn't contain `$(uname -r)`
- **mission-critical drivers loaded**: based on
  `/etc/jetson-av/expectations.conf`:
  ```sh
  EXPECT_METIS=1
  EXPECT_ZED_X=1
  EXPECT_MAX9296=1
  ```
  loud red FAIL when expected and not loaded; silent pass when not
  expected (botany-only airframe sets `EXPECT_ZED_X=0`)
- **hardware presence**: `lspci -d 1f9d:`, `lsmod | grep`,
  `/dev/dma_heap/`
- **power mode**: `nvpmodel -q` reports `MAXN_SUPER` (mode 0 on the
  super conf table)
- **thermal**: no `/sys/class/thermal/cooling_device*/cur_state > 0`
- **rt jitter**: 10s `cyclictest` burst on core 1, max < 100µs.
  measured avg on the reference unit: ~3µs. run this gate **headless**:
  an interactive desktop session adds ~150µs ipi spikes (known, not a
  kernel regression. log out of the gui before judging the kernel)
- **/opt/av-env**: `axelera.runtime` importable, `torch.cuda.is_available()`,
  `pyzed.sl` importable

exits 0 only on full green. perfect for ci or for `make ignite`
post-flash settle. one timing note: the `/opt/av-env` import checks
need first-boot provisioning to have completed with network access
(see part 4). on a unit whose first boot ran offline that step stays
red until the device gets a connection and the first-boot service
finishes; the kernel / rt / hardware checks above it are independent.
on the reference unit provisioning is complete and the gauntlet passes,
with the separate `verify_opengl_cuda.sh` at 14/14.

### scaling past one unit

once one board passes the gauntlet, the repo has the whole
build-once-flash-N story: signed release tarballs (`make release`),
batch flashing from a `fleet.csv` (`make flash-batch`), and
bit-identical golden-image cloning with per-device identity
(`make clone-golden` / `make flash-golden`), every step traceable back
to the git commit via manifests + sha256. that workflow is documented
in [RUNBOOK.md](RUNBOOK.md); this post stays focused on getting the
first unit right.

---

## part 7, troubleshooting catalog

symptom-first, in the order you're most likely to hit them.

### build / extract failures

| symptom | root cause | fix |
|---|---|---|
| `wget: 404 Not Found` on bootlin url | nvidia moved toolchain to `r36_release_v3.0/` | use the `v3.0` url, not `v5.0` (Dockerfile is fixed) |
| `cp -r ../zedx-driver/...: No such file or directory` | stereolabs repo doesn't exist publicly | get source via business agreement, or skip ZED X |
| `aarch64-buildroot-linux-gnu-gcc: command not found` | running phase 2 outside docker | `make docker-build` then `make build` |
| `No board config matches '$TARGET_BOARD'` (doctor) | wrong board target in `versions.env` | use `jetson-orin-nano-devkit` for Orin NX 16GB, NOT `-super` |
| dtbo missing in `/boot/` after build | nvidia silently skipped `dtbo-y` | `02_build_kernel.sh` direct-compile path; verify with `ls latest_jetson/Linux_for_Tegra/kernel/dtb/*-sl-overlay.dtbo` |
| `make audit` fails at "Module Vermagic" | partial vermagic drift | `make clean && make all`: never partial rebuild after kernel CONFIG change |
| `make build` fails at `bindeb-pkg` | missing `dpkg-dev`/`fakeroot` | `apt install dpkg-dev fakeroot` in docker image |
| `linux-headers-*.deb` not produced | bindeb-pkg failed (warning, not fail) | DKMS-based installers will fail on target; rebuild |

### flash failures

| symptom | root cause | fix |
|---|---|---|
| flash hangs at "Waiting for target to boot-up" | rndis gadget not enumerated on host | `lsusb -t` (no hub), `modprobe rndis_host`, autosuspend off |
| Error 3 / 202 | usb chain (hub, autosuspend, weak cable) | direct rear motherboard port, `echo -1 > /sys/module/usbcore/parameters/autosuspend` |
| ECID blank / device not in apx | jetson didn't enter recovery | power off, re-short rec+gnd, re-power |
| flash succeeds, no boot | wrong board target (`-super` vs no `-super`) | update `versions.env`, re-flash |
| flash succeeds, ssh "host key changed" warning on every device | personalize_first_boot didn't run / regenerate keys | check `/etc/jetson-av-personalized` exists; if not, run manually + reboot |

### vermagic / module loadability failures

| symptom | root cause | fix |
|---|---|---|
| `dmesg \| grep "Invalid module format"` | vermagic mismatch | identify the module, rebuild from clean tree |
| `lsmod \| grep <name>` empty but `.ko` is on disk | modprobe failed silently | `modinfo <ko> \| grep vermagic` vs `uname -r`; if mismatched, full rebuild |
| ZED SDK install fails to build sl_zedx.ko | linux-headers-*.deb not installed on target | `dpkg -i /opt/kernel-headers/linux-headers-*.deb` then re-run installer |
| Loaded modules look fine but driver behaves wrong | per-symbol CRC drift (CONFIG_MODVERSIONS) | rebuild from clean tree (force-load isn't allowed and shouldn't be) |
| First boot looks hung (gadget up, ping OK, no sshd) | unseeded flash booted into the oem-config wizard, which waits for input before sshd starts; or a oneshot service wedged | seed a user at flash (`SEED_USER`, the flash script hard-fails if the wizard symlink survives); wedged oneshots time out into logged failures (first-boot 1800s, other nv oneshots 120s): `journalctl -u jetson-first-boot.service` from the usb serial console |

### hardware enumeration failures

| symptom | root cause | fix |
|---|---|---|
| `lspci -d 1f9d:` empty (Metis ghost) | LINK_WAIT_MAX_RETRIES too low for cold boot | the patch sets it to 200; verify in source, rebuild if not |
| `lspci \| grep axelera` empty but `lspci -d 1f9d:` works | older `lspci` doesn't have the vendor name in its db | use the vendor:device id form |
| `v4l2-ctl --list-devices` shows nothing for ZED X | dtbo overlay didn't apply | check `OVERLAYS` line in `extlinux.conf` and `.dtbo` exists in `/boot/` |
| ZED X frames appear but stereo depth is garbage | wrong deserializer (MAX96712 instead of MAX9296) | `01_extract_and_patch.sh` enforces both defconfig + Makefile sed |
| MAX9296 dmesg errors / no frames | ISP `.isp` calibration missing or for wrong sensor | check `/var/nvidia/nvcam/settings/`, verify sensor variant |
| GPU devfreq operations silently fail | path is `.gpu` on R36.x, not `.ga10b` | `jetson_rt_tune.sh` probes both; older revisions only had `.ga10b` |

### runtime failures

| symptom | root cause | fix |
|---|---|---|
| cyclictest max latency > 1ms | RT boot args missing OR governor wrong | `cat /proc/cmdline` must contain `isolcpus=1-5 nohz_full=1-5 rcu_nocbs=1-5`; CPU governor must be `performance` |
| Performance tanks mid-mission | thermal throttling | `cat /sys/class/thermal/thermal_zone*/temp`; add active cooling |
| Inference latency too high | inference process not pinned | use `axrun` (or `systemd-run --scope -p AllowedCPUs=1`) |
| `cv2.cuda.getCudaEnabledDeviceCount() == 0` | OpenCV was apt-installed without CUDA | rebuild with `build_opencv_cuda.sh` |
| `glxinfo` reports `llvmpipe` | nvidia-l4t-3d-core missing | `apt install --reinstall nvidia-l4t-3d-core` |
| Voyager pip install 404 | URL missing `/api/pypi/<repo>/simple` suffix | fixed in `versions.env` and `jetson_first_boot.sh` |
| `inference.py` dies `not-negotiated` on file/RTSP sources | `nvv4l2decoder` outputs NVMM-memory caps the Axelera elements can't consume | `GST_PLUGIN_FEATURE_RANK=nvv4l2decoder:NONE` (software decode); camera-generator sources unaffected |
| `cv2` import dies `numpy.core.multiarray failed to import` after installing Voyager app deps | `opencv-python` from `requirements.application.txt` shadowed the CUDA cv2 build (and pulled numpy 2) | install the requirements minus `opencv-python` (and `pyopencl`); TROUBLESHOOTING P-6 |
| first inference run looks hung for ~17 min | first-use model compile (yolov5s), cached afterwards | wait it out once; and pass `aipu_cores=4` to `create_inference_stream` or you trigger a full recompile (the app API default is 1, `inference.py`'s is 4) |
| a CUDA pip build (`mmcv` etc., pulled by some model deploys) dies with a bare `Killed`; `journalctl -k` shows `Out of memory: Killed process (cicc)` | the baked image ships zero swap (ZRAM is deliberately off for rt determinism) and CUDA extension builds fan out `nvcc`/`cicc` at ~2 gb per source file | add a low-swappiness NVMe swapfile (`fallocate -l 16G /swapfile`, `vm.swappiness=10`) and/or cap the build: `MAX_JOBS=2 TORCH_CUDA_ARCH_LIST=8.7`; full recipe in TROUBLESHOOTING B-7 |
| fusion sample laggy / "duplicate frame" warnings at SVGA | camera at 120 fps outpaces what the pipeline drains | run SVGA at `--fps 60`; surplus capture rate only builds latency |
| fusion fps capped in the 20s-30s with every feature on | depth + body net gating every frame on the igpu | `--depth-every 3` (detection/display/pose still run every frame; tracker carries distance/velocity between refreshes) |
| TPM HW random not feeding entropy pool | wrong CONFIG name (TPM_HW_RANDOM vs HW_RANDOM_TPM) | defconfig uses `HW_RANDOM_TPM=y` |

---

## closing

### what this is and isn't

it's the artifact you need to run metis + zed x + nvme on an orin nx
16gb doing real-time computer vision without it falling apart on cold
boot or a brownout. as of 2026-06-11 the reference unit runs the whole
thing live: rt kernel, metis at 49.2 fps end-to-end on video, the c++
samples at 37-96 fps on the live camera, the fusion sample at 46-53
fps with every feature on, and the resilience services watching the
pcie bus. the open items are exactly the ones listed in the
verification status up top, no hidden "works on my machine" gaps.
every magic value in here was verified against vendor docs (the
corrections list is in `docs/VERIFICATION_REPORT.md` with source
urls). every measured number has a reproducible harness behind it.
every script passes `bash -n`. every gate is reproducible.

it's not a beginner course. it's not a click-through tutorial. you
need to know what `make` does, you need to be willing to read kernel
defconfig, you need to be comfortable when `dmesg` is the only thing
between you and the answer.

if you want the click-through version, the original community
tutorial is still there and still works for "get something that boots
with metis visible".

### the repo

**https://github.com/silicondoritos/jetson-rt-stack**: apache 2.0.

contributions welcome. file an issue with the bug-report template;
include `make logs` output if you have it. the bar for prs is
documented in `CONTRIBUTING.md`.

### acknowledgments

- the **axelera team** (especially whoever wrote the bring-up guide
  and `axl-jetson.patch` 6+ months ago, none of this exists without
  that starting point).
- **nvidia jetson linux team** for l4t r36.4.3 + the public sources.
- **stereolabs** for the zed x platform.
- the **linux kernel** + **preempt_rt** communities, every line of
  this is built on their work.
- everyone who asked questions on the original Axelera community
  thread, those questions drove most of what's in this post.

### contact

open a github issue or discussion at [github.com/silicondoritos/jetson-rt-stack](https://github.com/silicondoritos/jetson-rt-stack).
the work is open source (apache 2.0) so anyone who needs this can fork
it and grow their own internal expertise. that's the point.

one thing i'd genuinely like back from the community: if your numbers
differ from the tables in [SAMPLES.md](SAMPLES.md) on a different
carrier or sdk version, post them. comparative data is how the
troubleshooting catalog grows.

if you build something with this and it flies, say so in a github issue. seriously.
