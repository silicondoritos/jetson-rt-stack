# jetson-rt-stack: Custom RT Jetson Orin NX 16GB image with Metis + ZED X + Isaac ROS

> Jetson PREEMPT_RT firmware stack: Metis + ZED X + Isaac ROS

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![L4T](https://img.shields.io/badge/L4T-R36.4.3-76B900.svg)](https://developer.nvidia.com/embedded/jetson-linux-r3643)
[![JetPack](https://img.shields.io/badge/JetPack-6.2-76B900.svg)](https://developer.nvidia.com/embedded/jetpack)
[![Kernel](https://img.shields.io/badge/kernel-5.15--tegra-orange.svg)](docs/VERMAGIC_STRATEGY.md)
[![Pages](https://img.shields.io/badge/docs-silicondoritos.github.io-success.svg)](https://silicondoritos.github.io/jetson-rt-stack/)

📖 **Full documentation site**: [silicondoritos.github.io/jetson-rt-stack](https://silicondoritos.github.io/jetson-rt-stack/): same content, with sidebar navigation, search, and code highlighting. The complete tutorial and a [grouped map of every doc](https://silicondoritos.github.io/jetson-rt-stack/#documentation) live there.

---

A complete, audited, repeatable build pipeline for a custom **PREEMPT_RT** L4T
R36.4.3 image targeting the **Jetson Orin NX 16GB**, live-verified end to end
on the reference device (2026-06-11). Two independent layers:

**Layer 1, Baseline (Phases 1 to 4).** Everything needed to run Axelera Metis
inference on an NVMe-booted Jetson, with RT isolation. No camera or flight
controller required. `make verify` passing = done (note: the `/opt/av-env` import check inside
`make verify` passes only after first-boot provisioning has completed with internet
access, see Phase B below).

- **Axelera Metis M.2** (PCIe Gen3 x4): in-tree driver, Voyager SDK pip wheels. Verified live: enumerated at `0004:01:00.0`, bound to the `metis` driver; 49.2 FPS end-to-end inference on 1080p video at 13.7% CPU.
- **NVMe boot**: `flash_l4t_t234_nvme.xml`, btrfs data partition. Verified live: rootfs on `/dev/nvme0n1p1` (ADATA XPG GAMMIX S55 2 TB).
- **Realtek RTL8822CE** Wi-Fi/BT, M.2 Key E. The build blacklists the in-kernel `rtw88`; the vendor `rtl8822ce` driver is staged but **not** autoloaded by default (opt in with `WIFI_AUTOLOAD=1` at bake). NetworkManager credentials are staged; bring-up is `sudo modprobe rtl8822ce`.
- **PREEMPT_RT kernel**: CPU isolation 1-5, MAXN_SUPER clocks locked per-boot. Verified live: `uname -v` shows `SMP PREEMPT_RT`, `/sys/kernel/realtime` = 1.

**Layer 2, RT Vision Extension (Phases 5 to 7, all optional).** Adds camera,
flight controller, and operational hardening on top of the baseline. Phase 5
is installed and verified live on the reference device (2026-06-11), as are
Phase 7's resilience services (black-box, brownout guard, PCIe AER monitor);
Phase 6 (fleet manufacturing) ships as scripts and remains unexercised:

- **Stereolabs ZED X** stereo camera via **ZED Link Mono** (MAX9296A GMSL2), verified live: 29.5 FPS stereo + CUDA depth (see `scripts/install_zedx_daemons.sh`)
- **C++ camera-to-NPU samples**: a lean detector at 37 to 92 FPS on the live camera and a full sensor-fusion app (detection + depth + skeletons + IMU pose + tracking) at 46 to 53 FPS with all features via `--depth-every`, plus NVENC `--record`. See [`docs/ZEDX_METIS_CPP.md`](docs/ZEDX_METIS_CPP.md) and the measured dataset in [`docs/BENCHMARKS.md`](docs/BENCHMARKS.md)
- **ROS 2 Humble + Isaac ROS + Nav2**: cuVSLAM visual SLAM, nvblox 3D occupancy, Hybrid A* planning. Installed from apt (Isaac ROS 3.2, `isaac.download.nvidia.com` repo); mission dry-run spawns all 6 nodes
- Fleet manufacturing + golden-image clone workflow for N identical units (not yet exercised)

**Hardware**: Jetson Orin NX 16GB on any P3509-class carrier. Set `TARGET_BOARD`
in [`versions.env`](versions.env) if yours differs from `jetson-orin-nano-devkit`.
Do **not** use `jetson-orin-nano-devkit-super`: that suffix selects the Orin **Nano**
power-table and misconfigures the NX power profile (see
[`docs/VERIFICATION_REPORT.md`](docs/VERIFICATION_REPORT.md) §1.1).

**NX Super Mode (up to 157 TOPS)**: As of JetPack 6.2 (L4T R36.4.x+) NVIDIA added
Super Mode to the Orin NX 16GB: a new fixed 40 W budget mode plus an uncapped
`MAXN_SUPER` profile above it, raising the ceiling from 25 W / 100 TOPS to up to
**157 TOPS**. This build installs the SUPER nvpmodel table as the default and boots
into MAXN_SUPER, which is **mode 0** in that table
(live-verified IDs: 0=MAXN_SUPER uncapped, 1=10W, 2=15W, 3=25W, 4=40W fixed).
**Prerequisite**: verify your carrier exposes the HV power rail and is rated for 40 W
or more sustained before enabling it, see [`docs/VERIFICATION_REPORT.md`](docs/VERIFICATION_REPORT.md) §1.10.
MAXN_SUPER is absent on JetPack 6.0 and 6.1.

**Long-form guide**: [`docs/COMMUNITY_POST.md`](docs/COMMUNITY_POST.md), every command, every gotcha, every war story for getting this stack
into production. Built from the original Axelera community bring-up guide,
extended to a fleet-deployable, validated, RT-tuned image.

> **First time here?** Read [docs/QUICKSTART.md](docs/QUICKSTART.md) to go from a clean Ubuntu host to a flashed Jetson in 90 minutes.
> **Wondering where the tarballs and NDA trees come from?** [docs/THIRD_PARTY.md](docs/THIRD_PARTY.md) inventories every external input, its source, and its placement.
> **Operating it?** [docs/RUNBOOK.md](docs/RUNBOOK.md) has decision trees for repeat deployments and recovery.
> **Want the full story?** [docs/COMMUNITY_POST.md](docs/COMMUNITY_POST.md): the long-form guide.
> **Just want a list of commands?** `make help` (or `make list-targets` for everything).
> **Pin manifest?** `make versions` reads [`versions.env`](versions.env).

## Acknowledgments

- The Axelera team, especially the bring-up guide and `axl-jetson.patch`
  that started this work.
- NVIDIA Jetson Linux team for L4T R36.4.3 + the public sources.
- Stereolabs for the ZED X / ZED Link Mono platform.
- The Linux kernel + PREEMPT_RT communities.
- Everyone who contributed questions and issues that drove this work.

Licensed under the **Apache License, Version 2.0**: see
[`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).

---

## 1. Hardware Topology (What We Know)

The Jetson Orin NX 16GB Devkit carrier board is the physical foundation. We have mapped the peripherals to their specific hardware interfaces:

| Peripheral | Interface | Purpose |
|------------|-----------|---------|
| **NVMe Boot SSD** | M.2 Key M (2280) | Primary OS storage (PCIe Gen4 x4 per SoC; actual BW depends on carrier lane routing) |
| **Axelera Metis M.2** | M.2 Key M (2280) | AI Inference Accelerator (PCIe Gen3 x4); PCI ID `1f9d:1100` |
| **Realtek Module** | M.2 Key E (2230) | Wi-Fi & Bluetooth (PCIe x1 + USB) |
| **ZED Link Mono** | MIPI CSI-2 (Ribbon) | Capture card for ZED X Stereo Camera (GMSL2) |

---

## 2. Software Architecture (What We Know)

### 2.1 The Zero-Copy DMABUF Pipeline (Architectural Intent)

This is the target architecture. End-to-end dma_buf trace confirming zero
CPU memcpy on the actual hot path has not been published; treat this as
a design goal until a verification artifact (dma_buf trace / perf
flamegraph) is added.

1. The ZED X driver allocates a **DMA Buffer** (`CONFIG_DMABUF_HEAPS_CMA`) and passes a File Descriptor (FD) to userspace.
2. The ZED Link Mono hardware writes raw camera frames directly into that RAM block via MIPI CSI.
3. The Jetson Hardware ISP reads the raw buffer and writes the processed RGB frame into a second DMA buffer.
4. The GStreamer pipeline or C++ application (`AxRuntime`) takes the FD of the RGB buffer and passes it to the Axelera driver.
5. The Axelera Metis DMA engine pulls the RGB frame directly from the Jetson's RAM across the PCIe bus into its AIPU.

### 2.2 Kernel Lobotomization & Real-Time Tuning
To guarantee deterministic execution and eliminate jitter, the kernel must be tuned for real-time (RT) operation:
- `PREEMPT_RT` patch ensures kernel code can be preempted.
- `CONFIG_NO_HZ_FULL=y` stops the scheduler clock ticks on isolated CPU cores.
- `nohz_full=1-5 isolcpus=1-5 rcu_nocbs=1-5 irqaffinity=0` boot parameters isolate cores 1-5 for inference pipelines, forcing core 0 to handle all system interrupts and OS garbage.
- `efi=noruntime` disables UEFI runtime services, which NVIDIA confirms cause latency spikes on RT kernels.

### 2.3 Driver Specifics
- **Stereolabs ZED X**: now built **in-tree** under `drivers/media/i2c/zedx/` via a Kconfig+Kbuild shim that symlinks back to the canonical `source/stereolabs/`. The deserializer is enforced to MAX9296 in both the defconfig (`CONFIG_SL_DESER_MAX9296=m`) and the vendor Makefile (`-DCONFIG_SL_DESER_MAX9296`). The device-tree overlay is staged into `extlinux.conf` at bake. **End-to-end capture verified live (2026-06-11)**: pyzed opens the camera (HD1200@30), stereo at 29.5 FPS sustained, CUDA depth maps working, after three pieces the SDK installer does NOT provide: the BMI088/SPSC IMU kernel modules, the vendor daemons (`ZEDX_Driver`/`ZEDX_Daemon`/`IMU_Daemon`), and the patched `libnvisppg.so` ISP library (stock R36.4.x renders soft). All automated by `scripts/install_zedx_daemons.sh`. See `docs/DRIVERS.md` §1.4-1.5 and `docs/TROUBLESHOOTING.md` H-5/H-6.
- **Axelera Metis**: Axelera ships the Metis kernel module out-of-tree (DKMS-style). This build instead promotes it **in-tree** under `drivers/misc/axelera/`, so its vermagic matches the RT kernel by construction; the vendor source stays canonical at `source/axelera/axelera-driver/`. The build raises the DesignWare PCIe `LINK_WAIT_MAX_RETRIES` to 200 (see [`plugins/axelera`](plugins/axelera)) so the Metis link trains on colder boots. Voyager SDK userspace ships as pip wheels (numpy <2.0.0). See `docs/DRIVERS.md` §3.
- **ZED SDK**: userspace lives under `/usr/local/zed/`; installed at first-boot in `runtime_only` mode by `scripts/install_zed_sdk.sh` (the SDK's bundled GMSL2 `.ko`/`.dtb` is skipped because this build owns a vermagic-aligned in-tree driver). See `docs/DRIVERS.md` §2.

### 2.4 Vermagic Discipline
A custom RT kernel ships an incompatible vermagic with **every** stock NVIDIA / Stereolabs / Axelera pre-built module. Three-layer defense:

1. **In-tree build** of Metis + ZED X (vermagic match guaranteed by construction).
2. **Vermagic-aligned `linux-headers-5.15.x-tegra_*.deb`** produced in Phase 2, staged in Phase 3, installed at first-boot, DKMS-based third-party installers find headers under `/usr/src/linux-headers-$(uname -r)/`.
3. **Hard gates** at end of Phase 2 (`verify_vermagic.sh --build-tree`), in `pre_flash_audit.sh` (`--rootfs`), and on the live target in `verify_tuning.sh`. Any drift fails the audit before flashing.

Full strategy: `docs/VERMAGIC_STRATEGY.md`.

---

## 3. The Execution Plan (What We Need To Do)

This repository is designed for absolute, zero-touch automation via `Makefile`, encapsulated in a `Docker` container, and deployed via `systemd`. **Any AI agent inheriting this repository should default to using the `Makefile` targets.**

### Phase A: Host-Side Automation (The Makefile)

The full automation surface is exposed via Make. Run `make help` for the menu.

**Discovery & preflight**
*   **`make versions`**: print the pin manifest (versions, paths, USB IDs, RT tuning).
*   **`make doctor`**: preflight: confirm tarballs, external trees, host packages, Docker, sudo, network, *before* you waste 90 minutes on a doomed build.

**Build pipeline**
*   **`make docker-build`**: build the isolated Ubuntu 22.04 cross-compilation container (Bootlin toolchain, build tools).
*   **`make docker-shell`**: interactive shell inside the build container.
*   **`make extract`**: Phase 1: extracts L4T R36.4.3, applies all patches (PCIe retries, MAX9296, ZED X overlay, in-tree promotion of Metis + ZED X), injects defconfig (RT, CMA, DMABUF, hardening).
*   **`make build`**: Phase 2: cross-compiles kernel + every module + the `linux-headers-*.deb`. Captures `EXPECTED_VERMAGIC`, runs vermagic gate, writes `BUILD_MANIFEST.json`.
*   **`make bake`**: Phase 3: stages payloads (Voyager SDK, ZED SDK installer if present, ISP cals, headers .deb, systemd services) into the rootfs; injects RT boot args + ZED X overlay into `extlinux.conf`.
*   **`make audit`**: pre-flash gate. Vermagic + RT cmdline + DTBO presence. Exits non-zero on failure (CI-friendly).
*   **`make flash`**: Phase 4: writes NVMe via `l4t_initrd_flash.sh`. Requires Jetson in recovery mode (APX `0955:7323`). `apply_binaries` installs the stock kernel, so the flow backs up the custom RT kernel + modules and restores them over it; it then regenerates the initrd (NVMe is built-in, so no `nvme.ko` is needed and the now-built-in modules are stripped from `nv-update-initrd`'s list) and sets the SUPER nvpmodel conf (mode 0 = MAXN_SUPER) as default. The flash also seeds the default user (`SEED_USER=j` unless overridden; set `SEED_USER=""` to opt out), which removes the oem-config first-boot wizard symlink that `apply_binaries.sh` re-creates on every flash; the script hard-fails if that symlink survives, because an unseeded flash boots into the wizard and waits before sshd, looking exactly like a hang. A vermagic gate and an initrd gate abort before any device write if anything is inconsistent.

**Composition**
*   **`make all`**: extract → build → bake.
*   **`make ignite-no-flash`**: doctor → all → audit. The full host-side pipeline; hardware not required.
*   **`make ignite`**: doctor → all → audit → flash → post-flash-validate. End-to-end.

**Validation & support**
*   **`make verify`** / **`make post-flash-validate`**: SSH to Jetson and run the full gauntlet (RT kernel active, isolcpus, CMA, vermagic of every critical module, lspci/lsmod hardware, /opt/av-env, ZED SDK, cyclictest p99 max < 100 µs, see [RT tuning](docs/RT_KERNEL_OPTIMIZATION.md) for full test conditions). The `/opt/av-env` import step fails until first-boot provisioning has completed online; the first-boot service re-runs each boot and finishes provisioning once the device has a network connection.
*   **`make headers`**: rebuild just the `linux-headers-*.deb` (useful when changing CONFIG_*).
*   **`make logs`**: bundle every log + manifest + remote dmesg/journal into a `support-bundle-*.tar.gz` for support requests.
*   **`make clean`**: remove `latest_jetson/` workspace.
*   **`make distclean`**: clean + remove Docker image + remove all logs/manifests.

### Phase B: Target-Side Execution (Zero-Touch Boot)

When the Jetson Orin NX boots for the first time after flashing, no manual login is required.

> **"Did it boot?"** A blank HDMI display between "Exiting boot services" and the desktop is **normal** on Orin: `FRAMEBUFFER_CONSOLE` is off, and `earlycon=efifb` does not help because the GOP framebuffer is torn down at `ExitBootServices`. Judge boot health by the USB device-mode gadget (`0955:7020`), then ping `192.168.55.1`, then ssh; a healthy boot reaches sshd in about 60 seconds. Note that ping alone is not proof: an unseeded flash sits in the oem-config first-boot wizard before sshd while the gadget is up and answering ping (the flash step seeds a user by default to prevent this). Do not treat a dark screen as a failed flash.

The `jetson-first-boot.service` `systemd` daemon automatically executes `scripts/jetson_first_boot.sh`, which:
- Locks NVIDIA kernel/bootloader packages with `apt-mark hold` **and** an `/etc/apt/preferences.d/` entry (Pin-Priority: -1): both layers are needed because hold can be overridden but pin -1 cannot.
- Installs the vermagic-aligned `linux-headers-*.deb` from `/opt/kernel-headers/` so any DKMS-based third-party installer can rebuild against the running kernel.
- Symlinks the OpenCV headers (`/usr/include/opencv4/opencv2` → `/usr/include/opencv2`).
- Builds `/opt/av-env` (Python venv) with `numpy<2.0.0`, PyTorch 2.8.0 from the Jetson wheel index (the index prunes old wheels; the pin tracks what the index serves, see versions.env), and Voyager SDK 1.6 (pip wheels, no DKMS). This step requires internet: an offline first boot leaves `/opt/av-env` unprovisioned (so the CUDA userspace checks cannot pass yet on that unit), and the service re-runs on every boot until provisioning completes once the device gets a network connection (e.g. an Ethernet cable).
- Runs `/opt/zed-sdk/install_zed_sdk.sh` if a `ZED_SDK_Tegra_*.run` is staged. Installer runs in `silent skip_drivers skip_python skip_cuda skip_tools` mode; `pyzed` lands in the venv.
- Edits `/boot/extlinux/extlinux.conf` to append `nohz_full=1-5 isolcpus=1-5 rcu_nocbs=1-5 irqaffinity=0 efi=noruntime pcie_aspm=off`. Deliberately **no `cma=` boot argument**: a cmdline `cma=` bypasses the device tree `linux,cma` pool, and `cma=2048M` failed to reserve on the Orin NX ("cma: Failed to reserve 2048 MiB"), leaving the system with zero CMA and breaking nvgpu's 64MB physically-contiguous comptag allocation at GPU poweron (no CUDA, no GPU devfreq, nvpmodel unable to set any mode). With no `cma=` argument the DT pool (256MB, NVIDIA-sized, stock-proven) takes over; verified live: `CmaTotal` 262144 kB, zero nvgpu errors, GPU at 918MHz.
- Touches `/home/j/.jetson_initialized` to ensure idempotency.

Then a per-boot service (`jetson-rt-tune.service`, `scripts/jetson_rt_tune.sh`) runs on **every** boot to re-apply tuning that the firmware resets on power cycle: `nvpmodel -m 0` (MAXN_SUPER in the SUPER table, operator-overridable via power.conf), `jetson_clocks`, performance governor, GPU/EMC frequency lock, fan PWM 255, best-effort scheduler tuning (the CFS `kernel.sched_*_ns` sysctls do not exist on PREEMPT_RT, so those writes must not abort the service), IRQ affinity (Metis→core 1, ZED X→core 2, NVMe→core 0), OOM shielding for Axelera runtime, and `tc fq` on the primary NIC. Verified live: MAXN_SUPER active, 8 cores online, CPU max ~1.98 GHz.

**One-time post-provisioning, on the device** (verified live 2026-06-10/11; on images baked after 2026-06-11, steps 2-3 run automatically at first boot when staged. Step 1 remains manual):

1. `sudo apt update && sudo apt install nvidia-jetpack`: the sample rootfs ships **no** CUDA/cuDNN/TensorRT/VPI userspace; everything GPU depends on this (~3.8 GB; the kernel pins keep the RT kernel safe). See `docs/TROUBLESHOOTING.md` P-3.
2. `sudo bash scripts/install_av_phase5.sh`: OpenCV-CUDA build (cached as .deb for the fleet), ROS 2 + Isaac ROS (apt, `isaac.download.nvidia.com`) + Nav2 + MAVROS, `jetson-av-mission.service`.
3. `sudo bash scripts/install_zedx_daemons.sh`: ZED X IMU/SPSC kernel modules, vendor daemons, udev rule, and the patched `libnvisppg.so` ISP library. Requires the `zedx-driver` vendor tree on the device.

### Phase C: Operations & Maintenance
- The first-boot script now writes `/etc/apt/preferences.d/99-jetson-av-kernel-lock` with `Pin-Priority: -1` for `nvidia-l4t-kernel*`, `nvidia-l4t-bootloader`, `nvidia-l4t-init`, `nvidia-l4t-xusb-firmware`. Even an explicit `apt install <pkg>=<ver>` is rejected.
- Never run `sudo apt upgrade nvidia-jetpack`.
- If `/boot/extlinux/extlinux.conf` is ever overwritten, run `sudo /home/j/jetson_first_boot.sh` again (it's idempotent except for the marker, `rm /home/j/.jetson_initialized` first if you need it to fully re-execute).
- Always verify after any change with `sudo /home/j/verify_tuning.sh`: it now also dumps vermagic of the critical modules.

### Documentation map

The complete map of every doc, grouped by reader journey, is on the [docs site front page](https://silicondoritos.github.io/jetson-rt-stack/#documentation). The highlights:

**Start here**
| Doc | Purpose |
|---|---|
| [`docs/QUICKSTART.md`](docs/QUICKSTART.md) | Zero to flashed Jetson in 90 minutes |
| [`docs/RUNBOOK.md`](docs/RUNBOOK.md) | Operational decision trees (repeat deploys, recovery) |
| [`docs/OPERATIONS.md`](docs/OPERATIONS.md) | Day-2 operator guide (clock/Metis golden rule, SSH access, GUI/headless toggle, NPU/Wi-Fi/USB-C checks); ships on-device as `~/README.md` |
| [`docs/THIRD_PARTY.md`](docs/THIRD_PARTY.md) | Every third-party input (tarballs, NDA trees, wheels, apt repos): where from, where it goes |
| [`docs/AUTOMATION.md`](docs/AUTOMATION.md) | How Makefile + scripts + `versions.env` compose |
| [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) | Symptom-first failure modes |

**Production phases (Phase 5/6/7)**
| Doc | Purpose |
|---|---|
| [`docs/FLEET.md`](docs/FLEET.md) | Phase 6, fleet manufacturing for N units (release-tarball flow) |
| [`docs/GOLDEN_IMAGE.md`](docs/GOLDEN_IMAGE.md) | Clone a fully-customized Jetson and redeploy bit-identical copies to N units |
| [`docs/NVIDIA_REFERENCES.md`](docs/NVIDIA_REFERENCES.md) | Annotated index of NVIDIA / vendor canonical docs |
| [`docs/COMMUNITY_POST.md`](docs/COMMUNITY_POST.md) | The bible-grade long-form guide, companion to the original Axelera community tutorial |
| [`docs/UAV_RESILIENCE.md`](docs/UAV_RESILIENCE.md) | Phase 7, watchdog, persistent journald, kdump, security, time sync, brownout guard, PCIe AER |
| [`docs/FINE_TUNING.md`](docs/FINE_TUNING.md) | Cross-component coordination, power.conf, storage.conf, expectations.conf, axrun, CPU map, per-device CMA strategy |
| [`docs/BLACKBOX.md`](docs/BLACKBOX.md) | Phase 7, black-box recorder (event log + ROS bag + hash chain) |
| [`docs/DATA_PARTITION.md`](docs/DATA_PARTITION.md) | Phase 7, single-NVMe btrfs data partition (compression, scrub, snapshots) |
| [`docs/CUDA_LIBS.md`](docs/CUDA_LIBS.md) | Phase 5, OpenCV/OpenGL/CUDA/TensorRT/VPI userspace |
| [`docs/AV_STACK.md`](docs/AV_STACK.md) | Phase 5, ROS 2 + Isaac ROS + cuVSLAM + nvblox + Nav2 mission launch |
| [`docs/VERIFICATION.md`](docs/VERIFICATION.md) | The pre/post-check framework powering every phase |
| [`docs/SAMPLES.md`](docs/SAMPLES.md) | How to run every gauntlet, camera sample, and inference demo, with expected outputs |
| [`docs/ZEDX_METIS_CPP.md`](docs/ZEDX_METIS_CPP.md) | The C++ ZED X to Metis samples: lean detector + sensor fusion, `--depth-every` tuning, NVENC `--record` |
| [`docs/BENCHMARKS.md`](docs/BENCHMARKS.md) | Measured FPS / GPU / power / thermal dataset, reproducible via `scripts/bench_zedx_metis.sh` |
| [`docs/VERIFICATION_REPORT.md`](docs/VERIFICATION_REPORT.md) | Audit of every magic value/URL/CONFIG against vendor sources (May 2026) |

**Reference**
| Doc | Purpose |
|---|---|
| [`docs/BUILD.md`](docs/BUILD.md) | Build phase mechanics + reproducibility |
| [`docs/FLASH.md`](docs/FLASH.md) | Flash phase mechanics |
| [`docs/KERNEL_PATCHES.md`](docs/KERNEL_PATCHES.md) | Every patch & in-tree integration |
| [`docs/KERNEL_OPTIMIZATIONS.md`](docs/KERNEL_OPTIMIZATIONS.md) | Every CONFIG_* flag and why |
| [`docs/RT_KERNEL_OPTIMIZATION.md`](docs/RT_KERNEL_OPTIMIZATION.md) | Real-time tuning recipes |
| [`docs/VERMAGIC_STRATEGY.md`](docs/VERMAGIC_STRATEGY.md) | **Must-read**: vermagic discipline |
| [`docs/DRIVERS.md`](docs/DRIVERS.md) | All vendor drivers: ZED X + ZED SDK + Axelera Metis + Voyager SDK |

---

## Enabling the GitHub Pages site

If you've forked this repo and want the docs site on your own GitHub
Pages namespace:

1. **Settings → Pages → Build and deployment**
   - **Source**: `Deploy from a branch`
   - **Branch**: `main`, folder `/docs`
   - Save.
2. Edit [`docs/_config.yml`](docs/_config.yml): change `url` and
   `baseurl` to match your fork (e.g. `https://yourname.github.io` and
   `/your-repo-name`).
3. Push. The site builds in ~2 min and goes live at
   `https://<you>.github.io/<repo>/`.

To preview the site locally before pushing:

```bash
cd docs
bundle install
bundle exec jekyll serve
# open http://127.0.0.1:4000/jetson-rt-stack
```

The theme is [`just-the-docs`](https://just-the-docs.com/), pulled as a
remote theme, no vendoring required. Sidebar navigation,
search, and code highlighting are automatic; the order pages appear in
the sidebar is controlled by `nav_order:` in each doc's front matter.
