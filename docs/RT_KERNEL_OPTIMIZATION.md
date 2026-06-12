---
title: RT Tuning
layout: default
description: "PREEMPT_RT tuning recipes: cyclictest methodology, CPU isolation parameters, IRQ affinity, scheduler tuning, and expected jitter numbers."
nav_order: 15
---

# RT Kernel Optimization

This is the tuning loop for the PREEMPT_RT Jetson built by [jetson-rt-stack](../README.md): measure, diagnose, change, verify, repeat. It covers cyclictest methodology, CPU isolation, IRQ affinity, scheduler and power tuning, and how the project's automated latency gate works.

For the rationale behind each kernel flag, see [KERNEL_OPTIMIZATIONS.md](KERNEL_OPTIMIZATIONS.md); for the source-tree patches those flags ride on, see [KERNEL_PATCHES.md](KERNEL_PATCHES.md); for the per-boot service knobs and cross-component coordination, see [FINE_TUNING.md](FINE_TUNING.md).

## Scope

- Hardware: Jetson Orin NX 16GB (p3767-0000 module on a p3768 Orin Nano devkit carrier).
- BSP: L4T R36.4.3 / JetPack 6.2, kernel 5.15 with the PREEMPT_RT patch.
- Build host: Docker container with the Bootlin toolchain, driven by the numbered [scripts/](../scripts).
- Inputs: kernel source under `latest_jetson/Linux_for_Tegra/source/kernel/`, the Axelera PCIe patch, and the ZED X patches in `zedx-driver/`.
- Output: a `CONFIG_*` set, extlinux boot args, and a runtime recipe that produce measurable, repeatable jitter reduction.

The isolation set for this build is cores 1 through 5. Core 0 keeps the housekeeping work (timers, RCU callbacks, IRQs). This split is single-sourced in [versions.env](../versions.env) as `RT_ISOLATED_CORES=1-5` and is enforced by the bake and verify scripts.

## The automated latency gate

`make verify` runs [scripts/05_post_flash_validate.sh](../scripts/05_post_flash_validate.sh), which SSHes into the flashed board and executes [scripts/verify_tuning.sh](../scripts/verify_tuning.sh) (baked into the rootfs during stage 3). The jitter step of that script is the project's go/no-go gate. Note that `make verify` also includes a Python venv import check against `/opt/av-env`; that step fails until first-boot provisioning has completed with network access (the first-boot service re-runs on each boot and finishes provisioning once the board is online). The jitter gate itself does not depend on that step.

The gate runs cyclictest exactly as follows, on isolated core 1, for 10 seconds, with no concurrent load:

```bash
sudo cyclictest -m -p 99 -t 1 -a 1 -n -D 10s --quiet
```

It parses the reported `Max:` latency and passes when that maximum is under 100 microseconds. This is a fast smoke test, not a performance specification. Flags map as: `-m` lock memory, `-p 99` SCHED_FIFO priority 99, `-t 1` one measurement thread, `-a 1` pin to core 1, `-n` clock_nanosleep, `-D 10s` run for ten seconds.

Reproduce the gate by hand on the board:

```bash
# As root, after the board has reached multi-user and rt-tune has applied.
sudo cyclictest -m -p 99 -t 1 -a 1 -n -D 10s --quiet
```

A pass means core 1 stayed under 100 microseconds for the run. It does not characterize the long tail. For a deployment sign-off, run the longer sweeps below.

### Documented conditions for the gate

| Parameter | Value |
|---|---|
| Kernel | 5.15 PREEMPT_RT (`-tegra`) |
| Power profile | MAXN_SUPER (nvpmodel mode 0) |
| jetson_clocks | locked (all clocks at max) |
| CPU governor | performance |
| Isolated cores | 1-5 (`isolcpus=1-5 nohz_full=1-5 rcu_nocbs=1-5`) |
| Concurrent load | none (gate runs standalone) |
| cyclictest flags | `-m -p 99 -t 1 -a 1 -n -D 10s --quiet` |
| Reported metric | `Max:` latency on core 1 |
| Pass threshold | Max < 100 microseconds |
| Duration | 10 seconds |
| Ambient | ~25 C lab bench, natural convection |

