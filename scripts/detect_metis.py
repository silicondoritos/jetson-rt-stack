#!/usr/bin/env python3
# =============================================================================
# scripts/detect_metis.py   mission detect node: ZED X frames → Metis → ROS 2
# =============================================================================
# The mission graph node spawned by launch_av_mission.sh on core 1:
#   /opt/av-env/bin/python /opt/jetson-av/detect_metis.py
#
# Subscribes : /zed/zed_node/rgb/color/rect/image  (zed-ros2-wrapper >= 5.1
#              topic name; bgra8, lazy-published, best_effort)
# Publishes  : /detections  vision_msgs/Detection2DArray  (~camera Hz,
#              best_effort/keep_last/1 per docs/AV_STACK.md QoS table)
#
# The Metis runs the model via the Voyager app framework: a latest-frame-wins
# queue bridges the ROS subscription into a generator source for
# create_inference_stream()   the same pattern verified at 29-53 FPS by
# scripts/demo_zedx_metis.py. axelera.app lives in the voyager-sdk checkout
# (AXELERA_FRAMEWORK), not the wheels; /etc/profile.d/jetson-av-stack.sh
# exports it (installed by install_zed_ros2_wrapper.sh).
#
# Config (KEY=VALUE, parsed from /etc/jetson-av/mission.conf):
#   DETECT_NETWORK=yolov5s-v7-coco   model name under the build root
#   DETECT_BUILD_ROOT=/opt/jetson-av/models
#   DETECT_DEBUG_IMAGE=0             1 = also publish annotated /detections/image
# =============================================================================
import collections
import os
import pathlib
import queue
import signal
import sys
import threading

# axelera.app resolution: prefer AXELERA_FRAMEWORK, fall back to the known
# checkout so a bare `python detect_metis.py` works too.
_FRAMEWORK = os.environ.get("AXELERA_FRAMEWORK", "/home/j/voyager-sdk")
if _FRAMEWORK not in sys.path:
    sys.path.insert(0, _FRAMEWORK)

import numpy as np
import rclpy
from rclpy.node import Node
from rclpy.qos import QoSHistoryPolicy, QoSProfile, QoSReliabilityPolicy
from sensor_msgs.msg import Image
from vision_msgs.msg import (
    Detection2D,
    Detection2DArray,
    ObjectHypothesisWithPose,
)

from axelera.app.stream import create_inference_stream

CONF_PATH = "/etc/jetson-av/mission.conf"


def read_conf(path=CONF_PATH):
    conf = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    conf[k.strip()] = v.strip()
    except OSError:
        pass
    return conf


class DetectMetis(Node):
    def __init__(self):
        super().__init__("detect_metis")
        conf = read_conf()
        self.network = conf.get("DETECT_NETWORK", "yolov5s-v7-coco")
        self.build_root = conf.get("DETECT_BUILD_ROOT", "/opt/jetson-av/models")
        self.debug_image = conf.get("DETECT_DEBUG_IMAGE", "0") == "1"

        qos = QoSProfile(
            reliability=QoSReliabilityPolicy.BEST_EFFORT,
            history=QoSHistoryPolicy.KEEP_LAST,
            depth=1,
        )
        # Latest-frame-wins: the NPU pulls at its own rate; stale frames drop.
        self._frames = queue.Queue(maxsize=1)
        self._headers = collections.deque()
        self._stop = threading.Event()

        self.sub = self.create_subscription(
            Image, "/zed/zed_node/rgb/color/rect/image", self.on_image, qos
        )
        self.pub = self.create_publisher(Detection2DArray, "/detections", qos)
        self.pub_img = (
            self.create_publisher(Image, "/detections/image", qos)
            if self.debug_image
            else None
        )
        self.get_logger().info(
            f"detect_metis: network={self.network} build_root={self.build_root}"
        )

    def on_image(self, msg):
        # bgra8 from the wrapper; the framework wants 3-channel BGR.
        img = np.frombuffer(msg.data, dtype=np.uint8).reshape(
            msg.height, msg.width, -1
        )
        if img.shape[2] == 4:
            img = np.ascontiguousarray(img[:, :, :3])
        try:
            self._frames.put_nowait((msg.header, img))
        except queue.Full:
            try:
                self._frames.get_nowait()
            except queue.Empty:
                pass
            try:
                self._frames.put_nowait((msg.header, img))
            except queue.Full:
                pass

    def frame_source(self):
        while not self._stop.is_set():
            try:
                header, img = self._frames.get(timeout=0.5)
            except queue.Empty:
                continue
            self._headers.append(header)
            yield img

    def publish_result(self, frame_result):
        header = self._headers.popleft() if self._headers else None
        out = Detection2DArray()
        if header is not None:
            out.header = header
        for d in frame_result.detections:
            det = Detection2D()
            x1, y1, x2, y2 = (float(v) for v in d.box)
            det.bbox.center.position.x = (x1 + x2) / 2.0
            det.bbox.center.position.y = (y1 + y2) / 2.0
            det.bbox.size_x = x2 - x1
            det.bbox.size_y = y2 - y1
            hyp = ObjectHypothesisWithPose()
            hyp.hypothesis.class_id = str(int(d.class_id))
            hyp.hypothesis.score = float(d.score)
            det.results.append(hyp)
            out.detections.append(det)
        self.pub.publish(out)
        if self.pub_img is not None and frame_result.image is not None:
            arr = frame_result.image.asarray()
            msg = Image()
            if header is not None:
                msg.header = header
            msg.height, msg.width = arr.shape[:2]
            msg.encoding = "bgr8" if arr.shape[2] == 3 else "bgra8"
            msg.step = arr.shape[1] * arr.shape[2]
            msg.data = arr.tobytes()
            self.pub_img.publish(msg)

    def run_inference(self):
        # Outer loop: the framework raises "Timeout for querying an inference"
        # when the camera restarts and the generator starves (observed live on
        # the first mission run). Rebuild the stream and keep serving instead
        # of dying   systemd Restart=always would recover anyway, but a model
        # reload costs ~15 s we can skip.
        while not self._stop.is_set():
            stream = create_inference_stream(
                network=self.network,
                sources=[self.frame_source()],
                build_root=pathlib.Path(self.build_root),
                aipu_cores=4,
            )
            self._stream = stream
            try:
                for frame_result in stream:
                    if self._stop.is_set():
                        break
                    self.publish_result(frame_result)
            except RuntimeError as e:
                self.get_logger().warning(f"stream restart after: {e}")
            finally:
                stream.stop()
            self._headers.clear()

    def shutdown(self):
        self._stop.set()


def main():
    rclpy.init()
    node = DetectMetis()
    worker = threading.Thread(
        target=node.run_inference, name="MetisInference", daemon=True
    )
    worker.start()

    def on_term(_sig, _frm):
        node.shutdown()
        rclpy.try_shutdown()

    signal.signal(signal.SIGTERM, on_term)
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.shutdown()
        worker.join(timeout=10)
        node.destroy_node()
        rclpy.try_shutdown()


if __name__ == "__main__":
    main()
