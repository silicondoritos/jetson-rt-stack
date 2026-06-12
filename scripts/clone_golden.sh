#!/bin/bash
# =============================================================================
# scripts/clone_golden.sh   capture a golden image from a configured Jetson
# =============================================================================
# Workflow:
#   1. You flash a base image onto a "golden" Jetson with `make flash`.
#   2. You boot it, install your apps + ROS packages + models, run flights,
#      verify everything works exactly as you want it.
#   3. You power the golden Jetson off and put it in recovery mode.
#   4. You run THIS script. It:
#       - reads the live NVMe partition images back to the host via
#         NVIDIA's `l4t_initrd_flash.sh --read` mechanism;
#       - bundles them into golden-images/golden-<TAG>-<DATE>/;
#       - writes a manifest with checksum + provenance;
#       - signs (optional, GPG_KEY).
#   5. To redeploy: `make flash-golden GOLDEN=<TAG>`. Each receiving Jetson
#      goes into recovery mode, gets the EXACT bit pattern of the golden.
#
# After flashing a copy, the receiving Jetson still runs
# personalize_first_boot.sh → unique hostname + SSH host keys + optional
# static IP. Same fleet identity machinery as a fresh flash.
#
# Usage:
#   ./scripts/clone_golden.sh <tag> [--from-staged]
#
#   <tag>            short label, e.g. "v1.0-bench-validated"
#   --from-staged    use the staged Linux_for_Tegra/ tree's already-baked
#                    rootfs as the source (skip the recovery-mode read).
#                    Useful for snapshotting at bake time, before any
#                    on-device customization.
#
# Env:
#   GOLDEN_DIR       override golden-images/ (default: $REPO_ROOT/golden-images)
#   APX_TIMEOUT      seconds to wait for the Jetson to enter APX (default 60)
#   GPG_KEY          if set, GPG-sign the resulting manifest
#
# Each step pre/post-verified. DEBUG=1 enables bash -x trace into the log.
# =============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/config.sh"
. "$HERE/lib/log.sh"
. "$HERE/lib/verify.sh"
. "$HERE/lib/checks.sh"

PHASE=golden_clone

TAG="${1:-}"
MODE="recovery"     # default: read from a Jetson in recovery mode
shift || true
while [ $# -gt 0 ]; do
    case "$1" in
        --from-staged) MODE=staged ;;
        --help|-h)
            sed -n '/^# =============/,/^# =============$/p' "$0" | sed 's/^# //'
            exit 0 ;;
        *) log::warn "unknown arg: $1" ;;
    esac
    shift