The power profile is MAXN_SUPER by default: [scripts/04_flash_nvme.sh](../scripts/04_flash_nvme.sh) sets the `nvpmodel_p3767_0000_super.conf` as the default profile, and [scripts/jetson_rt_tune.sh](../scripts/jetson_rt_tune.sh) reasserts `nvpmodel -m 0` at boot (`NVPMODEL_MODE=0`, overridable via power.conf). With the SUPER table installed, the live-verified mode IDs are: 0 = MAXN_SUPER, 1 = 10W, 2 = 15W, 3 = 25W, 4 = 40W. Confirm on the board with `nvpmodel -q`.

## Deployment-grade verification

The 10-second gate proves the build is sane. It does not prove the build is mission-ready. Before relying on the kernel under a real workload, run a multi-core, long-duration sweep with the mission load present.

Run a wider sweep across the whole isolation set:

```bash
# All isolated cores, 30 minutes, JSON + histogram for later analysis.
sudo cyclictest --smp --mlockall --priority=99 --affinity=1-5 \
    --threads --interval=200 --duration=30m \
    --histofall --json=/tmp/ct.json
```

Generate concurrent load while the sweep runs so the numbers reflect contention, not an idle board:

```bash
# Inference + capture + CPU pressure. See scripts/run_sustained_load.sh.
./scripts/run_sustained_load.sh 1800
# In parallel, CPU/memory pressure on the housekeeping core only:
sudo stress-ng --cpu 1 --taskset 0 --vm 1 --vm-bytes 1G --timeout 1800s
```

`run_sustained_load.sh` drives inference and camera capture, so it needs a provisioned `/opt/av-env` and an attached ZED X camera. Both are live-verified on the reference device (2026-06-11: 29.5 FPS stereo capture, Voyager `inference.py` at 49.2 FPS end-to-end). On a fresh flash where first-boot provisioning has not yet completed online, or with no camera attached, generate load with `stress-ng` alone. For a heavier, reproducible mission load, the C++ fusion sample sustains 46 to 53 FPS with all features live using `--depth-every`; see [BENCHMARKS.md](BENCHMARKS.md) for the harness and [ZEDX_METIS_CPP.md](ZEDX_METIS_CPP.md) for the samples.

Sign-off criteria for a deployment build:

- The 10-second gate passes (Max < 100 microseconds on core 1).
- No recurring high-latency outliers after a 30-minute sweep at operating temperature with the mission load present.
- `rtla timerlat` and `rtla osnoise` traces show no remaining major kernel-induced latency source.

The long tail (p99.9 and beyond) is always higher than the gate's single-thread maximum, especially under thermal load. Characterize it; do not assume it.

## Tuning strategy

The kernel ships from [scripts/02_build_kernel.sh](../scripts/02_build_kernel.sh) already configured for RT. This loop is for narrowing residual jitter on a specific workload.

1. Baseline: run the gate and the wider sweep, save the histograms.
2. Trace: run `rtla timerlat` and `rtla osnoise` to find the dominant latency sources.
3. Change one thing: a boot arg, an IRQ affinity, a governor, or a `CONFIG_*` value.
4. Re-measure against the same baseline.
5. Iterate until the criteria above hold. Remove any diagnostic tracing config from the final defconfig to drop its overhead.

## Kernel config

These flags are appended to `arch/arm64/configs/defconfig` by [scripts/01_extract_and_patch.sh](../scripts/01_extract_and_patch.sh). [KERNEL_OPTIMIZATIONS.md](KERNEL_OPTIMIZATIONS.md) documents the full set with rationale; the latency-relevant subset is:

- `CONFIG_PREEMPT_RT=y`: the core RT support. Threads IRQ handlers and makes spinlocks sleepable.
- `CONFIG_NO_HZ_FULL=y`: full dynticks on isolated CPUs, so the timer tick stops firing on cores 1-5.
- `CONFIG_HIGH_RES_TIMERS=y` and `CONFIG_HZ_1000=y`: a 1 ms timer base with high-resolution timers.
- `CONFIG_RCU_NOCB_CPU=y`: lets `rcu_nocbs` move RCU callbacks off the isolated cores.
- `CONFIG_CPU_ISOLATION=y`: kernel-level enforcement that the scheduler skips isolated cores.

Diagnostic tracers (`CONFIG_OSNOISE_TRACER`, `CONFIG_TIMERLAT_TRACER`, `CONFIG_HWLAT_TRACER`, and the broader `CONFIG_FTRACE` family) add runtime overhead. Enable them in a measurement build only, then drop them from the production defconfig.

