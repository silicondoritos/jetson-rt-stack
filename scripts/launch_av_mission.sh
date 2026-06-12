#!/bin/bash
# =============================================================================
# scripts/launch_av_mission.sh   bring up the full AV mission stack
# =============================================================================
# Boot-time launch graph: capture → inference → SLAM → mapping → planning →
# MAVROS bridge. Started by jetson-av-mission.service.
#
# Modes:
#   --dry-run    print every node it would launch, exit 0 (sanity check)
#   --debug      ros2 launch --log-level debug
#   (default)    real launch
#
# Configurable via /etc/jetson-av/mission.conf:
#   ENABLE_CAMERA=1
#   ENABLE_INFERENCE=1
#   ENABLE_SLAM=1
#   ENABLE_NVBLOX=1
#   ENABLE_NAV2=1
#   ENABLE_MAVROS=1
#   FCU_URL=/dev/ttyTHS1:921600   (THS0 is the debug console   never MAVLink)
# =============================================================================
set -u

CONF=/etc/jetson-av/mission.conf
ENABLE_CAMERA=1
ENABLE_INFERENCE=1
ENABLE_SLAM=1
ENABLE_NVBLOX=1
ENABLE_NAV2=1
ENABLE_MAVROS=1
FCU_URL=/dev/ttyTHS1:921600
[ -f "$CONF" ] && . "$CONF"

DRY=0; DEBUG_LAUNCH=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY=1 ;;
        --debug)   DEBUG_LAUNCH=1 ;;
    esac
done

log()  { echo "[mission] $*"; }
fail() { echo "[mission] FAIL: $*" >&2; exit 1; }

# Source the stack environment. ROS setup scripts reference unbound
# variables, and under `set -u` an expansion error aborts the script even
# behind `||`   so drop -u around the sourcing.
set +u
[ -f /etc/profile.d/jetson-av-stack.sh ] && . /etc/profile.d/jetson-av-stack.sh
[ -f /opt/ros/humble/setup.bash ] && . /opt/ros/humble/setup.bash || \
    fail "ROS 2 not installed   run install_av_stack.sh first"
set -u

mkdir -p /var/log/jetson-av/ros
LAUNCH_LOG=/var/log/jetson-av/mission-$(date +%Y%m%d-%H%M%S).log
exec >>"$LAUNCH_LOG" 2>&1
log "===== mission start ($(date -u -Iseconds)) ====="
log "config: camera=$ENABLE_CAMERA inference=$ENABLE_INFERENCE slam=$ENABLE_SLAM nvblox=$ENABLE_NVBLOX nav2=$ENABLE_NAV2 mavros=$ENABLE_MAVROS"
log "fcu_url=$FCU_URL  dry=$DRY  debug=$DEBUG_LAUNCH"

# Pin nodes to specific isolated cores via systemd-run --scope.
spawn() {
    local label="$1" cores="$2"; shift 2
    log "spawn[$label] cores=$cores cmd: $*"
    if [ "$DRY" = "1" ]; then return 0; fi
    # systemd-run units start from PID 1 with NO ROS environment   every
    # ros2-based node crash-loops without it (observed on the first live
    # mission start, 2026-06-11). A login shell sources /etc/profile.d/
    # jetson-av-stack.sh (ROS + workspaces + venv + RMW + AXELERA_*).
    # HOME + ROS_LOG_DIR: transient units have no HOME, and ros2 launch
    # dies with "Failed to get logging directory" without one.
    systemd-run --unit="jetson-av-${label}" --slice=jetson-av.slice \
        --property="AllowedCPUs=$cores" --property="CPUQuota=400%" \
        --property="Restart=always" --property="RestartSec=5" \
        --setenv=HOME=/root --setenv=ROS_LOG_DIR=/var/log/jetson-av/ros \
        -- /bin/bash -lc 'exec "$@"' _ "$@" || log "WARN: spawn failed for $label"
}

LAUNCH_OPT=""
[ "$DEBUG_LAUNCH" = "1" ] && LAUNCH_OPT="--log-level debug"

