#!/bin/bash
# =============================================================================
# scripts/install_zed_ros2_wrapper.sh   build the Stereolabs zed-ros2-wrapper
# =============================================================================
# Builds the ROS 2 camera node the mission graph spawns:
#   ros2 launch zed_wrapper zed_camera.launch.py camera_model:=zedx
#
# Version pinning: wrapper tag v5.3.1 pairs with ZED SDK 5.3.1 on ROS 2
# Humble (master needs SDK >= 5.2; SDK-5.3 features are compile-gated).
# zed_msgs comes from apt on Humble (the package was renamed from
# zed_interfaces in the 4.2.x cycle).
#
# TOPIC RENAME TRAP (wrapper >= 5.1.0): image topics are
#   /zed/zed_node/rgb/color/rect/image   (NOT the pre-5.1 rgb/image_rect_color)
#   /zed/zed_node/depth/depth_registered
# and topics are lazy (published only while subscribed). Left/right topics
# are OFF by default; rgb (== left sensor) is on. See docs/AV_STACK.md.
#
# Prerequisites: ZED SDK installed (/usr/local/zed), the ZED X daemons
# running (scripts/install_zedx_daemons.sh), ROS 2 Humble, nvidia-jetpack.
# JP6 pitfall: zed-config.cmake needs CUDA_TOOLKIT_ROOT_DIR   supplied by
# the nvidia-jetpack-dev meta package.
#
# Idempotent: re-runs skip completed stages.
# =============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/config.sh"
. "$HERE/lib/log.sh"
. "$HERE/lib/verify.sh"
. "$HERE/lib/checks.sh"

PHASE=zed_ros2_wrapper
WS=/opt/zed_ros_ws
WRAPPER_TAG="${ZED_WRAPPER_TAG:-v5.3.1}"
RGB_TOPIC=/zed/zed_node/rgb/color/rect/image

if [ "$EUID" -ne 0 ]; then log::fail "must run as root"; fi

log::section "ZED ROS 2 wrapper ($WRAPPER_TAG) build"

# --- Step 1: dependencies ---------------------------------------------------
pre_deps()  { check::command_exists apt-get; }
exec_deps() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y -o DPkg::Lock::Timeout=600 \
        ros-humble-zed-msgs ros-humble-vision-msgs ros-humble-cv-bridge \
        ros-humble-point-cloud-transport ros-humble-image-transport \
        nvidia-jetpack-dev python3-rosdep python3-colcon-common-extensions git
}
post_deps() {
    check::package_installed ros-humble-zed-msgs
    check::package_installed nvidia-jetpack-dev
}
step::run "Install wrapper build deps" pre_deps exec_deps post_deps

# --- Step 2: workspace + clone ----------------------------------------------
pre_clone()  { return 0; }
exec_clone() {
    mkdir -p "$WS/src"
    if [ ! -d "$WS/src/zed-ros2-wrapper" ]; then
        git clone --depth 1 -b "$WRAPPER_TAG" \
            https://github.com/stereolabs/zed-ros2-wrapper.git \
            "$WS/src/zed-ros2-wrapper"
    fi
}
post_clone() { check::dir_nonempty "$WS/src/zed-ros2-wrapper/zed_wrapper"; }
step::run "Clone zed-ros2-wrapper $WRAPPER_TAG" pre_clone exec_clone post_clone

# --- Step 3: rosdep ----------------------------------------------------------
pre_rosdep()  { check::command_exists rosdep; }
exec_rosdep() {
    [ -f /etc/ros/rosdep/sources.list.d/20-default.list ] || rosdep init
    # rosdep update refuses to run as root for cache-ownership reasons unless
    # told otherwise; the cache landing in root's HOME is fine on this box.
    rosdep update --rosdistro humble 2>&1 | tail -1 || true
    set +u
    . /opt/ros/humble/setup.bash
    set -u
    rosdep install --from-paths "$WS/src" --ignore-src -r -y \
        --rosdistro humble 2>&1 | tail -3 || true
}
post_rosdep() { return 0; }
STRICT=0 step::run "rosdep install" pre_rosdep exec_rosdep post_rosdep

# --- Step 4: colcon build ------------------------------------------------------
pre_build()  { check::dir_exists "$WS/src/zed-ros2-wrapper"; }
exec_build() {
    cd "$WS"
    set +u
    . /opt/ros/humble/setup.bash
    set -u
    # ZED SDK cmake needs CUDA on PATH; JetPack does not export it.
    export PATH=/usr/local/cuda/bin:$PATH
    colcon build --symlink-install \
        --cmake-args=-DCMAKE_BUILD_TYPE=Release \
        --packages-skip zed_debug \
        --parallel-workers "$(nproc)"
}
post_build() {
    check::file_exists "$WS/install/local_setup.bash"
    [ -d "$WS/install/zed_wrapper" ] || { log::warn "zed_wrapper pkg missing"; return 1; }
}
step::run "colcon build (10-20 min)" pre_build exec_build post_build

# --- Step 5: environment wiring -----------------------------------------------
pre_env()  { check::file_exists /etc/profile.d/jetson-av-stack.sh; }
exec_env() {
    if ! grep -q 'zed_ros_ws' /etc/profile.d/jetson-av-stack.sh; then
        sed -i "/isaac_ros_ws/a [ -f $WS/install/local_setup.bash ] && . $WS/install/local_setup.bash" \
            /etc/profile.d/jetson-av-stack.sh
    fi
    # axelera.app lives in the voyager-sdk checkout, not the wheels   the
    # detect node (and any shell) needs it importable.
    if ! grep -q 'AXELERA_FRAMEWORK' /etc/profile.d/jetson-av-stack.sh; then
        cat >> /etc/profile.d/jetson-av-stack.sh <<'EOF'
export AXELERA_FRAMEWORK=/home/j/voyager-sdk
export PYTHONPATH=$AXELERA_FRAMEWORK${PYTHONPATH:+:$PYTHONPATH}
EOF
    fi
}
post_env() {
    grep -q 'zed_ros_ws' /etc/profile.d/jetson-av-stack.sh \
        && grep -q 'AXELERA_FRAMEWORK' /etc/profile.d/jetson-av-stack.sh
}
step::run "Wire workspace + AXELERA_FRAMEWORK into stack env" pre_env exec_env post_env

# --- Step 6: launch smoke test --------------------------------------------------
pre_smoke()  { lsmod | grep -q '^sl_zedx' || { log::warn "sl_zedx not loaded"; return 1; }; }
exec_smoke() {
    set +u
    . /opt/ros/humble/setup.bash
    . "$WS/install/local_setup.bash"
    set -u
    timeout 40 ros2 launch zed_wrapper zed_camera.launch.py camera_model:=zedx &
    local pid=$!
    # pos-tracking init + gravity alignment depress the rate for ~20 s;
    # measure steady-state, not warmup (18.5 Hz at t=18 vs ~30 Hz settled).
    sleep 30
    local hz
    hz="$(timeout 6 ros2 topic hz --window 30 "$RGB_TOPIC" 2>/dev/null \
          | awk '/average rate/{print $3; exit}')"
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    log::info "rgb rect image rate: ${hz:-none} Hz"
    [ -n "$hz" ] && awk -v h="$hz" 'BEGIN{exit !(h>=20)}'
}
post_smoke() { return 0; }
STRICT=0 step::run "Launch smoke test (25 s)" pre_smoke exec_smoke post_smoke

log::section "ZED ROS 2 wrapper install complete"
step::summary
