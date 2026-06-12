# shellcheck shell=bash
# =============================================================================
# scripts/lib/checks.sh   common pre/post-check primitives
# =============================================================================
# Reusable boolean assertions for use as pre_fn / post_fn in step::run.
# All functions return 0 on success, non-zero on failure. They print to stderr
# only on failure (clean output when chained).
#
# Source order:  config.sh → log.sh → checks.sh
# =============================================================================

if [ "${JETSON_AV_CHECKS_LOADED:-0}" = "1" ]; then return 0 2>/dev/null; fi

# --- Filesystem assertions --------------------------------------------------

check::file_exists() {
    [ -f "$1" ] || { echo "MISSING file: $1" >&2; return 1; }
}

check::dir_exists() {
    [ -d "$1" ] || { echo "MISSING dir: $1" >&2; return 1; }
}

check::blockdev_exists() {
    # [ -f ] is false for device nodes   block devices need [ -b ]
    # (observed live 2026-06-11: file_exists on /dev/nvme0n1 failed the
    # data-partition pre-check on a perfectly healthy disk).
    [ -b "$1" ] || { echo "MISSING block device: $1" >&2; return 1; }
}

check::dir_nonempty() {
    [ -d "$1" ] && [ -n "$(ls -A "$1" 2>/dev/null)" ] \
        || { echo "EMPTY/MISSING dir: $1" >&2; return 1; }
}

check::executable() {
    [ -x "$1" ] || { echo "NOT executable: $1" >&2; return 1; }
}

check::file_contains() {
    local file="$1" needle="$2"
    grep -q -- "$needle" "$file" 2>/dev/null \
        || { echo "MISSING '$needle' in $file" >&2; return 1; }
}

check::file_not_contains() {
    local file="$1" needle="$2"
    if grep -q -- "$needle" "$file" 2>/dev/null; then
        echo "FORBIDDEN '$needle' present in $file" >&2
        return 1
    fi
    return 0
}

check::file_size_gt() {
    local file="$1" min_bytes="$2"
    local sz
    sz="$(stat -c %s "$file" 2>/dev/null || echo 0)"
    [ "$sz" -gt "$min_bytes" ] \
        || { echo "FILE too small: $file ($sz <= $min_bytes)" >&2; return 1; }
}

# --- Command / package assertions -------------------------------------------

check::command_exists() {
    command -v "$1" >/dev/null 2>&1 \
        || { echo "MISSING command: $1" >&2; return 1; }
}

check::package_installed() {
    dpkg -s "$1" >/dev/null 2>&1 \
        || { echo "MISSING package: $1" >&2; return 1; }
}

check::python_module_importable() {
    local py="${PYTHON_BIN:-/opt/av-env/bin/python}"
    "$py" -c "import $1" >/dev/null 2>&1 \
        || { echo "MISSING python module ($py): $1" >&2; return 1; }
}

# --- Kernel / module assertions ---------------------------------------------

check::module_loaded() {
    lsmod 2>/dev/null | awk '{print $1}' | grep -qx "$1" \
        || { echo "NOT LOADED: kernel module $1" >&2; return 1; }
}

check::vermagic_matches_running() {
    local ko="$1"
    local krel; krel="$(uname -r)"
    local vm; vm="$(modinfo "$ko" 2>/dev/null | awk -F': *' '/^vermagic:/{print $2; exit}')"
    case "$vm" in
        *"$krel"*) return 0 ;;
        *)
            echo "VERMAGIC MISMATCH: kernel=$krel  module=$vm  ($ko)" >&2
            return 1
            ;;
    esac
}

check::kernel_cmdline_has() {
    local needle="$1"
    grep -q -- "$needle" /proc/cmdline 2>/dev/null \
        || { echo "MISSING '$needle' in /proc/cmdline" >&2; return 1; }
}

check::config_y() {
    local cfg="$1"
    if [ -r /proc/config.gz ]; then
        zgrep -q "^${cfg}=y\$" /proc/config.gz \
            || { echo "MISSING $cfg=y in /proc/config.gz" >&2; return 1; }
    elif [ -r "/boot/config-$(uname -r)" ]; then
        grep -q "^${cfg}=y\$" "/boot/config-$(uname -r)" \
            || { echo "MISSING $cfg=y in /boot/config-$(uname -r)" >&2; return 1; }
    else
        echo "Cannot read kernel config (no /proc/config.gz, no /boot/config-*)" >&2
        return 1
    fi
}

# --- PCIe / hardware assertions ---------------------------------------------

check::pci_device_visible() {
    local needle="$1"
    lspci 2>/dev/null | grep -qi -- "$needle" \
        || { echo "PCI device NOT VISIBLE: $needle" >&2; return 1; }
}

check::usb_device_visible() {
    local id="$1"  # format VVVV:PPPP
    lsusb 2>/dev/null | grep -q "$id" \
        || { echo "USB device NOT VISIBLE: $id" >&2; return 1; }
}

# --- systemd assertions -----------------------------------------------------

check::service_active() {
    systemctl is-active --quiet "$1" \
        || { echo "SERVICE not active: $1" >&2; return 1; }
}

check::service_enabled() {
    systemctl is-enabled --quiet "$1" 2>/dev/null \
        || { echo "SERVICE not enabled: $1" >&2; return 1; }
}

# --- Network assertions -----------------------------------------------------

check::host_pingable() {
    local host="$1" timeout="${2:-2}"
    ping -c 1 -W "$timeout" "$host" >/dev/null 2>&1 \
        || { echo "HOST not pingable: $host" >&2; return 1; }
}

check::tcp_open() {
    local host="$1" port="$2" timeout="${3:-2}"
    timeout "$timeout" bash -c "</dev/tcp/$host/$port" 2>/dev/null \
        || { echo "TCP closed: $host:$port" >&2; return 1; }
}

# --- Numeric / threshold assertions -----------------------------------------

check::value_gt() {
    local actual="$1" minimum="$2" label="${3:-value}"
    [ "$actual" -gt "$minimum" ] \
        || { echo "$label too small: $actual <= $minimum" >&2; return 1; }
}

check::value_eq() {
    local actual="$1" expected="$2" label="${3:-value}"
    [ "$actual" = "$expected" ] \
        || { echo "$label mismatch: got '$actual' want '$expected'" >&2; return 1; }
}

# --- "true" / "false" sugar -------------------------------------------------
# Useful when a step has no real pre- or post-condition (rare).
check::true()  { return 0; }
check::false() { return 1; }

# JETSON_AV_CHECKS_LOADED is deliberately NOT exported: an exported guard leaks into
# child processes (env vars cross fork+exec, functions do not), so a
# sub-script sourcing this lib would hit the guard and get no functions
# (observed live 2026-06-10: install_av_phase5.sh -> build_opencv_cuda.sh
# died with 'step::run: command not found'). Plain assignment keeps the
# include guard per-process, which is exactly what an include guard means.
JETSON_AV_CHECKS_LOADED=1