# --- Camera (ZED X) -------------------------------------------------------
if [ "$ENABLE_CAMERA" = "1" ]; then
    if [ -d /usr/local/zed ]; then
        # ros_params_override_path enables left/right rect topics for cuVSLAM
        # (wrapper >= 5.1 keeps them off by default; YAML staged by
        # install_mission_inference.sh).
        CAM_OVERRIDES=""
        [ -f /etc/jetson-av/zedx_overrides.yaml ] && \
            CAM_OVERRIDES="ros_params_override_path:=/etc/jetson-av/zedx_overrides.yaml"
        spawn camera 2-3 ros2 launch zed_wrapper zed_camera.launch.py camera_model:=zedx $CAM_OVERRIDES
    else
        log "WARN: ZED SDK not installed   camera node skipped"
    fi
fi

# --- Object detection on Metis -------------------------------------------
if [ "$ENABLE_INFERENCE" = "1" ]; then
    if /opt/av-env/bin/python -c 'import axelera.runtime' 2>/dev/null; then
        spawn detect 1 /opt/av-env/bin/python /opt/jetson-av/detect_metis.py
    else
        log "WARN: axelera.runtime not available   inference node skipped"
    fi
fi

# --- Visual SLAM (Isaac ROS cuVSLAM) -------------------------------------
if [ "$ENABLE_SLAM" = "1" ]; then
    if ros2 pkg list 2>/dev/null | grep -q isaac_ros_visual_slam; then
        # The stock isaac_ros_visual_slam.launch.py has NO remappings   it
        # listens on visual_slam/image_0|1, never the ZED topics. Our launch
        # file (staged by install_mission_inference.sh) wires the wrapper's
        # >=5.1 stereo rect topics into cuVSLAM.
        SLAM_LAUNCH=/opt/jetson-av/zedx_vslam.launch.py
        [ -f "$SLAM_LAUNCH" ] || SLAM_LAUNCH="isaac_ros_visual_slam isaac_ros_visual_slam.launch.py"
        spawn slam 4-5 ros2 launch $SLAM_LAUNCH $LAUNCH_OPT
    else
        log "WARN: isaac_ros_visual_slam not installed   SLAM skipped"
    fi
fi

# --- 3D mapping (nvblox) -------------------------------------------------
if [ "$ENABLE_NVBLOX" = "1" ]; then
    if ros2 pkg list 2>/dev/null | grep -q nvblox; then
        # nvblox shares core 6 with Nav2: the zed wrapper needs two cores
        # (grab + ISP-resize + publish saturate one), so it owns 2-3.
        spawn nvblox 6 ros2 launch nvblox_examples_bringup nvblox_zed_example.launch.py $LAUNCH_OPT
    else
        log "WARN: nvblox not installed   mapping skipped"
    fi
fi

# --- Nav2 ----------------------------------------------------------------
if [ "$ENABLE_NAV2" = "1" ]; then
    if ros2 pkg list 2>/dev/null | grep -q nav2_bringup; then
        spawn nav2 6 ros2 launch nav2_bringup navigation_launch.py $LAUNCH_OPT
    else
        log "WARN: nav2_bringup not installed   Nav2 skipped"
    fi
fi

# --- MAVROS --------------------------------------------------------------
if [ "$ENABLE_MAVROS" = "1" ]; then
    if ros2 pkg list 2>/dev/null | grep -q '^mavros$'; then
        spawn mavros 7 ros2 launch mavros mavros.launch fcu_url:=$FCU_URL
    else
        log "WARN: mavros not installed   bridge skipped"
    fi
fi

if [ "$DRY" = "1" ]; then
    log "dry-run complete"
    exit 0
fi

log "all nodes spawned; mission running"
# Keep this script alive so systemd considers the service active.
# Real shutdown comes via SIGTERM from systemd.
trap 'log "stopping mission"; systemctl stop jetson-av.slice; exit 0' INT TERM
while true; do sleep 60; done