done
[ -n "$TAG" ] || log::fail "Usage: $0 <tag> [--from-staged]"
case "$TAG" in
    *' '*|*/*) log::fail "tag must be a single shell-safe token" ;;
esac

GOLDEN_DIR="${GOLDEN_DIR:-$REPO_ROOT/golden-images}"
STAMP="$(date +%Y%m%d-%H%M%S)"
GOLDEN_NAME="golden-${TAG}-${STAMP}"
DEST="$GOLDEN_DIR/$GOLDEN_NAME"

log::section "Clone Golden Image   tag: $TAG  mode: $MODE"
log::info "Output : $DEST"

mkdir -p "$DEST"

# -----------------------------------------------------------------------
# Step 1   sanity-check the L4T tree (we need its tools either way)
# -----------------------------------------------------------------------
pre_l4t()  { check::dir_exists "$L4T_DIR"; }
exec_l4t() {
    check::executable "$L4T_DIR/tools/kernel_flash/l4t_initrd_flash.sh" || return 1
    check::executable "$L4T_DIR/tools/backup_restore/l4t_backup_restore.sh" 2>/dev/null \
        && log::info "backup_restore.sh available (preferred path)" \
        || log::info "backup_restore.sh not present   will use l4t_initrd_flash --read fallback"
}
post_l4t() { return 0; }
step::run "L4T tools available" pre_l4t exec_l4t post_l4t

# -----------------------------------------------------------------------
# Step 2   capture the source bytes
# -----------------------------------------------------------------------
case "$MODE" in
    recovery)
        # Mode A: pull from a running Jetson via NVIDIA's read flow.
        # Requires the Jetson to be in APX recovery mode and connected
        # via direct USB-C to the host motherboard.
        pre_apx()  { check::command_exists lsusb; }
        exec_apx() {
            APX_TIMEOUT="${APX_TIMEOUT:-60}"
            log::info "Polling for APX device (USB ID $USB_ID_APX) for ${APX_TIMEOUT}s..."
            local i=0
            while [ "$i" -lt "$APX_TIMEOUT" ]; do
                if lsusb 2>/dev/null | grep -q "$USB_ID_APX"; then
                    log::ok "APX detected"
                    return 0
                fi
                sleep 1; i=$((i+1)); printf '.'
            done
            echo
            return 1
        }
        post_apx() { check::usb_device_visible "$USB_ID_APX"; }
        step::run "Detect Jetson recovery mode" pre_apx exec_apx post_apx

        pre_read()  { check::dir_exists "$L4T_DIR"; }
        exec_read() {
            cd "$L4T_DIR"
            # Prefer the dedicated backup script if present (R36.x ships
            # `tools/backup_restore/l4t_backup_partitions.sh`). Falls back
            # to `l4t_initrd_flash.sh --read` for older trees.
            if [ -x "$L4T_DIR/tools/backup_restore/l4t_backup_partitions.sh" ]; then
                log::info "Using l4t_backup_partitions.sh"
                sudo ./tools/backup_restore/l4t_backup_partitions.sh \
                    -u "$DEST" \
                    "$TARGET_BOARD"
            else
                log::info "Using l4t_initrd_flash.sh --read"
                # --read pulls back the partitions defined in the XML.
                # The output lands in tools/kernel_flash/images/<board>/
                # by default; we move it into our golden-images/ tree.
                sudo ./tools/kernel_flash/l4t_initrd_flash.sh \
                    --read \
                    --external-device "$TARGET_STORAGE_DEV" \
                    -c "$TARGET_FLASH_XML" \
                    --showlogs --network usb0 \
                    "$TARGET_BOARD" internal
                local img_src="tools/kernel_flash/images/$TARGET_BOARD"
                [ -d "$img_src" ] || img_src="tools/kernel_flash/images"
                if [ -d "$img_src" ]; then
                    log::info "Moving $img_src/ → $DEST/"
                    sudo mv "$img_src"/* "$DEST/" 2>/dev/null || \
                        sudo cp -r "$img_src/." "$DEST/"
                fi
            fi
        }
        post_read() {
            # We expect at least the rootfs APP image and a kernel.
            local rootfs
            rootfs=$(find "$DEST" -name 'system.img*' -o -name 'app*.raw' \
                       -o -name 'app*.img' 2>/dev/null | head -1)
            [ -n "$rootfs" ] || { echo "no rootfs image captured" >&2; return 1; }
            check::file_size_gt "$rootfs" 100000000   # >= 100 MB
        }
        step::run "Read partitions from Jetson" pre_read exec_read post_read
        ;;

    staged)
        # Mode B: snapshot the staged Linux_for_Tegra/rootfs/ as if it had
        # been live. Useful for capturing a baseline before any on-device
        # customization. The output is a tar of the rootfs rather than
        # raw partition images   re-flash uses the standard make flash.
        pre_stage()  { check::dir_exists "$ROOTFS"; }
        exec_stage() {
            log::info "Snapshotting $ROOTFS..."
            sudo tar --sort=name --owner=0 --group=0 --numeric-owner \
                -C "$L4T_DIR" \
                -czf "$DEST/staged-rootfs.tar.gz" rootfs
        }
        post_stage() {
            check::file_exists "$DEST/staged-rootfs.tar.gz"
            check::file_size_gt "$DEST/staged-rootfs.tar.gz" 50000000  # 50 MB
        }
        step::run "Snapshot staged rootfs" pre_stage exec_stage post_stage
        ;;
esac

# -----------------------------------------------------------------------
# Step 3   write golden manifest
# -----------------------------------------------------------------------
pre_manifest()  { check::dir_nonempty "$DEST"; }
exec_manifest() {
    local size_bytes; size_bytes="$(du -sb "$DEST" | awk '{print $1}')"
    local size_human; size_human="$(du -sh "$DEST" | awk '{print $1}')"
    cat > "$DEST/golden.manifest.json" <<EOF
{
  "tag":               "$TAG",
  "captured_at_iso":   "$(date -u -Iseconds)",
  "captured_by":       "${BUILD_IDENTITY:-silicondoritos}",
  "capture_mode":      "$MODE",
  "size_bytes":        $size_bytes,
  "size_human":        "$size_human",
  "source_target_board":   "$TARGET_BOARD",
  "source_storage_dev":    "$TARGET_STORAGE_DEV",
  "build_manifest":    $( [ -f "$BUILD_MANIFEST" ] && cat "$BUILD_MANIFEST" || echo '"unavailable"' ),
  "git_head":          "$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)",
  "git_state":         "$(git -C "$REPO_ROOT" diff --quiet 2>/dev/null && echo clean || echo dirty)"
}
EOF

    # SHA-256 every file we captured for tamper-evidence.
    ( cd "$DEST" && find . -type f ! -name 'golden.manifest.json' \
            ! -name 'CHECKSUMS.sha256' ! -name '*.sig' \
            -print0 | sort -z | xargs -0 sha256sum > CHECKSUMS.sha256 )
}
post_manifest() {
    check::file_exists "$DEST/golden.manifest.json"
    check::file_exists "$DEST/CHECKSUMS.sha256"
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "import json,sys; json.load(open('$DEST/golden.manifest.json'))"
    fi
}
step::run "Write golden manifest + checksums" pre_manifest exec_manifest post_manifest

# -----------------------------------------------------------------------
# Step 4   optional GPG signature
# -----------------------------------------------------------------------
if [ -n "${GPG_KEY:-}" ]; then
    pre_sig()  { check::command_exists gpg; }
    exec_sig() {
        gpg --batch --yes --local-user "$GPG_KEY" \
            --detach-sign --armor \
            --output "$DEST/golden.manifest.sig" "$DEST/golden.manifest.json"
    }
    post_sig() { check::file_exists "$DEST/golden.manifest.sig"; }
    step::run "GPG sign golden manifest" pre_sig exec_sig post_sig
else
    step::skip "GPG sign golden manifest" "GPG_KEY not set"
fi

log::section "Golden Image Captured"
echo "  Tag    : $TAG"
echo "  Path   : $DEST  ($(du -sh "$DEST" | awk '{print $1}'))"
echo "  Files  : $(find "$DEST" -maxdepth 1 -type f | wc -l) at top level"
echo
echo "Redeploy with:"
echo "  make flash-golden GOLDEN=$GOLDEN_NAME"
echo "  ./scripts/flash_golden.sh $GOLDEN_NAME"
echo
step::summary
