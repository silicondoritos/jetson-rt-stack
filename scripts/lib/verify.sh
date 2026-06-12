# shellcheck shell=bash
# =============================================================================
# scripts/lib/verify.sh   pre/post step verification framework
# =============================================================================
# Wraps each unit of work in a deterministic gate:
#
#   1. PRE-CHECK     confirm preconditions are met (file exists, command works,
#                    expected state holds). If false, abort BEFORE doing harm.
#   2. EXECUTE       run the actual work. Output captured to a step log.
#   3. POST-CHECK    confirm postconditions hold (artifact produced, service
#                    running, value present). Fails the step if not.
#   4. RECORD        append result to STEP_MANIFEST so audits can replay.
#
# Source order:  config.sh → log.sh → verify.sh
#
# Public API:
#   step::run "Step name" pre_fn exec_fn post_fn
#   step::skip "Step name" "reason"
#   step::current                          name of currently-executing step
#   step::manifest_path                    path of the step manifest
#
# Environment switches:
#   DEBUG=1            enable bash -x and verbose log output
#   DRY_RUN=1          run pre/post but skip execute (planning mode)
#   STEP_LOG_DIR=...   override log directory (default: $REPO_ROOT/logs)
#   STEP_MANIFEST=...  override manifest path
#   STRICT=1           abort the entire script on any step failure (default)
#   STRICT=0           continue past failures, accumulate, summarize at end
# =============================================================================

# Idempotency
if [ "${JETSON_AV_VERIFY_LOADED:-0}" = "1" ]; then return 0 2>/dev/null; fi

# Require log.sh + config.sh first
if [ "${JETSON_AV_LOG_LOADED:-0}" != "1" ]; then
    echo "[verify.sh] ERROR: source lib/log.sh first" >&2
    return 1 2>/dev/null || exit 1
fi
if [ "${JETSON_AV_CONFIG_LOADED:-0}" != "1" ]; then
    echo "[verify.sh] ERROR: source lib/config.sh first" >&2
    return 1 2>/dev/null || exit 1
fi

# --- Globals ----------------------------------------------------------------
STEP_LOG_DIR="${STEP_LOG_DIR:-$REPO_ROOT/logs}"
STEP_MANIFEST="${STEP_MANIFEST:-$STEP_LOG_DIR/STEP_MANIFEST.tsv}"
STRICT="${STRICT:-1}"
DEBUG="${DEBUG:-0}"
DRY_RUN="${DRY_RUN:-0}"

mkdir -p "$STEP_LOG_DIR"

# Initialize manifest with header if missing
if [ ! -f "$STEP_MANIFEST" ]; then
    printf 'timestamp\tstep\tphase\tresult\tduration_s\tlog_path\n' > "$STEP_MANIFEST"
fi

# Track per-script accumulator
STEP__CURRENT=""
STEP__FAILED_COUNT=0
STEP__PASSED_COUNT=0
STEP__SKIPPED_COUNT=0

# --- Helpers ---------------------------------------------------------------

# Sanitize a step name into a filesystem-safe slug.
__step_slug() {
    printf '%s' "$1" | tr '[:upper:] /:' '[:lower:]___' | tr -cd 'a-z0-9_-'
}

# Append a manifest row.
__step_record() {
    local step="$1" result="$2" duration="$3" log="$4"
    local phase="${PHASE:-unknown}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(date -u -Iseconds)" "$step" "$phase" "$result" "$duration" "$log" \
        >> "$STEP_MANIFEST"
}

# Public: name of the step currently executing.
step::current() { printf '%s\n' "$STEP__CURRENT"; }
step::manifest_path() { printf '%s\n' "$STEP_MANIFEST"; }

# Public: skip a step (records SKIPPED in manifest).
step::skip() {
    local name="$1" reason="${2:-no reason given}"
    log::warn "SKIP: $name  ($reason)"
    __step_record "$name" "SKIPPED" "0" "(none)"
    STEP__SKIPPED_COUNT=$((STEP__SKIPPED_COUNT + 1))
}

