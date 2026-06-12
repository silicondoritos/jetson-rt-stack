#!/bin/bash
# =============================================================================
#  VERIFY_VERMAGIC.SH   Vermagic Consistency Gate
# =============================================================================
#  Purpose: Confirm every kernel module produced by Phase 2 (and later baked
#           into the rootfs) shares the exact same vermagic string as the
#           kernel itself. Vermagic mismatch is the single most common reason
#           that custom RT kernel deployments fail at runtime ("Invalid
#           module format" on insmod). This gate catches the problem before
#           flashing.
#
#  Modes:
#    --build-tree   Walk the build tree (kernel-jammy-src + OOT modules).
#                   Used at end of Phase 2 to write EXPECTED_VERMAGIC.
#    --rootfs       Walk $ROOTFS/lib/modules/<UTS_RELEASE>/.
#                   Used by pre_flash_audit.sh after Phase 3.
#    --target       Walk /lib/modules/$(uname -r)/ on a running Jetson.
#                   Used by verify_tuning.sh post-boot.
#
#  Exit codes:
#    0  All modules match expected vermagic.
#    1  At least one mismatch (or expected vermagic could not be determined).
#    2  No modules found to check.
# =============================================================================
set -e

MODE="${1:---rootfs}"

# Resolve project paths regardless of cwd
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
L4T_DEFAULT="$PROJECT_DIR/latest_jetson/Linux_for_Tegra"
L4T="${L4T:-$L4T_DEFAULT}"
SOURCE="$L4T/source"
KERNEL_SRC="$SOURCE/kernel/kernel-jammy-src"
ROOTFS="$L4T/rootfs"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# =============================================================================
# Helpers
# =============================================================================

# Extract the vermagic string from a .ko file. modinfo is preferred (works on
# any host), but we fall back to `strings | grep '^vermagic='` so this script
# is portable even when modinfo isn't available (e.g. a stripped Docker stage).
extract_vermagic() {
    local ko="$1" vm=""
    if command -v modinfo >/dev/null 2>&1; then
        vm="$(modinfo "$ko" 2>/dev/null | awk -F': *' '/^vermagic:/{print $2; exit}')"
    fi
    # modinfo returns empty for a foreign-arch .ko on an x86 host; strings is reliable.
    [ -z "$vm" ] && vm="$(strings "$ko" 2>/dev/null | grep -m1 '^vermagic=' | sed 's/^vermagic=//')"
    printf '%s\n' "$vm"
}

# Determine the expected vermagic for the build. Priority order:
#   1. EXPECTED_VERMAGIC env var (CI / explicit override)
#   2. $L4T/EXPECTED_VERMAGIC marker file written by Phase 2
#   3. Read from the kernel image's .modinfo section via modprobe-style grep
#   4. Synthesize from include/generated/utsrelease.h + config flags
expected_vermagic() {
    if [ -n "${EXPECTED_VERMAGIC:-}" ]; then
        echo "$EXPECTED_VERMAGIC"
        return 0
    fi
    if [ -f "$L4T/EXPECTED_VERMAGIC" ]; then
        cat "$L4T/EXPECTED_VERMAGIC"
        return 0
    fi
    # Try to derive from any one of the produced .ko files in the build tree.
    # This isn't strictly "expected"   it's "first observed"   but it's used
    # as the consensus value for cross-checking the rest.
    local sample
    sample="$(find "$KERNEL_SRC" "$SOURCE/stereolabs" "$SOURCE/axelera" \
                -name '*.ko' -type f 2>/dev/null | head -1)"
    if [ -n "$sample" ]; then
        extract_vermagic "$sample"
        return 0
    fi
    return 1
}

walk_modules_in() {
    local root="$1"
    # exclude debian/ packaging staging (stripped/dbg copies have no vermagic)
    find "$root" -name '*.ko' -type f -not -path '*/debian/*' 2>/dev/null
}

# =============================================================================
# Mode dispatch
# =============================================================================

case "$MODE" in
    --build-tree)
        ROOTS=("$KERNEL_SRC" "$SOURCE/stereolabs" "$SOURCE/axelera" "$SOURCE/kernel_oot_modules")
        LABEL="build tree (kernel-jammy-src + OOT)"
        ;;
    --rootfs)
        ROOTS=("$ROOTFS/lib/modules")
        LABEL="rootfs ($ROOTFS/lib/modules)"
        ;;
    --target)
        ROOTS=("/lib/modules/$(uname -r)")
        LABEL="target /lib/modules/$(uname -r)"
        ;;
    *)
        echo "Usage: $0 [--build-tree | --rootfs | --target]" >&2
        exit 1
        ;;
esac

echo -e "${BLUE}=================================================================${NC}"
echo -e "         VERMAGIC CONSISTENCY GATE (mode: $MODE)                  "
echo -e "${BLUE}=================================================================${NC}"
echo -e "[*] Scope: $LABEL"

EXPECTED="$(expected_vermagic || true)"
if [ -z "$EXPECTED" ]; then
    echo -e "    ${RED}[FAIL]${NC} Could not determine expected vermagic."
    echo -e "    Either set EXPECTED_VERMAGIC, write $L4T/EXPECTED_VERMAGIC,"
    echo -e "    or build the kernel first."
    exit 1
fi
echo -e "[*] Expected vermagic:"
echo -e "    ${BLUE}$EXPECTED${NC}"

TOTAL=0
MATCH=0
MISMATCH=0
MISMATCH_LIST=()

for root in "${ROOTS[@]}"; do
    [ -d "$root" ] || continue
    while IFS= read -r ko; do
        TOTAL=$((TOTAL + 1))
        actual="$(extract_vermagic "$ko")"
        if [ "$actual" = "$EXPECTED" ]; then
            MATCH=$((MATCH + 1))
        else
            MISMATCH=$((MISMATCH + 1))
            MISMATCH_LIST+=("$ko :: $actual")
        fi
    done < <(walk_modules_in "$root")
done

echo -e "[*] Modules scanned: $TOTAL  (match: ${GREEN}$MATCH${NC}, mismatch: ${RED}$MISMATCH${NC})"

if [ "$TOTAL" -eq 0 ]; then
    echo -e "    ${YELLOW}[WARN]${NC} No .ko files found under the requested scope."
    echo -e "${BLUE}=================================================================${NC}"
    exit 2
fi

if [ "$MISMATCH" -gt 0 ]; then
    echo -e "${RED}[FAIL] Vermagic mismatches detected:${NC}"
    for entry in "${MISMATCH_LIST[@]}"; do
        echo -e "    ${RED}*${NC} $entry"
    done
    echo
    echo -e "${RED}>>> DO NOT FLASH. Rebuild the offending modules in the same${NC}"
    echo -e "${RED}    Docker container that produced the kernel image.${NC}"
    echo -e "${BLUE}=================================================================${NC}"
    exit 1
fi

echo -e "    ${GREEN}[PASS]${NC} All $TOTAL modules share the expected vermagic."
echo -e "${BLUE}=================================================================${NC}"
exit 0
