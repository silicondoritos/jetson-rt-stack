#!/usr/bin/env python3
# =============================================================================
# scripts/demo_zedx_metis.py   live ZED X → Metis inference demo
# =============================================================================
# Proves the camera → NPU pipeline end to end: pyzed grabs HD1200 frames from
# the ZED X (GMSL2 → MAX9296 → in-tree RT driver), a generator feeds them to
# the Voyager application framework, and the Metis runs the detector.
#
# Prerequisites (all verified live 2026-06-11 on the reference device):
#   - ZED X opening via SDK (scripts/install_zedx_daemons.sh)
#   - Voyager app deps in /opt/av-env (requirements.application.txt minus
#     opencv-python/pyopencl   see docs/AV_STACK.md)
#   - the model deployed once (first run of:
#       ./inference.py yolov5s-v7-coco media/h264/traffic1_1080p.mp4 )
#
# Measured end-to-end baselines (2026-06-11, reference device):
#   HD1200@30 -> 29.6 FPS (camera-limited)
#   HD1200@60 -> 37.3 FPS (python copy chain is the limiter)   <- default
#   SVGA@120  -> 53.3 FPS (NPU pipeline)
# Switch modes via camera_resolution / camera_fps below.
#
# Run (from the voyager-sdk checkout, with the user in the `zed` group):
#   cd ~/voyager-sdk
#   DISPLAY=:0 PYTHONPATH=$PWD \
#     sg zed -c "/opt/av-env/bin/python \
#       ~/Documents/jetson-rt-stack/scripts/demo_zedx_metis.py"
# =============================================================================
import time

import cv2
import pyzed.sl as sl

from axelera.app import display
from axelera.app.stream import create_inference_stream

NETWORK = "yolov5s-v7-coco"
SECONDS = 60


def zedx_frames():
    cam = sl.Camera()
    init = sl.InitParameters()
    init.camera_resolution = sl.RESOLUTION.HD1200
    init.camera_fps = 60  # HD1200 supports 60 FPS; default was 30
    init.depth_mode = sl.DEPTH_MODE.NONE  # detector only; depth costs FPS
    err = cam.open(init)
    if err != sl.ERROR_CODE.SUCCESS:
        raise RuntimeError(f"ZED X open failed: {err}   run install_zedx_daemons.sh?")
    print(f"ZED X open: S/N {cam.get_camera_information().serial_number}")
    img = sl.Mat()
    rt = sl.RuntimeParameters()
    t0 = time.time()
    try:
        while time.time() - t0 < SECONDS:
            if cam.grab(rt) != sl.ERROR_CODE.SUCCESS:
                continue
            cam.retrieve_image(img, sl.VIEW.LEFT)
            yield cv2.cvtColor(img.get_data(), cv2.COLOR_BGRA2BGR)
    finally:
        cam.close()


# aipu_cores=4 matches the artifact inference.py deploys by default   without
# it the app API defaults to 1 core and triggers a full ~17 min recompile.
stream = create_inference_stream(network=NETWORK, sources=[zedx_frames()], aipu_cores=4)


def main(window, stream):
    start = time.time()
    for frame_result in stream:
        window.show(frame_result.image, frame_result.meta, frame_result.stream_id)
        if window.is_closed:
            break
    secs = time.time() - start
    if secs > 0:
        print(f"{stream.frames_executed} frames in {secs:.1f}s "
              f"(end-to-end {stream.frames_executed / secs:.1f} FPS)")


with display.App(renderer=True) as app:
    wnd = app.create_window("ZED X -> Metis (live)", (1280, 800))
    app.start_thread(main, (wnd, stream), name="InferenceThread")
    app.run()
stream.stop()
