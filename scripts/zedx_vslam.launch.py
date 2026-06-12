#!/usr/bin/env python3
# =============================================================================
# scripts/zedx_vslam.launch.py   cuVSLAM wired to the ZED X wrapper topics
# =============================================================================
# The stock isaac_ros_visual_slam.launch.py declares NO remappings: the node
# listens on visual_slam/image_0|1 + camera_info_0|1 and expects a rectified
# stereo pair. The zed-ros2-wrapper (>= 5.1 topic names) publishes left/right
# rect color at /zed/zed_node/{left,right}/color/rect/image   but only when
# video.publish_left_right is enabled (/etc/jetson-av/zedx_overrides.yaml,
# staged by install_mission_inference.sh; the launcher passes
# ros_params_override_path to the camera node).
#
# Spawned by launch_av_mission.sh as:
#   ros2 launch /opt/jetson-av/zedx_vslam.launch.py
# =============================================================================
import launch
from launch_ros.actions import ComposableNodeContainer
from launch_ros.descriptions import ComposableNode

ZED = '/zed/zed_node'


def generate_launch_description():
    visual_slam_node = ComposableNode(
        name='visual_slam_node',
        package='isaac_ros_visual_slam',
        plugin='nvidia::isaac_ros::visual_slam::VisualSlamNode',
        parameters=[{
            'num_cameras': 2,
            'rectified_images': True,
            'enable_imu_fusion': False,  # flip on after FIELD_CONFIRM of imu noise params
            'base_frame': 'zed_camera_link',
        }],
        remappings=[
            ('visual_slam/image_0', f'{ZED}/left/color/rect/image'),
            ('visual_slam/camera_info_0', f'{ZED}/left/color/rect/camera_info'),
            ('visual_slam/image_1', f'{ZED}/right/color/rect/image'),
            ('visual_slam/camera_info_1', f'{ZED}/right/color/rect/camera_info'),
            ('visual_slam/imu', f'{ZED}/imu/data'),
        ],
    )

    container = ComposableNodeContainer(
        name='visual_slam_launch_container',
        namespace='',
        package='rclcpp_components',
        executable='component_container',
        composable_node_descriptions=[visual_slam_node],
        output='screen',
    )

    return launch.LaunchDescription([container])
