#!/bin/bash
# Per-boot RT tuning   runs on EVERY boot via jetson-rt-tune.service.
# Applies IRQ affinity, clock locking, scheduler tuning, and SUPER Mode.
# Safe to run multiple times (idempotent).
set -e

if [ "$EUID" -ne 0 ]; then
    echo "[!] Must run as root."
    exit 1
fi

echo "[rt-tune] Applying maximum performance + RT tuning..."

# =============================================================
# MAXIMUM PERFORMANCE: Lock clocks and power mode
# (tunable via /etc/jetson-av/power.conf   Gap 6+9 fix)
# =============================================================

# Defaults match the previous always-MAXN behavior. Operator can override
# any value in /etc/jetson-av/power.conf without editing this script.
NVPMODEL_MODE=0          # SUPER conf table (live-verified): 0=MAXN_SUPER 1=10W 2=15W 3=25W 4=40W
GPU_MAX_FREQ_HZ=          # empty = use hardware max; set to cap below max
EMC_FREQ_HZ=              # empty = use hardware max
LOCK_CPU_GOV=performance # ondemand | schedutil | conservative | performance
FAN_PWM=255              # 0-255 (255=full)
if [ -f /etc/jetson-av/power.conf ]; then
    # shellcheck disable=SC1091
    . /etc/jetson-av/power.conf
fi

# 1. Set selected power mode (default MAXN/0)
nvpmodel -m "$NVPMODEL_MODE" 2>/dev/null \
    && echo "[rt-tune] nvpmodel: mode $NVPMODEL_MODE"

# 2. Lock all clocks to maximum frequency
jetson_clocks 2>/dev/null && echo "[rt-tune] jetson_clocks: all clocks locked"

# 3. CPU governor on all cores (defaults to performance; tunable via
#    LOCK_CPU_GOV in power.conf for thermal-constrained airframes).
for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo "$LOCK_CPU_GOV" > "$gov" 2>/dev/null || true
done
echo "[rt-tune] CPU: $LOCK_CPU_GOV governor on all cores"

# 4. GPU   lock min freq to max freq (GA10B Ampere on Orin NX).
#    L4T R36.x exposes the GPU at /sys/class/devfreq/17000000.gpu/.
#    L4T R35.x used the older /sys/class/devfreq/17000000.ga10b/ path.
#    Try the new path first, fall back for older targets.
GPU_DEV=""
for cand in /sys/class/devfreq/17000000.gpu \
            /sys/class/devfreq/17000000.ga10b \
            /sys/devices/platform/17000000.gpu/devfreq/17000000.gpu; do
    if [ -d "$cand" ]; then GPU_DEV="$cand"; break; fi
done
if [ -n "$GPU_DEV" ]; then
    GPU_HW_MAX=$(cat "$GPU_DEV/max_freq")
    # Respect GPU_MAX_FREQ_HZ override (Gap 6   protect Metis bandwidth by
    # capping the GPU below the hardware maximum). Empty = use hardware max.
    if [ -n "$GPU_MAX_FREQ_HZ" ] && [ "$GPU_MAX_FREQ_HZ" -lt "$GPU_HW_MAX" ]; then
        GPU_TARGET=$GPU_MAX_FREQ_HZ
        echo "[rt-tune] GPU: capping at ${GPU_TARGET}Hz (HW max ${GPU_HW_MAX}Hz)"
    else
        GPU_TARGET=$GPU_HW_MAX
    fi
    echo "$GPU_TARGET" > "$GPU_DEV/max_freq" 2>/dev/null || true
    echo "$GPU_TARGET" > "$GPU_DEV/min_freq" 2>/dev/null || true
    echo "performance" > "$GPU_DEV/governor" 2>/dev/null || true
    echo "[rt-tune] GPU: locked to ${GPU_TARGET}Hz at $GPU_DEV"
else
    echo "[rt-tune] GPU: devfreq node not found (checked .gpu and .ga10b)   skipping GPU lock"
fi

# 5. EMC (memory controller)   lock to peak
EMC_CLK="/sys/kernel/debug/bpmp/debug/clk/emc"
if [ -f "$EMC_CLK/max_rate" ]; then
    EMC_MAX=$(cat "$EMC_CLK/max_rate")
    echo $EMC_MAX > "$EMC_CLK/rate" 2>/dev/null || true
    echo "[rt-tune] EMC: locked to ${EMC_MAX}Hz"
fi

# 6. Fan PWM (default 255=100%; tunable via FAN_PWM in power.conf).
FAN_PWM_NODE=$(find /sys/devices/platform/pwm-fan -name "pwm1" 2>/dev/null | head -1)
if [ -n "$FAN_PWM_NODE" ]; then
    echo "$FAN_PWM" > "$FAN_PWM_NODE" 2>/dev/null || true
    echo "[rt-tune] Fan: PWM=$FAN_PWM (max 255)"
fi

