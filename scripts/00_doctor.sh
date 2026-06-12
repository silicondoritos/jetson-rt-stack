#!/bin/bash
# =============================================================================
# scripts/00_doctor.sh   preflight environment check
# =============================================================================
# Run this BEFORE `make extract`. It walks every prerequisite the build needs
# and reports them with PASS/FAIL/WARN. Exits 0 only if everything required is
# in place; exits 1 otherwise.
#
# Idempotent. Read-only   never installs anything. Prints exact remediation
# commands when something fails.
#
# Usage:
#   ./scripts/00_doctor.sh        # full preflight
#   ./scripts/00_doctor.sh --only host          # host packages only
#   ./scripts/00_doctor.sh --only docker        # Docker only
#   ./scripts/00_doctor.sh --only sources       # tarballs + external trees
#   ./scripts/00_doctor.sh --only network       # network-required URLs only
# =============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/config.sh"
. "$HERE/lib/log.sh"
. "$HERE/lib/plugin.sh"

ONLY="${1:-all}"
[ "$ONLY" = "--only" ] && ONLY="${2:-all}"

log::section "AV Firmware: Doctor (Preflight Check)"
echo "Repository: $REPO_ROOT"
echo "L4T target: $L4T_VERSION (JetPack $JETPACK_VERSION)"
echo

GATE_FAILED=0
WARN_COUNT=0

# --- 1. Host OS sanity ------------------------------------------------------
if [ "$ONLY" = "all" ] || [ "$ONLY" = "host" ]; then
    log::step "Host OS"
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "$ID" in
            ubuntu)
                case "$VERSION_ID" in
                    22.04|20.04)
                        log::pass "Ubuntu $VERSION_ID (kernel build runs in the 22.04 container; L4T flash tools support 20.04/22.04)"
                        ;;
                    *)
                        log::warn "Ubuntu $VERSION_ID untested (tested on 20.04/22.04); build is containerized so likely fine"
                        WARN_COUNT=$((WARN_COUNT + 1))
                        ;;
                esac
                ;;
            debian)
                log::warn "Debian untested; kernel build is containerized (Ubuntu 22.04), flashing likely works"
                WARN_COUNT=$((WARN_COUNT + 1))
                ;;
            *)
                log::warn "$ID untested host distro; build is containerized, likely fine"
                WARN_COUNT=$((WARN_COUNT + 1))
                ;;
        esac
    else
        log::xfail "OS detection" "/etc/os-release missing"
    fi

    # CPU arch   must be x86_64 for the cross-compile host
    arch="$(uname -m)"
    if [ "$arch" = "x86_64" ]; then
        log::pass "Architecture: x86_64"
    else
        log::xfail "Architecture" "$arch (cross-compile host must be x86_64)"
    fi

    # RAM   kernel build is containerized; 15 GB is proven to work. 8 GB floor.
    ram_kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
    ram_gb="$((ram_kb / 1024 / 1024))"
    if [ "$ram_gb" -ge 16 ]; then
        log::pass "RAM: ${ram_gb} GB"
    elif [ "$ram_gb" -ge 8 ]; then
        log::pass "RAM: ${ram_gb} GB (sufficient; build works, swap covers peaks)"
        log::warn "16 GB+ recommended for a faster parallel kernel build"
        WARN_COUNT=$((WARN_COUNT + 1))
    else
        log::xfail "RAM" "${ram_gb} GB   at least 8 GB required"
    fi

    # Disk space   40 GB floor on the partition holding REPO_ROOT (build + a
    # rootfs the flash step duplicates). 100 GB+ recommended for headroom.
    disk_avail_kb="$(df -k "$REPO_ROOT" | awk 'NR==2 {print $4}')"
    disk_avail_gb="$((disk_avail_kb / 1024 / 1024))"
    if [ "$disk_avail_gb" -ge 100 ]; then
        log::pass "Disk: ${disk_avail_gb} GB free at $REPO_ROOT"
    elif [ "$disk_avail_gb" -ge 40 ]; then
        log::pass "Disk: ${disk_avail_gb} GB free (sufficient)"
        log::warn "100 GB+ recommended (build + rootfs + flash images duplicate the rootfs)"
        WARN_COUNT=$((WARN_COUNT + 1))
    else
        log::xfail "Disk" "${disk_avail_gb} GB free   40 GB minimum"
    fi

    # Required host packages
    declare -a REQUIRED_PKGS=(
        bc bison flex git rsync zstd make
        openssl xxd dpkg-dev qemu-user-static
        device-tree-compiler nfs-kernel-server sudo curl
    )
    log::step "Host packages"
    for pkg in "${REQUIRED_PKGS[@]}"; do
        if dpkg -s "$pkg" >/dev/null 2>&1; then
            log::pass "$pkg"
        else
            log::xfail "$pkg" "sudo apt install -y $pkg"
        fi
    done

    # libssl-dev (kernel build)
    if dpkg -s libssl-dev >/dev/null 2>&1; then
        log::pass "libssl-dev"
    else
        log::xfail "libssl-dev" "sudo apt install -y libssl-dev"
    fi

    # build-essential
    if dpkg -s build-essential >/dev/null 2>&1; then
        log::pass "build-essential"
    else
        log::xfail "build-essential" "sudo apt install -y build-essential"
    fi
