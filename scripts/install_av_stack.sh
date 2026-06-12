#!/bin/bash
# =============================================================================
# scripts/install_av_stack.sh   install ROS 2 + Isaac ROS + Nav2 + MAVROS
# =============================================================================
# Runs on the target after first-boot. Each step is pre/post-verified; debug
# via DEBUG=1; logs land in /var/log/jetson-av/.
#
# Order matters:
#   1. ROS 2 Humble (universe   apt deb from packages.ros.org)
#   2. Isaac ROS bringup (NITROS, image_pipeline, visual_slam, nvblox,
#      object_detection)
#   3. Nav2 (navigation2, nav2_bringup, hybrid A* planner)
#   4. MAVROS + pymavlink
#
# Idempotent. Re-runs are safe; each "install" step skips if already done.
# =============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/config.sh"
. "$HERE/lib/log.sh"
. "$HERE/lib/verify.sh"
. "$HERE/lib/checks.sh"

PHASE=av_stack
ROS_DISTRO=humble
LOG_DIR=/var/log/jetson-av
mkdir -p "$LOG_DIR"

if [ "$EUID" -ne 0 ]; then log::fail "must run as root"; fi

log::section "Phase 5: AV Application Stack"

# --- Step 1: ROS 2 Humble repo + base ----------------------------------
pre_ros() { check::command_exists curl; }
exec_ros() {
    if ! grep -rq packages.ros.org /etc/apt/sources.list.d/ 2>/dev/null; then
        apt-get update -qq
        apt-get install -y curl gnupg2 lsb-release software-properties-common
        curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
            -o /usr/share/keyrings/ros-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu $(lsb_release -cs) main" \
            > /etc/apt/sources.list.d/ros2.list
    fi
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        ros-${ROS_DISTRO}-ros-base \
        ros-${ROS_DISTRO}-ros2-control \
        ros-${ROS_DISTRO}-rosbag2-storage-mcap \
        python3-rosdep python3-colcon-common-extensions \
        python3-pip
    if [ ! -f /etc/ros/rosdep/sources.list.d/20-default.list ]; then
        rosdep init || true
    fi
    sudo -u "${TARGET_USER:-j}" rosdep update || true
}
post_ros() {
    check::dir_exists "/opt/ros/$ROS_DISTRO"
    check::file_exists "/opt/ros/$ROS_DISTRO/setup.bash"
}
step::run "Install ROS 2 $ROS_DISTRO base" pre_ros exec_ros post_ros

# Ensure ROS env is sourced for downstream apt-installed nodes.
# ROS setup scripts reference unbound variables (AMENT_TRACE_SETUP_FILES),
# and under `set -u` an expansion error aborts the script even behind
# `|| true` (observed live 2026-06-10)   so drop -u around the source.
# shellcheck disable=SC1090
set +u
. "/opt/ros/$ROS_DISTRO/setup.bash" || true
set -u

# --- Step 2: Isaac ROS (NITROS, image_pipeline, visual_slam, nvblox) -----
pre_isaac() { check::dir_exists "/opt/ros/$ROS_DISTRO"; }
exec_isaac() {
    # Add NVIDIA's Isaac ROS apt repository (buildfarm). Without this the
    # apt fast-path below can never resolve and every install falls into the
    # slow source build (observed live 2026-06-10   the comment promised the
    # repo but the code never added it).
    if [ ! -f /etc/apt/sources.list.d/isaac-ros.list ]; then
        curl -fsSL https://isaac.download.nvidia.com/isaac-ros/repos.key \
            | gpg --dearmor -o /usr/share/keyrings/isaac-ros.gpg
        echo "deb [signed-by=/usr/share/keyrings/isaac-ros.gpg] https://isaac.download.nvidia.com/isaac-ros/release-3 jammy release-3.0" \
            > /etc/apt/sources.list.d/isaac-ros.list
        apt-get update -o Dir::Etc::sourcelist=sources.list.d/isaac-ros.list \
                       -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0 \
            || apt-get update
    fi
    if true; then
        # Try apt first (fast, vermagic-irrelevant userspace), fall back to
        # a local rosdep + colcon source build.
        # detectnet, not object-detection: the object-detection meta-package
        # does not exist in the 3.x apt repo, and ONE unknown name fails the
        # WHOLE transaction (observed live 2026-06-10   and the 2>/dev/null
        # that used to be here hid the error, sending every install down the
        # slow source-build path).
        apt-get install -y \
            ros-${ROS_DISTRO}-isaac-ros-nitros \
            ros-${ROS_DISTRO}-isaac-ros-image-pipeline \
            ros-${ROS_DISTRO}-isaac-ros-visual-slam \
            ros-${ROS_DISTRO}-isaac-ros-nvblox \
            ros-${ROS_DISTRO}-isaac-ros-detectnet \
            || {
            log::warn "Isaac ROS apt packages not available   clone+colcon source build"
            mkdir -p /opt/isaac_ros_ws/src
            cd /opt/isaac_ros_ws/src
            for repo in isaac_ros_common isaac_ros_nitros isaac_ros_image_pipeline \
                        isaac_ros_visual_slam isaac_ros_nvblox isaac_ros_object_detection; do
                if [ ! -d "$repo" ]; then
                    git clone --depth 1 "https://github.com/NVIDIA-ISAAC-ROS/$repo.git" || true
                fi
            done
            cd /opt/isaac_ros_ws
            rosdep install --from-paths src --ignore-src -r -y 2>/dev/null || true
            colcon build --symlink-install --executor sequential || true
        }
    fi
}
post_isaac() {
    # The mission graph specifically needs visual_slam + nvblox   checking
    # for ANY isaac_ros_* dir passes on a half-finished colcon build whose
    # only artifact is isaac_ros_common (observed live 2026-06-10).
    local pkg missing=0
    for pkg in isaac_ros_visual_slam isaac_ros_nvblox; do
        if find "/opt/ros/$ROS_DISTRO/share" -maxdepth 1 -type d -name "$pkg" 2>/dev/null | grep -q . \
           || find /opt/isaac_ros_ws/install -maxdepth 2 -name "$pkg" 2>/dev/null | grep -q .; then
            continue
        fi
        log::warn "$pkg missing"
        missing=1
    done
    [ "$missing" = "0" ] || { log::warn "Isaac ROS install incomplete   see logs"; return 1; }
}
STRICT=0 step::run "Install Isaac ROS bringup" pre_isaac exec_isaac post_isaac

