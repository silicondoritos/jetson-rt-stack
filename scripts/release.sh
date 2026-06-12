#!/bin/bash
# =============================================================================
# scripts/release.sh   package a built workspace into release-vX.Y.Z.tar.gz
# =============================================================================
# Bundles everything a flash station needs into a single artifact:
#   - Linux_for_Tegra/kernel/Image, kernel/dtb/, kernel/Image.gz
#   - Linux_for_Tegra/rootfs/         (already populated by Phase 3)
#   - Linux_for_Tegra/staging/kernel-headers/linux-headers-*.deb
#   - Linux_for_Tegra/bootloader/, tools/                  (NVIDIA flash tooling)
#   - Linux_for_Tegra/BUILD_MANIFEST.json + EXPECTED_VERMAGIC
#   - scripts/04_flash_nvme.sh, 05_post_flash_validate.sh, flash_release.sh,
#     flash_one.sh, flash_batch.sh, personalize_first_boot.sh, lib/
#   - versions.env, docs/FLASH.md, docs/FLEET.md, docs/RUNBOOK.md
#
# Output:
#   releases/release-<VERSION>.tar.gz
#   releases/release-<VERSION>.sha256
#   releases/release-<VERSION>.manifest.json
#   releases/release-<VERSION>.sig         (only if GPG_KEY env var is set)
#
# Usage:
#   make release VERSION=v1.0.0
#   ./scripts/release.sh v1.0.0
#   GPG_KEY=ABCD1234 ./scripts/release.sh v1.0.0      # adds detached signature
#
# Each step pre-/post-verified; debug via DEBUG=1.
# =============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/config.sh"
. "$HERE/lib/log.sh"
. "$HERE/lib/verify.sh"
. "$HERE/lib/checks.sh"

PHASE=release

VERSION="${1:-${VERSION:-}}"
if [ -z "$VERSION" ]; then
    log::fail "Usage: $0 <VERSION>  (e.g., v1.0.0)"
fi

case "$VERSION" in
    v[0-9]*) ;;
    *) log::fail "VERSION must start with 'v' (got: $VERSION)" ;;
esac

RELEASES_DIR="$REPO_ROOT/releases"
WORK_DIR="$RELEASES_DIR/.work-$VERSION"
TARBALL="$RELEASES_DIR/release-$VERSION.tar.gz"
SHA_FILE="$RELEASES_DIR/release-$VERSION.sha256"
MANIFEST="$RELEASES_DIR/release-$VERSION.manifest.json"
SIG_FILE="$RELEASES_DIR/release-$VERSION.sig"

log::section "Release packaging: $VERSION"
log::info "Output dir: $RELEASES_DIR"

mkdir -p "$RELEASES_DIR"

# --- Step 1: workspace integrity --------------------------------------------
pre_workspace()  { check::dir_exists "$L4T_DIR"; }
exec_workspace() {
    check::file_exists "$KERNEL_IMAGE" || return 1
    check::file_exists "$L4T_DIR/BUILD_MANIFEST.json" || return 1
    check::file_exists "$L4T_DIR/EXPECTED_VERMAGIC" || return 1
    log::ok "workspace artifacts present"
}
post_workspace() {
    check::dir_nonempty "$L4T_DIR/rootfs"
}
step::run "Validate built workspace" pre_workspace exec_workspace post_workspace

# --- Step 2: pre-flash audit must pass --------------------------------------
pre_audit()  { check::executable "$HERE/pre_flash_audit.sh"; }
exec_audit() { "$HERE/pre_flash_audit.sh"; }
post_audit() { return 0; }   # exit code of audit is the post-check
step::run "Pre-flash audit gate" pre_audit exec_audit post_audit