fi

# --- 2. Sudo (passwordless preferred for full automation) ------------------
if [ "$ONLY" = "all" ] || [ "$ONLY" = "host" ]; then
    log::step "sudo"
    if sudo -n true 2>/dev/null; then
        log::pass "passwordless sudo (full automation possible)"
    else
        log::warn "sudo requires a password   Phase 1 will prompt for rootfs extraction"
        WARN_COUNT=$((WARN_COUNT + 1))
    fi
fi

# --- 3. Docker --------------------------------------------------------------
if [ "$ONLY" = "all" ] || [ "$ONLY" = "docker" ]; then
    log::step "Docker"
    if command -v docker >/dev/null 2>&1; then
        log::pass "docker installed ($(docker --version | awk '{print $3}' | tr -d ,))"
    else
        log::xfail "docker" "sudo apt install -y docker.io"
    fi

    # Daemon reachable as current user OR via sudo
    if docker ps >/dev/null 2>&1; then
        log::pass "docker daemon reachable as $(id -un)"
    elif sudo -n docker ps >/dev/null 2>&1; then
        log::pass "docker daemon reachable via sudo"
        log::warn "consider: sudo usermod -aG docker \$USER && newgrp docker"
        WARN_COUNT=$((WARN_COUNT + 1))
    else
        log::xfail "docker daemon" "sudo systemctl start docker; sudo usermod -aG docker \$USER"
    fi

    # Builder image present?
    if docker image inspect "$DOCKER_IMAGE_TAG" >/dev/null 2>&1 \
       || sudo -n docker image inspect "$DOCKER_IMAGE_TAG" >/dev/null 2>&1; then
        log::pass "image '$DOCKER_IMAGE_TAG' present"
    else
        log::warn "image '$DOCKER_IMAGE_TAG' not built yet   run: make docker-build"
        WARN_COUNT=$((WARN_COUNT + 1))
    fi
fi

# --- 4. Source tarballs -----------------------------------------------------
if [ "$ONLY" = "all" ] || [ "$ONLY" = "sources" ]; then
    log::step "L4T source tarballs"
    for var in TARBALL_L4T_PATH TARBALL_ROOTFS_PATH TARBALL_PUBLIC_SOURCES_PATH; do
        path="${!var}"
        if [ -f "$path" ]; then
            sz="$(du -h "$path" | awk '{print $1}')"
            log::pass "$(basename "$path") ($sz)"
        else
            log::xfail "$(basename "$path")" "missing   download from developer.nvidia.com/embedded/jetson-linux-archive"
        fi
    done

    log::step "Vendor trees (plugin doctor checks)"
    load_plugins
    run_hook doctor
fi

# --- 5. Network reachability for ZED SDK / Voyager / PyTorch wheels --------
if [ "$ONLY" = "all" ] || [ "$ONLY" = "network" ]; then
    log::step "Network"
    declare -a URLS=(
        "https://developer.nvidia.com"
        "$PYTORCH_INDEX_URL"
        "$VOYAGER_PYPI_URL"
    )
    for url in "${URLS[@]}"; do
        if curl --silent --head --max-time 5 "$url" >/dev/null 2>&1; then
            log::pass "$url"
        else
            log::warn "$url unreachable   needed at first-boot on the target"
            WARN_COUNT=$((WARN_COUNT + 1))
        fi
    done
