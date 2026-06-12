#!/bin/bash
# =============================================================================
# scripts/install_av_phase5.sh   Phase 5 (AV application stack) installer
# =============================================================================
# Orchestrates with pre/post checks per step:
#   1. build_opencv_cuda.sh         → OpenCV with CUDA + cuDNN + GStreamer
#   2. verify_opengl_cuda.sh        → confirm full CUDA/OpenGL stack works
#   3. install_av_stack.sh          → ROS 2 Humble, Isaac ROS, Nav2, MAVROS
#   3b. install_zed_ros2_wrapper.sh → zed_wrapper colcon ws (/opt/zed_ros_ws)
#   3c. install_mission_inference.sh → detect_metis.py + models + SLAM wiring
#   4. install jetson-av-mission.service for boot-time mission launch
# =============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/config.sh"
. "$HERE/lib/log.sh"
. "$HERE/lib/verify.sh"
. "$HERE/lib/checks.sh"

PHASE=phase5

if [ "$EUID" -ne 0 ]; then log::fail "must run as root"; fi

log::section "Phase 5: AV Application Stack + CUDA Userspace"

# --- Step 1: OpenCV with CUDA -------------------------------------------
pre_cv() { check::file_exists "$HERE/build_opencv_cuda.sh"; }
exec_cv() { bash "$HERE/build_opencv_cuda.sh"; }
post_cv() {
    /opt/av-env/bin/python -c \
        "import cv2; assert cv2.cuda.getCudaEnabledDeviceCount() > 0" 2>/dev/null \
        || { log::warn "OpenCV-CUDA not active; will warn-continue"; return 1; }
}
STRICT=0 step::run "Build/install OpenCV-CUDA" pre_cv exec_cv post_cv

# --- Step 2: verify OpenGL/CUDA ----------------------------------------
pre_vg() { check::file_exists "$HERE/verify_opengl_cuda.sh"; }
exec_vg() { bash "$HERE/verify_opengl_cuda.sh"; }
post_vg() { return 0; }
STRICT=0 step::run "Verify CUDA/OpenGL stack" pre_vg exec_vg post_vg

# --- Step 3: ROS 2 / Isaac ROS / Nav2 / MAVROS -------------------------
pre_av() { check::file_exists "$HERE/install_av_stack.sh"; }
exec_av() { bash "$HERE/install_av_stack.sh"; }
post_av() {
    [ -d /opt/ros/humble ] || return 1
    return 0
}
STRICT=0 step::run "Install ROS2/Isaac/Nav2/MAVROS" pre_av exec_av post_av

# --- Step 3b: ZED ROS 2 wrapper (mission camera node) -------------------
pre_zw() { check::file_exists "$HERE/install_zed_ros2_wrapper.sh"; }
exec_zw() { bash "$HERE/install_zed_ros2_wrapper.sh"; }
post_zw() { [ -d /opt/zed_ros_ws/install/zed_wrapper ] || return 1; }
STRICT=0 step::run "Build ZED ROS 2 wrapper" pre_zw exec_zw post_zw

# --- Step 3c: mission inference (detect node + models + SLAM wiring) ----
pre_mi() { check::file_exists "$HERE/install_mission_inference.sh"; }
exec_mi() { bash "$HERE/install_mission_inference.sh"; }
post_mi() { check::file_exists /opt/jetson-av/detect_metis.py; }
STRICT=0 step::run "Install mission inference" pre_mi exec_mi post_mi

# --- Step 4: jetson-av-mission.service ---------------------------------
pre_svc() { check::file_exists "$HERE/launch_av_mission.sh"; }
exec_svc() {
    install -m 0755 "$HERE/launch_av_mission.sh" /usr/local/bin/launch_av_mission.sh
    mkdir -p /etc/jetson-av
    if [ ! -f /etc/jetson-av/mission.conf ]; then
        cat > /etc/jetson-av/mission.conf <<'EOF'
# AV mission stack toggles. 1=enable, 0=disable.
ENABLE_CAMERA=1
ENABLE_INFERENCE=1
ENABLE_SLAM=1
ENABLE_NVBLOX=1
ENABLE_NAV2=1
ENABLE_MAVROS=1
# Flight controller URL (UART or USB-serial). Common bridges:
#   /dev/ttyTHS1:921600   (Pixhawk TELEM2 → Jetson UART1)
#   /dev/ttyACM0:115200   (USB-serial via Pixhawk)
# /dev/ttyTHS0 is the debug console   do NOT use it for MAVLink
# (opens successfully, receives nothing). See versions.env FCU_TTY_DEFAULT.
FCU_URL=/dev/ttyTHS1:921600
# Metis detect node (detect_metis.py): network name under DETECT_BUILD_ROOT.
DETECT_NETWORK=yolov5s-v7-coco
DETECT_BUILD_ROOT=/opt/jetson-av/models
DETECT_DEBUG_IMAGE=0
EOF
    fi
    cat > /etc/systemd/system/jetson-av-mission.service <<'EOF'
[Unit]
Description=Jetson AV mission stack (camera → inference → SLAM → Nav2 → MAVROS)
Documentation=file:///opt/docs/AV_STACK.md
After=network.target multi-user.target jetson-rt-tune.service jetson-blackbox.service
Wants=network.target jetson-rt-tune.service jetson-blackbox.service

[Service]
Type=simple
ExecStart=/usr/local/bin/launch_av_mission.sh
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10
TimeoutStopSec=30
KillMode=mixed

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable jetson-av-mission.service
    # Don't auto-start during install; operator should review config first.
    log::info "Service installed but NOT started   review /etc/jetson-av/mission.conf"
    log::info "To start now:   systemctl start jetson-av-mission.service"
    log::info "To dry-run:     /usr/local/bin/launch_av_mission.sh --dry-run"
}
post_svc() {
    check::file_exists /etc/systemd/system/jetson-av-mission.service
    check::file_exists /etc/jetson-av/mission.conf
    check::file_exists /usr/local/bin/launch_av_mission.sh
}
step::run "Install jetson-av-mission.service" pre_svc exec_svc post_svc

log::section "Phase 5 Install Complete"
echo
echo "Next steps:"
echo "  1. Edit /etc/jetson-av/mission.conf for your FCU/sensors"
echo "  2. Place compiled models under /opt/jetson-av/models/"
echo "  3. Dry-run:   sudo /usr/local/bin/launch_av_mission.sh --dry-run"
echo "  4. Start:     sudo systemctl start jetson-av-mission.service"
echo
step::summary