# --- Step 3: Nav2 -----------------------------------------------------
pre_nav2() { check::dir_exists "/opt/ros/$ROS_DISTRO"; }
exec_nav2() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        ros-${ROS_DISTRO}-navigation2 \
        ros-${ROS_DISTRO}-nav2-bringup \
        ros-${ROS_DISTRO}-slam-toolbox
}
post_nav2() {
    [ -d "/opt/ros/$ROS_DISTRO/share/nav2_bringup" ] \
        || { log::warn "nav2_bringup missing"; return 1; }
}
STRICT=0 step::run "Install Nav2" pre_nav2 exec_nav2 post_nav2

# --- Step 4: MAVROS + pymavlink --------------------------------------
pre_mav() { check::dir_exists "/opt/ros/$ROS_DISTRO"; }
exec_mav() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        ros-${ROS_DISTRO}-mavros \
        ros-${ROS_DISTRO}-mavros-extras
    # GeographicLib datasets that MAVROS needs for some message types.
    # Canonical install method per mavros/ros2 README is `ros2 run`, which
    # finds the script via the package install layout (the hardcoded
    # /opt/ros/$ROS_DISTRO/lib/mavros/ path is NOT portable).
    sudo -u "${TARGET_USER:-j}" ros2 run mavros install_geographiclib_datasets.sh \
        2>/dev/null || true
    /opt/av-env/bin/pip install pymavlink 2>/dev/null || pip3 install pymavlink || true
}
post_mav() {
    [ -d "/opt/ros/$ROS_DISTRO/share/mavros" ] \
        || { log::warn "mavros missing"; return 1; }
}
STRICT=0 step::run "Install MAVROS" pre_mav exec_mav post_mav

# --- Step 5: bake stack-source environment -------------------------------
pre_env() { return 0; }
exec_env() {
    cat > /etc/profile.d/jetson-av-stack.sh <<EOF
# Auto-source ROS + AV venv + (if present) Isaac ROS workspace.
[ -f /opt/ros/$ROS_DISTRO/setup.bash ] && . /opt/ros/$ROS_DISTRO/setup.bash
[ -f /opt/isaac_ros_ws/install/setup.bash ] && . /opt/isaac_ros_ws/install/setup.bash
[ -f /opt/av-env/bin/activate ] && . /opt/av-env/bin/activate
export RMW_IMPLEMENTATION=rmw_fastrtps_cpp
EOF
    chmod 644 /etc/profile.d/jetson-av-stack.sh
}
post_env() { check::file_exists /etc/profile.d/jetson-av-stack.sh; }
step::run "Stack environment auto-source" pre_env exec_env post_env

log::section "AV Stack Install Complete"
echo
echo "Source the stack in any new shell with:"
echo "  source /etc/profile.d/jetson-av-stack.sh"
echo
echo "Then verify with:"
echo "  ros2 pkg list | grep -E 'isaac_ros|nav2|mavros'"
echo "  /home/j/phase5/launch_av_mission.sh --dry-run"
echo
step::summary