fi

# --- 6. USB / flashing readiness (only relevant just before flash) ---------
if [ "$ONLY" = "all" ] || [ "$ONLY" = "flash" ]; then
    log::step "Board target validation (TARGET_BOARD=$TARGET_BOARD)"
    # The flasher takes <board-target> as its argument, e.g.
    # jetson-orin-nano-devkit-super. Wrong value = silent boot failure later.
    # If the L4T tree has been extracted, confirm a matching .conf exists.
    if [ -d "$L4T_DIR" ]; then
        if find "$L4T_DIR" -maxdepth 1 -name "${TARGET_BOARD}.conf" 2>/dev/null \
              | grep -q . \
           || find "$L4T_DIR" -maxdepth 1 \
                  \( -name "p3768*${TARGET_BOARD}*.conf" \
                  -o -name "${TARGET_BOARD}*.conf" \) 2>/dev/null \
              | grep -q .; then
            log::pass "TARGET_BOARD '$TARGET_BOARD' found in L4T tree"
        else
            log::xfail "TARGET_BOARD '$TARGET_BOARD'" \
                       "no matching .conf in $L4T_DIR   check your carrier's board target in versions.env"
            log::info "Available board configs:"
            find "$L4T_DIR" -maxdepth 1 -name '*.conf' \
                  -printf '      %f\n' 2>/dev/null \
              | grep -E '^      (p3768|jetson-)' | head -10
        fi
    else
        log::warn "L4T not extracted yet   board validation deferred to flash time"
        log::warn "  Set TARGET_BOARD in versions.env; current value: '$TARGET_BOARD'"
        WARN_COUNT=$((WARN_COUNT + 1))
    fi

    log::step "Storage device target (TARGET_STORAGE_DEV=$TARGET_STORAGE_DEV)"
    case "$TARGET_STORAGE_DEV" in
        nvme*p[0-9]*) log::pass "$TARGET_STORAGE_DEV (looks like NVMe partition)" ;;
        mmcblk*p[0-9]*) log::pass "$TARGET_STORAGE_DEV (looks like eMMC partition)" ;;
        *) log::xfail "TARGET_STORAGE_DEV '$TARGET_STORAGE_DEV'" \
                       "unrecognized; expected nvme0n1pN or mmcblk*pN" ;;
    esac

    log::step "Flash prerequisites (only matters at flash time)"
    if lsusb 2>/dev/null | grep -q "$USB_ID_APX"; then
        log::pass "Jetson in recovery mode (USB ID $USB_ID_APX)"
    else
        log::warn "Jetson not in recovery mode (no $USB_ID_APX on USB)"
        log::warn "  → short REC+GND, plug USB-C into rear motherboard port (no hub), then re-run"
        WARN_COUNT=$((WARN_COUNT + 1))
    fi

    autosuspend="$(cat /sys/module/usbcore/parameters/autosuspend 2>/dev/null || echo missing)"
    if [ "$autosuspend" = "-1" ]; then
        log::pass "USB autosuspend disabled"
    else
        log::warn "USB autosuspend = $autosuspend (recommend -1 before flashing)"
        log::warn "  → sudo sh -c 'echo -1 > /sys/module/usbcore/parameters/autosuspend'"
        WARN_COUNT=$((WARN_COUNT + 1))
    fi
fi

# --- Version consistency (versions.env is the single source of truth) -------
echo
log::section "Version Consistency"
if bash "$HERE/check_version_consistency.sh" >/dev/null 2>&1; then
    log::pass "docs and scripts agree with versions.env"
else
    log::warn "version drift: run scripts/check_version_consistency.sh for the list"
    WARN_COUNT=$((WARN_COUNT + 1))
fi

# --- Summary ----------------------------------------------------------------
echo
log::section "Doctor Result"
if [ "$GATE_FAILED" = "0" ]; then
    if [ "$WARN_COUNT" = "0" ]; then
        log::ok "All checks PASS   ready to run 'make extract'"
        exit 0
    else
        log::ok "Required checks PASS, $WARN_COUNT warning(s)   review above"
        exit 0
    fi
else
    log::fail "One or more REQUIRED checks failed. Fix and re-run."
    # log::fail exits unless NO_EXIT=1; we end here.
fi
