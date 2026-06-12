#!/usr/bin/env python3
# ZED X depth smoke test: proves the SDK's CUDA depth pipeline.
# Run: sg zed -c '/opt/av-env/bin/python examples/zedx_depth.py'
# Expected: "open: SUCCESS", "DEPTH MAP OK: 1920 x 1200 | center px: <mm>".
# Note: SDK default units are MILLIMETERS.
import math

import pyzed.sl as sl

cam = sl.Camera()
init = sl.InitParameters()
init.depth_mode = sl.DEPTH_MODE.PERFORMANCE
err = cam.open(init)
print("open:", err)
if err == sl.ERROR_CODE.SUCCESS:
    if cam.grab(sl.RuntimeParameters()) == sl.ERROR_CODE.SUCCESS:
        d = sl.Mat()
        cam.retrieve_measure(d, sl.MEASURE.DEPTH)
        v = d.get_value(960, 600)[1]
        label = "%.0fmm" % v if v and not math.isnan(v) else "no-texture"
        print("DEPTH MAP OK:", d.get_width(), "x", d.get_height(), "| center px:", label)
    cam.close()
