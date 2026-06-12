# shellcheck shell=bash
# =============================================================================
# scripts/lib/log.sh   uniform colored logging + step banners + result helpers.
# =============================================================================
# Source:  . "$(dirname "${BASH_SOURCE[0]}")/lib/log.sh"
# Idempotent.
#
# Provides:
#   log::section "Title"        bold blue banner
#   log::step    "msg"          "[*] msg"
#   log::ok      "msg"          "[OK] msg" (green)
#   log::warn    "msg"          "[WARN] msg" (yellow)
#   log::fail    "msg"          "[FAIL] msg" (red)  + exit 1 unless NO_EXIT=1
#   log::info    "msg"          "[*] msg" (blue)
#   log::pass    "label"        "    - label: PASS" (green)
#   log::xfail   "label" "why"  "    - label: FAIL (why)" (red); sets GATE_FAILED=1
#
# Color is auto-disabled if NO_COLOR=1 or stdout is not a tty.
# =============================================================================

# Idempotency
if [ "${JETSON_AV_LOG_LOADED:-0}" = "1" ]; then return 0 2>/dev/null; fi

# --- Colors ------------------------------------------------------------------
if [ "${NO_COLOR:-0}" = "1" ] || [ ! -t 1 ]; then
    _C_RESET=''; _C_RED=''; _C_GREEN=''; _C_YELLOW=''; _C_BLUE=''; _C_BOLD=''
else
    _C_RESET=$'\033[0m'
    _C_RED=$'\033[0;31m'
    _C_GREEN=$'\033[0;32m'
    _C_YELLOW=$'\033[0;33m'
    _C_BLUE=$'\033[0;34m'
    _C_BOLD=$'\033[1m'
fi

# --- Functions ---------------------------------------------------------------
log::section() {
    printf '\n%s%s%s\n' "$_C_BOLD$_C_BLUE" "===========================================" "$_C_RESET"
    printf '%s%s %s%s\n' "$_C_BOLD$_C_BLUE" " " "$1" "$_C_RESET"
    printf '%s%s%s\n\n' "$_C_BOLD$_C_BLUE" "===========================================" "$_C_RESET"
}

log::step() { printf '%s[*]%s %s\n' "$_C_BLUE" "$_C_RESET" "$1"; }
log::ok()   { printf '%s[OK]%s %s\n' "$_C_GREEN" "$_C_RESET" "$1"; }
log::warn() { printf '%s[WARN]%s %s\n' "$_C_YELLOW" "$_C_RESET" "$1" >&2; }
log::info() { printf '%s[*]%s %s\n' "$_C_BLUE" "$_C_RESET" "$1"; }

log::fail() {
    printf '%s[FAIL]%s %s\n' "$_C_RED" "$_C_RESET" "$1" >&2
    if [ "${NO_EXIT:-0}" != "1" ]; then exit 1; fi
}

log::pass() {
    printf '    - %-32s %s%s%s\n' "$1" "$_C_GREEN" "PASS" "$_C_RESET"
}

log::xfail() {
    printf '    - %-32s %sFAIL%s (%s)\n' "$1" "$_C_RED" "$_C_RESET" "${2:-}"
    GATE_FAILED=1
}

# Pretty-print a key/value result row (used by audit/verify scripts).
log::kv() {
    printf '    - %-32s %s%s%s\n' "$1" "$_C_BLUE" "$2" "$_C_RESET"
}

# Optional verbose debug output (active only when DEBUG=1 in env).
log::debug() {
    [ "${DEBUG:-0}" = "1" ] || return 0
    printf '%s[DBG]%s %s\n' "$_C_BLUE" "$_C_RESET" "$1" >&2
}

# Redact secrets / IPs / serials when echoing a value to a log file.
log::redact() {
    printf '%s' "$1" | sed -E '
        s/[A-Fa-f0-9]{32,}/<REDACTED-HASH>/g;
        s/(password|token|key)=[^ ]+/\1=<REDACTED>/Ig;
    '
}

# JETSON_AV_LOG_LOADED is deliberately NOT exported: an exported guard leaks into
# child processes (env vars cross fork+exec, functions do not), so a
# sub-script sourcing this lib would hit the guard and get no functions
# (observed live 2026-06-10: install_av_phase5.sh -> build_opencv_cuda.sh
# died with 'step::run: command not found'). Plain assignment keeps the
# include guard per-process, which is exactly what an include guard means.
JETSON_AV_LOG_LOADED=1