# Public: run a fully-gated step.
#   $1 = display name (e.g., "Extract L4T BSP")
#   $2 = pre-check function name (returns 0/1)
#   $3 = execution function name (returns 0/1)
#   $4 = post-check function name (returns 0/1)
step::run() {
    local name="$1" pre_fn="$2" exec_fn="$3" post_fn="$4"
    local slug; slug="$(__step_slug "$name")"
    local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
    local log="$STEP_LOG_DIR/${stamp}_${slug}.log"
    local started; started="$(date +%s)"
    STEP__CURRENT="$name"

    log::section "STEP: $name"
    log::info "Log: $log"
    if [ "$DEBUG" = "1" ]; then
        log::info "Debug mode ON (bash -x trace will be in log)"
    fi
    if [ "$DRY_RUN" = "1" ]; then
        log::warn "DRY_RUN=1   execute will be skipped (pre/post still run)"
    fi

    # Open the per-step log.
    {
        echo "===== STEP: $name ====="
        echo "Started: $(date -u -Iseconds)"
        echo "Pre-check: $pre_fn"
        echo "Execute:   $exec_fn"
        echo "Post-check:$post_fn"
        echo "DEBUG=$DEBUG  DRY_RUN=$DRY_RUN  STRICT=$STRICT"
        echo "------------------------"
    } > "$log"

    # 1. Pre-check ----------------------------------------------------------
    log::step "[pre]  $pre_fn"
    if "$pre_fn" >>"$log" 2>&1; then
        log::ok "pre-check passed"
    else
        log::xfail "pre-check $pre_fn" "see $log"
        __step_record "$name" "PRE_FAIL" "$(($(date +%s) - started))" "$log"
        STEP__FAILED_COUNT=$((STEP__FAILED_COUNT + 1))
        if [ "$STRICT" = "1" ]; then
            log::fail "Aborting: pre-check failed for '$name'"
        fi
        return 1
    fi

    # 2. Execute -----------------------------------------------------------
    if [ "$DRY_RUN" = "1" ]; then
        log::warn "[exec] skipped (DRY_RUN=1)"
        echo "[DRY_RUN] execute skipped" >> "$log"
    else
        log::step "[exec] $exec_fn"
        local exec_ok=0
        if [ "$DEBUG" = "1" ]; then
            ( set -x; "$exec_fn" ) >>"$log" 2>&1 || exec_ok=$?
        else
            "$exec_fn" >>"$log" 2>&1 || exec_ok=$?
        fi
        if [ "$exec_ok" -ne 0 ]; then
            log::xfail "execute $exec_fn" "exit=$exec_ok   see $log"
            # Run post-check anyway for forensic data, but don't gate on it.
            log::warn "Running post-check for forensic data despite failure..."
            "$post_fn" >>"$log" 2>&1 || true
            __step_record "$name" "EXEC_FAIL" "$(($(date +%s) - started))" "$log"
            STEP__FAILED_COUNT=$((STEP__FAILED_COUNT + 1))
            if [ "$STRICT" = "1" ]; then
                log::fail "Aborting: execute failed for '$name'"
            fi
            return 1
        fi
        log::ok "execute succeeded"
    fi

    # 3. Post-check --------------------------------------------------------
    log::step "[post] $post_fn"
    if "$post_fn" >>"$log" 2>&1; then
        log::ok "post-check passed"
    else
        log::xfail "post-check $post_fn" "see $log"
        __step_record "$name" "POST_FAIL" "$(($(date +%s) - started))" "$log"
        STEP__FAILED_COUNT=$((STEP__FAILED_COUNT + 1))
        if [ "$STRICT" = "1" ]; then
            log::fail "Aborting: post-check failed for '$name'"
        fi
        return 1
    fi

    # 4. Record + summary --------------------------------------------------
    local duration=$(($(date +%s) - started))
    __step_record "$name" "PASS" "$duration" "$log"
    STEP__PASSED_COUNT=$((STEP__PASSED_COUNT + 1))
    log::ok "STEP COMPLETE: $name  (${duration}s)"
    STEP__CURRENT=""
    return 0
}

# Public: print the per-script tally.
step::summary() {
    echo
    log::section "Step Summary"
    printf '  Passed : %s%d%s\n' "$_C_GREEN" "$STEP__PASSED_COUNT" "$_C_RESET"
    printf '  Failed : %s%d%s\n' "$_C_RED"   "$STEP__FAILED_COUNT" "$_C_RESET"
    printf '  Skipped: %s%d%s\n' "$_C_YELLOW" "$STEP__SKIPPED_COUNT" "$_C_RESET"
    printf '  Manifest: %s\n' "$STEP_MANIFEST"
    if [ "$STEP__FAILED_COUNT" -gt 0 ]; then
        return 1
    fi
    return 0
}

# JETSON_AV_VERIFY_LOADED is deliberately NOT exported: an exported guard leaks into
# child processes (env vars cross fork+exec, functions do not), so a
# sub-script sourcing this lib would hit the guard and get no functions
# (observed live 2026-06-10: install_av_phase5.sh -> build_opencv_cuda.sh
# died with 'step::run: command not found'). Plain assignment keeps the
# include guard per-process, which is exactly what an include guard means.
JETSON_AV_VERIFY_LOADED=1