Verify the RT flags landed in the extracted tree:

```bash
DEFCONFIG=latest_jetson/Linux_for_Tegra/source/kernel/kernel-jammy-src/arch/arm64/configs/defconfig
grep -E "PREEMPT_RT|NO_HZ_FULL|RCU_NOCB|HZ_1000|TIMERLAT|OSNOISE" "$DEFCONFIG"
```

## Boot arguments

[scripts/03_bake_rootfs.sh](../scripts/03_bake_rootfs.sh) injects the RT boot args into the device extlinux on the rootfs. The injected line includes:

```
root=/dev/nvme0n1p1 rootwait rootfstype=ext4 efi=noruntime pcie_aspm=off \
nohz_full=1-5 isolcpus=1-5 rcu_nocbs=1-5 irqaffinity=0
```

- `isolcpus=1-5 nohz_full=1-5 rcu_nocbs=1-5`: dedicate cores 1-5 to RT tasks and keep tick, scheduler, and RCU-callback noise off them.
- `irqaffinity=0`: default all IRQ affinity to core 0 so device interrupts do not land on the isolated set.
- No `cma=` argument, deliberately. An earlier revision passed `cma=2048M` as an "optimization"; on the Orin NX it failed to reserve ("cma: Failed to reserve 2048 MiB"), and because a cmdline `cma=` bypasses the device tree `linux,cma` pool, the board ran with zero CMA. nvgpu requires a 64MB physically contiguous comptag allocation at GPU poweron (`ga10b_cbc_alloc_comptags`); with zero CMA that allocation fails ("DMA alloc FAILED: [sysmem] size=64225280 ... PHYSICALLY_ADDRESSED") and cascades into "Unable to recover GR falcon", a FECS context switch init error, no CUDA, no GPU devfreq, and nvpmodel unable to set any power mode (it reads the GPU frequency table). With no `cma=` on the cmdline, the stock-proven 256MB device tree pool takes over. Verified after the fix: `CmaTotal: 262144 kB`, zero nvgpu errors across the boot, GPU devfreq present, GPU at 918MHz.
- `root=/dev/nvme0n1p1`: explicit NVMe root. On an NVMe-only Orin NX this is mandatory; see the troubleshooting note below.

The isolation range and IRQ affinity are single-sourced in [versions.env](../versions.env). Do not hand-edit them in extlinux; change them at the source and re-bake. CMA sizing belongs to the device tree, not the cmdline; do not reintroduce a `cma=` boot arg.

Confirm on the running board:

```bash
cat /proc/cmdline                      # expect: no cma= argument
cat /sys/devices/system/cpu/isolated   # expect: 1-5
grep CmaTotal /proc/meminfo            # expect: 262144 kB (device tree pool)
```

## Runtime knobs

The boot-time service [scripts/jetson_rt_tune.sh](../scripts/jetson_rt_tune.sh) (installed as `jetson-rt-tune.service`) applies these on every boot. Apply them by hand when tuning interactively.

Power profile and clocks:

```bash
sudo nvpmodel -m 0        # MAXN_SUPER (SUPER table: 0=MAXN_SUPER, 1=10W, 2=15W, 3=25W, 4=40W)
sudo jetson_clocks        # lock all clocks to max
```

CPU governor (performance on every core):

```bash
for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
    echo performance | sudo tee "$cpu/cpufreq/scaling_governor" > /dev/null
done
```

Disable device autosuspend for interrupt sources that would otherwise wake and add latency:

```bash
# Example: disable USB autosuspend globally.
echo -1 | sudo tee /sys/module/usbcore/parameters/autosuspend
```

## CPU isolation and IRQ affinity

`isolcpus` keeps the scheduler off cores 1-5, and `irqaffinity=0` defaults interrupts to core 0. Some drivers re-pin their own IRQs after they load, so verify and correct device IRQs once the Metis and ZED X drivers are up.

```bash
# Inspect where each IRQ is currently allowed to run.
grep . /proc/irq/*/smp_affinity_list

# Force a specific IRQ onto core 0 (mask 0x1).
echo 1 | sudo tee /proc/irq/<IRQ_NUMBER>/smp_affinity
```

