#!/usr/bin/env bash
# =============================================================================
# scripts/check_version_consistency.sh
# -----------------------------------------------------------------------------
# Enforce versions.env as the SINGLE SOURCE OF TRUTH for the L4T / JetPack pin.
#
# The repo claims "versions.env is the one place all version numbers live," but
# ~100 of those numbers are copy-pasted into prose across 19 docs/scripts. This
# linter mechanically proves they still agree with versions.env, so a re-pin (or
# a future bump) can't silently leave stale R36.x / JetPack / CDN tokens behind.
#
# Wired into `make doctor` and CI (.github/workflows/lint.yml).
# Exit 0 = consistent. Exit 1 = drift (prints every offending file:line).
#
# Escape hatch for *intentional* historical references (change-logs, war
# stories, compatibility tables that name several releases on purpose):
#   - put the marker  version-lint-ok  in a comment on the same line, OR
#   - add the file's basename to ALLOW_FILES below.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/config.sh
. "$HERE/lib/config.sh"
# shellcheck source=scripts/lib/log.sh
. "$HERE/lib/log.sh"

# --- Expected values, derived from the single source of truth ----------------
L4T_NUM="${L4T_VERSION#R}"                                   # R36.4.3 -> 36.4.3
L4T_BRANCH="$(printf '%s' "$L4T_NUM" | cut -d. -f1,2)"       # 36.4
JP="$JETPACK_VERSION"                                        # 6.2
CDN_REL="${L4T_CDN_RELEASE:-r36_release_v4.3}"               # explicit pin (CDN layout is irregular)
CDN_TC="${L4T_TOOLCHAIN_CDN:-r36_release_v3.0}"              # toolchain mirror (release-independent)

# Files allowed to mention superseded versions (history, roadmaps, matrices).
ALLOW_FILES=(VERIFICATION_REPORT.md COMPATIBILITY.md ROADMAP_JP7.md claims.yaml CHANGELOG.md check_docs_consistency.sh analytics_table.md)

violations=0
flag() { printf '  %sDRIFT%s  %s\n' "$_C_RED" "$_C_RESET" "$1"; violations=$((violations + 1)); }

_allowed_file() {
  local base a; base="$(basename "$1")"
  for a in "${ALLOW_FILES[@]}"; do [ "$base" = "$a" ] && return 0; done
  return 1
}

# Tracked text files only (respect .gitignore); skip self.
# (while-read instead of mapfile so this runs on macOS bash 3.2 as well as CI.)
FILES=()
while IFS= read -r _rel; do
  [ -n "$_rel" ] && FILES+=("$_rel")
done < <(
  git -C "$REPO_ROOT" ls-files 2>/dev/null \
    | grep -E '\.(md|sh|env|ya?ml)$|/?Dockerfile$|/?Makefile$|/?Kconfig$' \
    | grep -v 'scripts/check_version_consistency.sh' || true
)

log::section "version-consistency: pin = L4T $L4T_VERSION / JetPack $JP (branch $L4T_BRANCH, CDN $CDN_REL)"

# One grep pass over all tracked files for lines carrying a version-shaped token,
# then inspect only those lines. Far faster than a per-line loop over every file.
TOKEN_RE='R?36\.[0-9]|r36_release_v|6\.2\.[0-9]|_aarch64\.tbz2'
abs=()
for rel in "${FILES[@]}"; do
  _allowed_file "$rel" && continue
  [ -f "$REPO_ROOT/$rel" ] && abs+=("$REPO_ROOT/$rel")
done

while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  case "$entry" in *version-lint-ok*) continue ;; esac
  af="${entry%%:*}"; rest="${entry#*:}"; lineno="${rest%%:*}"; content="${rest#*:}"
  rel="${af#"$REPO_ROOT"/}"

  # 1) L4T release tokens: R?36.<minor>[.patch] whose branch != expected.
  for tok in $(grep -oE 'R?36\.[0-9]+(\.[0-9]+)?' <<<"$content" || true); do
    b="${tok#R}"; maj="${b%%.*}"; b="${b#*.}"; br="$maj.${b%%.*}"
    [ "$br" = "$L4T_BRANCH" ] || flag "$rel:$lineno  L4T token \"$tok\" (expected branch $L4T_BRANCH)"
  done
  # 2) CDN release dirs: must be the pinned release, except the toolchain mirror.
  for tok in $(grep -oE 'r36_release_v[0-9.]+(/[a-z]+)?' <<<"$content" || true); do
    case "$tok" in
      *toolchain) : ;;
      "$CDN_REL"|"$CDN_REL"/*) : ;;
      *) dir="${tok%%/*}"
         [ "$dir" = "$CDN_REL" ] || [ "$dir" = "$CDN_TC" ] \
           || flag "$rel:$lineno  CDN dir \"$tok\" (expected $CDN_REL, or $CDN_TC/toolchain)" ;;
    esac
  done
  # 3) JetPack point-release tokens 6.2.x that don't match the pin.
  for tok in $(grep -oE '6\.2\.[0-9]+' <<<"$content" || true); do
    [ "$tok" = "$JP" ] || flag "$rel:$lineno  JetPack token \"$tok\" (pin is $JP)"
  done
  # 4) Stale BSP/rootfs tarball filenames.
  for tok in $(grep -oE '(Jetson_Linux|Tegra_Linux_Sample-Root-Filesystem)[A-Za-z0-9._-]*_aarch64\.tbz2' <<<"$content" || true); do
    [ "$tok" = "$TARBALL_L4T" ] || [ "$tok" = "$TARBALL_ROOTFS" ] \
      || flag "$rel:$lineno  stale tarball \"$tok\" (expected $TARBALL_L4T / $TARBALL_ROOTFS)"
  done
done < <(grep -nHE "$TOKEN_RE" "${abs[@]}" 2>/dev/null || true)

echo
if [ "$violations" -eq 0 ]; then
  log::ok "version-consistency: all references agree with versions.env"
  exit 0
fi
log::fail "version-consistency: $violations reference(s) disagree with versions.env (fix, or mark 'version-lint-ok')"
