#!/bin/bash
# =============================================================================
# scripts/install_mission_inference.sh   stage the mission detect node + models
# =============================================================================
# Installs the two operator-side inference pieces the mission graph spawns:
#   /opt/jetson-av/detect_metis.py          (rclpy + axelera.app bridge node)
#   /opt/jetson-av/models/<network>/        (relocated Voyager deploy artifact)
#
# Voyager model artifacts are relocatable directories: the deployed network at
# $AXELERA_FRAMEWORK/build/<network>/ is copied wholesale and detect_metis.py
# points create_inference_stream() at it via build_root=. If the network has
# not been deployed yet, deploy.py compiles it first (~17 min, then cached).
#
# Idempotent: safe to re-run; the model copy is skipped when current.
# =============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/config.sh"
. "$HERE/lib/log.sh"
. "$HERE/lib/verify.sh"
. "$HERE/lib/checks.sh"

PHASE=mission_inference
FRAMEWORK="${AXELERA_FRAMEWORK:-/home/j/voyager-sdk}"
NETWORK="${DETECT_NETWORK:-yolov5s-v7-coco}"
MODELS_DIR=/opt/jetson-av/models

if [ "$EUID" -ne 0 ]; then log::fail "must run as root"; fi

log::section "Mission inference: detect_metis.py + $NETWORK artifact"

# --- Step 1: deploy the network if no artifact exists yet --------------------
pre_deploy()  { check::dir_exists "$FRAMEWORK"; }
exec_deploy() {
    if [ -f "$FRAMEWORK/build/$NETWORK/$NETWORK.axnet" ]; then
        log::info "deploy artifact present   skipping compile"
        return 0
    fi
    log::info "no artifact   deploying $NETWORK (first compile ~17 min)..."
    cd "$FRAMEWORK"
    PYTHONPATH="$FRAMEWORK" /opt/av-env/bin/python deploy.py "$NETWORK" \
        --aipu-cores 4 2>&1 | tail -3
}
post_deploy() { check::file_exists "$FRAMEWORK/build/$NETWORK/$NETWORK.axnet"; }
step::run "Deploy $NETWORK (or reuse cache)" pre_deploy exec_deploy post_deploy

# --- Step 2: relocate the artifact to /opt/jetson-av/models ------------------
pre_models()  { check::dir_exists "$FRAMEWORK/build/$NETWORK"; }
exec_models() {
    mkdir -p "$MODELS_DIR"
    # rsync-style refresh: cheap when current, correct when the deploy changed.
    cp -ru "$FRAMEWORK/build/$NETWORK" "$MODELS_DIR/"
    chmod -R a+rX "$MODELS_DIR"
}
post_models() { check::file_exists "$MODELS_DIR/$NETWORK/$NETWORK.axnet"; }
step::run "Stage model artifact at $MODELS_DIR" pre_models exec_models post_models

# --- Step 2b: SLAM wiring (launch file + wrapper overrides) -------------------
# cuVSLAM needs a rectified stereo pair; the wrapper publishes left/right
# only when video.publish_left_right is on. The override YAML feeds the
# camera node (ros_params_override_path in launch_av_mission.sh) and the
# launch file remaps cuVSLAM's inputs to the wrapper's >=5.1 topic names.
pre_slam()  { check::file_exists "$HERE/zedx_vslam.launch.py"; }
exec_slam() {
    install -m 0644 "$HERE/zedx_vslam.launch.py" /opt/jetson-av/zedx_vslam.launch.py
    if [ ! -f /etc/jetson-av/zedx_overrides.yaml ]; then
        cat > /etc/jetson-av/zedx_overrides.yaml <<'EOF'
# zed-ros2-wrapper parameter overrides for the mission graph.
# left/right rect topics are required by cuVSLAM (zedx_vslam.launch.py);
# the wrapper keeps them off by default.
/**:
    ros__parameters:
        video:
            publish_left_right: true
EOF
    fi
}
post_slam() {
    check::file_exists /opt/jetson-av/zedx_vslam.launch.py
    check::file_exists /etc/jetson-av/zedx_overrides.yaml
}
step::run "Stage SLAM launch + wrapper overrides" pre_slam exec_slam post_slam

# --- Step 3: install the detect node ------------------------------------------
pre_node()  { check::file_exists "$HERE/detect_metis.py"; }
exec_node() {
    mkdir -p /opt/jetson-av
    install -m 0755 "$HERE/detect_metis.py" /opt/jetson-av/detect_metis.py
}
post_node() {
    check::file_exists /opt/jetson-av/detect_metis.py
    # Import check: rclpy + vision_msgs + the app framework must all resolve.
    set +u
    . /opt/ros/humble/setup.bash 2>/dev/null
    set -u
    AXELERA_FRAMEWORK="$FRAMEWORK" PYTHONPATH="$FRAMEWORK:${PYTHONPATH:-}" \
        /opt/av-env/bin/python -c \
        "import rclpy, vision_msgs; import axelera.app" 2>/dev/null \
        || { log::warn "import check failed   is the ZED wrapper env installed?"; return 1; }
}
STRICT=0 step::run "Install /opt/jetson-av/detect_metis.py" pre_node exec_node post_node

log::section "Mission inference install complete"
step::summary