# =============================================================
# SCHEDULER: Minimize jitter for RT tasks
# =============================================================
# These are CFS tunables. They DO NOT EXIST on a CONFIG_PREEMPT_RT kernel
# (the RT scheduler replaces CFS granularity knobs), so each is best-effort:
# without the guards the first missing key aborts this whole service (it ran
# under set -e), which silently skipped nvpmodel + jetson_clocks and left the
# board un-tuned. Real-time scheduling on PREEMPT_RT is governed by task
# SCHED_FIFO/RR priorities, not these.
sysctl -qw kernel.sched_min_granularity_ns=100000 2>/dev/null || true
sysctl -qw kernel.sched_wakeup_granularity_ns=100000 2>/dev/null || true
sysctl -qw kernel.sched_migration_cost_ns=50000 2>/dev/null || true
echo "[rt-tune] Scheduler: low-jitter parameters applied (CFS knobs skipped on PREEMPT_RT)"

# =============================================================
# MEMORY: HugePages for AI/Vision buffers
# =============================================================
echo always > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo madvise > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
echo "[rt-tune] HugePages: THP enabled (skipped if not built into this kernel)"

# =============================================================
# PCIe: Force Axelera to active state
# =============================================================
for pcie_power in /sys/bus/pci/devices/*/power/control; do
    echo on > "$pcie_power" 2>/dev/null || true
done
echo "[rt-tune] PCIe: all devices forced to active power state"

# =============================================================
# IRQ AFFINITY: Pin hardware interrupts to dedicated cores
# Core 0 = OS (servant)
# Core 1 = Axelera Metis (AI inference IRQs)
# Core 2 = ZED X + CSI (vision pipeline IRQs)
# Cores 3-5 = SLAM / path generation (no IRQs)
# =============================================================

# Wait for drivers to load before pinning IRQs
sleep 2

# Pin Axelera Metis PCIe IRQs to Core 1 (mask 0x02).
METIS_IRQS=$(grep -iE "axelera|metis|1f9d" /proc/interrupts 2>/dev/null | awk -F: '{print $1}' | tr -d ' ')
for irq in $METIS_IRQS; do
    echo 2 > /proc/irq/$irq/smp_affinity 2>/dev/null || true
    echo "[rt-tune] IRQ $irq (Metis) → Core 1"
done

# Pin ZED X CSI/VI IRQs to Core 2 (mask 0x04).
ZED_IRQS=$(grep -iE "tegra-csi|tegra-capture-vi|vi-notif" /proc/interrupts 2>/dev/null | awk -F: '{print $1}' | tr -d ' ')
for irq in $ZED_IRQS; do
    echo 4 > /proc/irq/$irq/smp_affinity 2>/dev/null || true
    echo "[rt-tune] IRQ $irq (ZED X CSI) → Core 2"
done

# Pin NVMe IRQs to Core 0 (don't let storage compete with AI). Mask 0x01.
NVME_IRQS=$(grep -i "nvme" /proc/interrupts 2>/dev/null | awk -F: '{print $1}' | tr -d ' ')
for irq in $NVME_IRQS; do
    echo 1 > /proc/irq/$irq/smp_affinity 2>/dev/null || true
done

# Sweep ALL remaining Tegra IRQ sources to management cores 0,6,7
# (mask 0xC1). Without this, host1x / nvenc / nvdec / isp / mipi-cal / vic /
# nvgpu interrupts can land on isolated cores 1-5 and inject >50µs spikes
# into RT tasks. The narrow regex above only caught Metis + CSI + NVMe;
# the broader sweep below catches everything else Tegra exposes.
TEGRA_BROAD_IRQS=$(grep -iE "host1x|nvenc|nvdec|isp[0-9]?|mipi-cal|vic|nvgpu|nvjpg|nvgr|tegra-vi|t234-cbb" \
    /proc/interrupts 2>/dev/null | awk -F: '{print $1}' | tr -d ' ')
for irq in $TEGRA_BROAD_IRQS; do
    # 0xC1 = cores 0, 6, 7   keeps RT cores 1-5 clean.
    echo c1 > /proc/irq/$irq/smp_affinity 2>/dev/null || true
done

# Default-affinity for any IRQ that wasn't explicitly pinned.
# Setting /proc/irq/default_smp_affinity covers IRQs that come up later.
echo c1 > /proc/irq/default_smp_affinity 2>/dev/null || true
echo "[rt-tune] IRQ default-affinity → cores 0,6,7 (mask 0xC1)"

# =============================================================
# OOM PROTECTION: Axelera inference process is mission-critical
# =============================================================
AXELERA_PID=$(pgrep -f "axelera\|axrt" 2>/dev/null | head -1)
if [ -n "$AXELERA_PID" ]; then
    echo -1000 > /proc/$AXELERA_PID/oom_score_adj 2>/dev/null || true
    echo "[rt-tune] OOM shield applied to Axelera runtime (PID $AXELERA_PID)"
fi

# =============================================================
# NETWORK: ROS 2 DDS real-time QoS
# =============================================================
# Set fair queuing scheduler on the primary network interface
PRIMARY_IF=$(ip route | grep default | awk '{print $5}' | head -1)
if [ -n "$PRIMARY_IF" ]; then
    tc qdisc replace dev "$PRIMARY_IF" root fq 2>/dev/null || true
    echo "[rt-tune] Network QoS: FQ scheduler on $PRIMARY_IF"
fi

echo "[rt-tune] Maximum performance + RT tuning complete."
