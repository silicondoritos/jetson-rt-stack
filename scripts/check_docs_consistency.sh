#!/usr/bin/env bash
# =============================================================================
# scripts/check_docs_consistency.sh
# -----------------------------------------------------------------------------
# Ratchet for NON-version stale values in docs/. The L4T / JetPack / CDN *pin*
# is owned by check_version_consistency.sh; this catches the specific wrong
# values that drifted across doc generations and must not creep back:
#   APX recovery id, CMA pool size, cuDNN soname, MAVLink message id, the
#   canonical isolated-core range, BSP CDN release path, leftover draft
#   scaffolding, and dead nav links.
#
# Scope: docs/ only (the rendered site). Pass a path as $1 to override.
# Exit 0 = clean. Exit 1 = a known-bad token reappeared (prints file:line).
#
# Escape hatch for *intentional* mentions (war stories, change-logs that name a
# wrong value on purpose): put the marker  docs-lint-ok  on the same line. The
# whole audit doc VERIFICATION_REPORT.md is excluded for the change-log tokens.
#
# Wired into `make doctor` and CI (.github/workflows/lint.yml), beside
# check_version_consistency.sh.
# =============================================================================
set -uo pipefail

DOCS="${1:-docs}"
SKIP='docs-lint-ok'
fail=0

# forbid <regex> <reason> [path-exclude-regex]
forbid() {
    local pat="$1" reason="$2" xfile="${3:-}"
    local hits
    hits="$(grep -rInE "$pat" "$DOCS" 2>/dev/null | grep -v "$SKIP" || true)"
    if [ -n "$xfile" ]; then
        hits="$(printf '%s\n' "$hits" | grep -vE "$xfile" || true)"
    fi
    hits="$(printf '%s' "$hits" | sed '/^[[:space:]]*$/d')"
    if [ -n "$hits" ]; then
        echo "FAIL: $reason"
        printf '%s\n' "$hits" | sed 's/^/    /'
        fail=1
    fi
}

# --- recovery / hardware ids -------------------------------------------------
forbid '0955:7023' 'AGX Orin APX id in docs (Orin NX is 0955:7323)' 'VERIFICATION_REPORT'

# --- memory / kernel config values ------------------------------------------
forbid 'CONFIG_CMA_SIZE_MBYTES=512' 'CMA pool 512MB (canonical is 2048)'
forbid 'CONFIG_PREEMPT_RT_FULL' 'stale kernel symbol (use CONFIG_PREEMPT_RT)'

# --- cuDNN soname (JetPack 6.2 ships cuDNN 9) -------------------------------
forbid 'libcudnn8|libcudnn\.so\.8' 'cuDNN 8 reference (JetPack 6.2 ships cuDNN 9 / libcudnn9-cuda-12)'

# --- MAVLink message id ------------------------------------------------------
forbid 'RC_CHANNELS_RAW' 'RC_CHANNELS_RAW (PX4/ArduPilot emit RC_CHANNELS)' 'VERIFICATION_REPORT'

# --- canonical isolated-core range is 1-5 -----------------------------------
forbid 'isolcpus=2-3|nohz_full=2-3|rcu_nocbs=2-3|--affinity=2,3|--cpus 2,3' \
       'non-canonical core range (project isolates cores 1-5)'

# --- CDN layout: BSP/rootfs/sources live under v4.3; only toolchain is v3.0 --
forbid 'r36_release_v3\.0/(release|sources)' \
       'BSP/rootfs/sources under r36_release_v3.0 (should be v4.3; only toolchain is v3.0)'

# --- leftover assistant / draft scaffolding ---------------------------------
forbid 'Next steps I can take for you|I.?ll implement it in the repo' \
       'assistant scaffolding left in published docs'
forbid 'stres-ng' 'typo: stres-ng -> stress-ng'

# --- dead nav link integrity -------------------------------------------------
if grep -rqI 'MEDIUM_POST' "$DOCS" 2>/dev/null; then
    if [ ! -f "$DOCS/MEDIUM_POST.md" ]; then
        echo "FAIL: MEDIUM_POST linked but $DOCS/MEDIUM_POST.md missing"
        fail=1
    fi
fi

if [ "$fail" -eq 0 ]; then
    echo "docs consistency: OK"
fi
exit "$fail"
