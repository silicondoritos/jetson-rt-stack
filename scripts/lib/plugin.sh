# shellcheck shell=bash
# =============================================================================
# scripts/lib/plugin.sh   plugin loader and hook dispatcher
# =============================================================================
# Source after config.sh and log.sh:
#   . "$HERE/lib/config.sh"
#   . "$HERE/lib/log.sh"
#   . "$HERE/lib/plugin.sh"
#
# Public API:
#   load_plugins          source all enabled plugins (built-in + custom)
#   run_hook PHASE [args] call <plugin>_PHASE for each loaded plugin
#   list_plugins          print loaded plugin slugs, one per line
#
# Plugin convention:
#   Each plugin is a directory containing plugin.sh. plugin.sh must define:
#     plugin_name()     returns a unique slug (e.g. "zedx", "axelera")
#   And may define zero or more hook functions named <slug>_<phase>():
#     <slug>_doctor()          validate prerequisites
#     <slug>_post_extract()    after L4T extraction, inject vendor sources
#     <slug>_post_defconfig()  append CONFIG_* to kernel defconfig
#     <slug>_pre_bake()        stage files into rootfs before bake
#     <slug>_post_bake()       patch extlinux.conf / overlays after bake
#
# Missing hooks are silently skipped. Plugins guard their own CONFIG flags.
# =============================================================================

if [ "${JETSON_AV_PLUGIN_LOADED:-0}" = "1" ]; then return 0 2>/dev/null || true; fi

LOADED_PLUGINS=()

load_plugins() {
    local plugin_dir plugin_name_val

    # Built-in plugins   sourced unconditionally; each checks its own CONFIG guards
    if [ -d "$REPO_ROOT/plugins" ]; then
        for plugin_dir in "$REPO_ROOT/plugins"/*/; do
            [ -f "$plugin_dir/plugin.sh" ] || continue
            # shellcheck disable=SC1090
            . "$plugin_dir/plugin.sh"
            plugin_name_val="$(plugin_name)"
            LOADED_PLUGINS+=("$plugin_name_val")
        done
    fi

    # Custom plugin path from .config
    local custom="${CONFIG_PLUGIN_CUSTOM_PATH:-}"
    if [ -n "$custom" ]; then
        if [ -f "$custom/plugin.sh" ]; then
            # shellcheck disable=SC1090
            . "$custom/plugin.sh"
            plugin_name_val="$(plugin_name)"
            LOADED_PLUGINS+=("$plugin_name_val")
        else
            echo "[plugin] WARN: CONFIG_PLUGIN_CUSTOM_PATH=$custom but $custom/plugin.sh not found" >&2
        fi
    fi
}

run_hook() {
    local phase="$1"; shift
    local plugin fn
    for plugin in "${LOADED_PLUGINS[@]}"; do
        fn="${plugin}_${phase}"
        if declare -f "$fn" > /dev/null 2>&1; then
            "$fn" "$@"
        fi
    done
}

list_plugins() {
    local plugin
    for plugin in "${LOADED_PLUGINS[@]}"; do
        echo "$plugin"
    done
}

JETSON_AV_PLUGIN_LOADED=1
export JETSON_AV_PLUGIN_LOADED