# --- Step 3: stage release tree ---------------------------------------------
pre_stage()  { rm -rf "$WORK_DIR"; mkdir -p "$WORK_DIR"; }
exec_stage() {
    local payload="$WORK_DIR/payload"
    mkdir -p "$payload/Linux_for_Tegra" "$payload/scripts/lib" "$payload/docs"

    # Linux_for_Tegra: rootfs + kernel + bootloader + tools + manifests.
    # rsync to preserve perms; exclude source tree (huge, unneeded for flash).
    rsync -a --info=stats0 \
        --exclude='source/' \
        --exclude='kernel/kernel-jammy-src/' \
        --exclude='*.tbz2' \
        "$L4T_DIR/" "$payload/Linux_for_Tegra/"

    # Scripts needed at the flash station.
    cp "$HERE/04_flash_nvme.sh"           "$payload/scripts/"
    cp "$HERE/05_post_flash_validate.sh"  "$payload/scripts/"
    cp "$HERE/flash_release.sh"           "$payload/scripts/" 2>/dev/null || true
    cp "$HERE/flash_one.sh"               "$payload/scripts/" 2>/dev/null || true
    cp "$HERE/flash_batch.sh"             "$payload/scripts/" 2>/dev/null || true
    cp "$HERE/personalize_first_boot.sh"  "$payload/scripts/" 2>/dev/null || true
    cp "$HERE/verify_vermagic.sh"         "$payload/scripts/"
    cp "$HERE/show_versions.sh"           "$payload/scripts/"
    cp "$HERE/00_doctor.sh"               "$payload/scripts/"
    cp "$HERE"/lib/*.sh                   "$payload/scripts/lib/"

    # Pin manifest + key docs.
    cp "$REPO_ROOT/versions.env"          "$payload/"
    for d in FLASH.md FLEET.md RUNBOOK.md QUICKSTART.md TROUBLESHOOTING.md \
             VERMAGIC_STRATEGY.md; do
        [ -f "$REPO_ROOT/docs/$d" ] && cp "$REPO_ROOT/docs/$d" "$payload/docs/"
    done

    # Top-level README inside the release.
    cat > "$payload/README.md" <<EOF
# Jetson AV Firmware   Release $VERSION

This is a self-contained flash artifact. You do **not** need the source
repo, Docker, or the Bootlin toolchain to use it. You need:

- A Linux x86_64 host with sudo, USB, NFS-server.
- A Jetson Orin NX 16GB carrier with NVMe in the M.2 Key M slot.
- A USB-C cable to the host.

## Quick flash (single device)

\`\`\`bash
tar xzf release-$VERSION.tar.gz
cd release-$VERSION
./scripts/flash_release.sh
\`\`\`

## Batch flash (N devices)

\`\`\`bash
./scripts/flash_batch.sh fleet.csv
\`\`\`

See \`docs/FLEET.md\` and \`docs/FLASH.md\` inside this release.

## Provenance

\`\`\`
$(cat "$L4T_DIR/BUILD_MANIFEST.json")
\`\`\`
EOF
}
post_stage() {
    check::file_exists "$WORK_DIR/payload/Linux_for_Tegra/kernel/Image"
    check::file_exists "$WORK_DIR/payload/Linux_for_Tegra/BUILD_MANIFEST.json"
    check::dir_exists  "$WORK_DIR/payload/Linux_for_Tegra/rootfs"
    check::dir_exists  "$WORK_DIR/payload/Linux_for_Tegra/bootloader"
    check::dir_exists  "$WORK_DIR/payload/Linux_for_Tegra/tools"
    check::file_exists "$WORK_DIR/payload/scripts/04_flash_nvme.sh"
    check::file_exists "$WORK_DIR/payload/versions.env"
    check::file_exists "$WORK_DIR/payload/README.md"
}
step::run "Stage release tree" pre_stage exec_stage post_stage

# --- Step 4: tar + gzip with deterministic flags ----------------------------
pre_tar()  { check::dir_nonempty "$WORK_DIR/payload"; }
exec_tar() {
    # Deterministic tar: --sort=name --mtime=$BUILD_TIME --owner=0 --group=0
    local epoch
    epoch="$(grep -oE '"source_date_epoch": *"[0-9]+"' \
              "$L4T_DIR/BUILD_MANIFEST.json" | grep -oE '[0-9]+' || date +%s)"
    tar --sort=name \
        --mtime="@$epoch" \
        --owner=0 --group=0 --numeric-owner \
        -C "$WORK_DIR" \
        -czf "$TARBALL" \
        --transform "s,^payload,release-$VERSION," \
        payload
}
post_tar() {
    check::file_exists "$TARBALL"
    check::file_size_gt "$TARBALL" 1000000   # at least 1 MB
}
step::run "Tar + compress release" pre_tar exec_tar post_tar

# --- Step 5: SHA-256 + manifest ----------------------------------------------
pre_sha()  { check::file_exists "$TARBALL"; }
exec_sha() {
    ( cd "$RELEASES_DIR" && sha256sum "$(basename "$TARBALL")" > "$SHA_FILE" )
    local sha; sha="$(awk '{print $1}' "$SHA_FILE")"
    local size; size="$(stat -c %s "$TARBALL")"
    cat > "$MANIFEST" <<EOF
{
  "version":           "$VERSION",
  "release_time_iso":  "$(date -u -Iseconds)",
  "tarball":           "$(basename "$TARBALL")",
  "tarball_sha256":    "$sha",
  "tarball_size":      $size,
  "build_manifest":    $(cat "$L4T_DIR/BUILD_MANIFEST.json"),
  "expected_vermagic": "$(cat "$L4T_DIR/EXPECTED_VERMAGIC")",
  "git_head":          "$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)",
  "git_state":         "$(git -C "$REPO_ROOT" diff --quiet 2>/dev/null && echo clean || echo dirty)",
  "released_by":       "${BUILD_IDENTITY:-silicondoritos}"
}
EOF
}
post_sha() {
    check::file_exists "$SHA_FILE"
    check::file_exists "$MANIFEST"
    # Verify manifest is parseable JSON (best-effort: python or jq).
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "import json,sys; json.load(open('$MANIFEST'))" \
            || { echo "manifest not valid JSON" >&2; return 1; }
    elif command -v jq >/dev/null 2>&1; then
        jq . "$MANIFEST" >/dev/null
    fi
}
step::run "SHA-256 + manifest" pre_sha exec_sha post_sha

# --- Step 6: optional GPG signature -----------------------------------------
if [ -n "${GPG_KEY:-}" ]; then
    pre_sig()  { check::command_exists gpg; }
    exec_sig() {
        gpg --batch --yes --local-user "$GPG_KEY" \
            --detach-sign --armor --output "$SIG_FILE" "$TARBALL"
    }
    post_sig() {
        check::file_exists "$SIG_FILE"
        gpg --verify "$SIG_FILE" "$TARBALL" >/dev/null 2>&1
    }
    step::run "GPG sign release" pre_sig exec_sig post_sig
else
    step::skip "GPG sign release" "GPG_KEY not set"
fi

# --- Step 7: cleanup workspace ----------------------------------------------
pre_cleanup()  { check::dir_exists "$WORK_DIR"; }
exec_cleanup() { rm -rf "$WORK_DIR"; }
post_cleanup() { [ ! -d "$WORK_DIR" ] || { echo "work dir still present" >&2; return 1; }; }
step::run "Cleanup work dir" pre_cleanup exec_cleanup post_cleanup

# --- Final summary ----------------------------------------------------------
log::section "Release Complete"
echo "  Tarball  : $TARBALL  ($(du -h "$TARBALL" | awk '{print $1}'))"
echo "  SHA-256  : $(cat "$SHA_FILE")"
echo "  Manifest : $MANIFEST"
[ -f "$SIG_FILE" ] && echo "  Signature: $SIG_FILE"
echo
step::summary
