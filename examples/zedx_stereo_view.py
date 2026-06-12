#!/usr/bin/env python3
# Live ZED X stereo viewer: left | right side by side with FPS overlay.
# Run: DISPLAY=:0 sg zed -c '/opt/av-env/bin/python examples/zedx_stereo_view.py'
# Expected: a window with both eyes at ~30 FPS (HD1200@30); q/ESC closes.
# Saves a snapshot to ~/Desktop/zedx_stereo_snapshot.png on exit.
import time

import cv2
import pyzed.sl as sl

cam = sl.Camera()
init = sl.InitParameters()
init.depth_mode = sl.DEPTH_MODE.NONE
init.camera_resolution = sl.RESOLUTION.HD1200
err = cam.open(init)
print("open:", err)
assert err == sl.ERROR_CODE.SUCCESS

sbs = sl.Mat()
rt = sl.RuntimeParameters()
t0, frames = time.time(), 0
cv2.namedWindow("ZED X - LEFT | RIGHT", cv2.WINDOW_NORMAL)
cv2.resizeWindow("ZED X - LEFT | RIGHT", 1820, 580)
while time.time() - t0 < 60:
    if cam.grab(rt) != sl.ERROR_CODE.SUCCESS:
        continue
    frames += 1
    cam.retrieve_image(sbs, sl.VIEW.SIDE_BY_SIDE)
    img = cv2.resize(cv2.cvtColor(sbs.get_data(), cv2.COLOR_BGRA2BGR), (1820, 570))
    h, w = img.shape[:2]
    cv2.line(img, (w // 2, 0), (w // 2, h), (255, 255, 255), 2)
    fps = frames / (time.time() - t0)
    cv2.putText(img, f"{fps:.1f} FPS  (q/ESC to close)", (16, h - 16),
                cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 255, 255), 2)
    cv2.imshow("ZED X - LEFT | RIGHT", img)
    if cv2.waitKey(1) & 0xFF in (27, ord('q')):
        break
cv2.imwrite("/home/j/Desktop/zedx_stereo_snapshot.png", img)
print(f"frames: {frames}, avg fps: {frames / (time.time() - t0):.1f}")
cam.close()
cv2.destroyAllWindows()
