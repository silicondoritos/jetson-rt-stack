#!/usr/bin/env python3
# Minimal ZED X smoke test: open, identify, grab one frame.
# Run: sg zed -c '/opt/av-env/bin/python examples/zedx_grab.py'
# Expected: "open: SUCCESS", model + serial, "FRAME CAPTURED: 1920 x 1200".
import pyzed.sl as sl

cam = sl.Camera()
init = sl.InitParameters()
init.depth_mode = sl.DEPTH_MODE.NONE
err = cam.open(init)
print("open:", err)
if err == sl.ERROR_CODE.SUCCESS:
    info = cam.get_camera_information()
    print("model:", info.camera_model, "| serial:", info.serial_number)
    if cam.grab(sl.RuntimeParameters()) == sl.ERROR_CODE.SUCCESS:
        m = sl.Mat()
        cam.retrieve_image(m, sl.VIEW.LEFT)
        print("FRAME CAPTURED:", m.get_width(), "x", m.get_height())
    cam.close()