Move any stray kernel threads off the isolated cores with `tuna` or `taskset`. The Metis NPU enumerates on PCIe at `0004:01:00.0`; after its driver binds, confirm its IRQ is not landing on the isolated set.

## Trace and diagnose

Install the test and tracing tools on the target (or in the chroot while baking):

```bash
sudo apt update
sudo apt install -y rt-tests rtla trace-cmd linux-tools-generic sysstat stress-ng
```

Run `rtla timerlat` alongside a cyclictest sweep to capture a kernel stack trace whenever latency exceeds a threshold. Pick the threshold from the cyclictest maximum:

```bash
# Stop tracing automatically on the first sample over 250 microseconds.
sudo rtla timerlat top --cpus 1-5 --auto 250
```

`rtla osnoise` attributes time lost to OS noise sources (IRQs, NMIs, softirqs, kernel threads); `rtla hwlat` isolates hardware-induced latency. Use both to separate software causes from firmware or SMI-style stalls.

### Common causes and fixes

| Symptom in trace | Likely cause | Fix |
|---|---|---|
| `od_dbs_update`, `dev_pm_opp_set_rate` | ondemand governor callbacks | force the performance governor; confirm ondemand is not compiled in |
| `kworker` spikes on cores 1-5 | workqueue work scheduled on isolated cores | pin the workqueue, or move its trigger off the isolated set |
| Long IRQ handler on an isolated core | a driver re-pinned its IRQ | re-set `smp_affinity` to core 0; rely on threaded IRQs |
| Periodic spikes tied to frequency changes | regulator or OPP transitions | lock clocks with `jetson_clocks`; pin OPPs for the RT path |

## Verify

After any change, re-run the gate and confirm the tuning state. The fastest check is the host-side gate:

```bash
make verify        # SSH to the board, run verify_tuning.sh, enforce the gate
```

On the board directly:

```bash
uname -v | grep -q 'PREEMPT RT' && echo RT-OK   # PREEMPT_RT kernel
cat /sys/kernel/realtime                          # expect: 1
cat /sys/devices/system/cpu/isolated              # expect: 1-5
nvpmodel -q                                        # expect: MAXN_SUPER
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor   # expect: performance
sudo cyclictest -m -p 99 -t 1 -a 1 -n -D 10s --quiet        # Max < 100 us
```

## Troubleshoot

- **Blank HDMI from "Exiting boot services" to the desktop.** Normal on Orin. `FRAMEBUFFER_CONSOLE` is off, and `earlycon=efifb` does not help because the GOP framebuffer is torn down at ExitBootServices. The reliable "did it boot" signal is the USB device-mode gadget at `192.168.55.1` (and the `ttyACM` console) once the board reaches multi-user.
- **Board hangs at boot waiting for a root device.** The eMMC default `root=/dev/mmcblk0p1` does not exist on an NVMe-only Orin NX, so `rootwait` blocks forever. The bake step writes `root=/dev/nvme0n1p1` explicitly; confirm it is present in `/proc/cmdline`.
- **Root will not mount on the RT kernel.** The initrd carries its own copy of the early-boot modules. On a PREEMPT_RT kernel those must share the kernel's `preempt_rt` vermagic, or the early-boot drivers must be built in. NVMe, PCIe, and PHY are built in for exactly this reason, so no `nvme.ko` is needed in the initrd.
- **The gate fails intermittently under thermal load.** The 10-second gate runs standalone; a board that passes idle can still throttle under the mission load. Re-check with `nvpmodel -q` and the thermal cooling-device states, then run the 30-minute sweep with load before trusting the build.

## References

- NVIDIA Jetson Linux Developer Guide R36.4.3: nvpmodel and jetson_clocks usage, and the kernel and flash workflow.
- The Good Penguin: practical `rtla timerlat` and cyclictest recipes for ARM and embedded targets.
- Project docs: [KERNEL_OPTIMIZATIONS.md](KERNEL_OPTIMIZATIONS.md) for every `CONFIG_*` flag, [KERNEL_PATCHES.md](KERNEL_PATCHES.md) for the source-tree patches, [FINE_TUNING.md](FINE_TUNING.md) for the boot-time tuning service, [BENCHMARKS.md](BENCHMARKS.md) for the measured camera-plus-NPU throughput, [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for the full boot and flash failure catalog.
