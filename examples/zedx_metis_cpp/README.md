# zedx_metis_cpp   ZED X → Axelera Metis, pure C++

Two samples that drive the ZED X into the Metis NPU via `libaxruntime` directly
(no Voyager app framework):

- **`zedx_metis_infer`**   lean detector (grab → letterbox+quantize → Metis →
  decode+NMS → draw). Max detection throughput.
- **`zedx_metis_fusion`**   full sensor fusion: detection (Metis) + stereo depth
  + IMU-fused pose + skeleton tracking + per-object distance/world-position +
  IoU tracking with velocity/TTC, in a 3-stage pipeline using the GPU, NPU, and
  CPU concurrently.

Both auto-detect YOLOv5/YOLOv8 heads and the deployed core-count build dir.

## Build & run

```bash
cmake -B build && cmake --build build          # CUDA + libaxldev

# all features, fast & smooth (runs until Esc):
DISPLAY=:0 sg zed -c './build/zedx_metis_fusion --model yolov8s-coco --depth-every 3'

# lean detector, no depth:
DISPLAY=:0 sg zed -c './build/zedx_metis_infer --model yolov8s-coco'

# decode smoke test, no camera:
./build/zedx_metis_infer --image ~/voyager-sdk/media/h264/traffic1_1080p.mp4
```

Quit with **Esc** (or Ctrl-C when `--headless`). Models must be deployed once
with the Voyager SDK. The full ROS mission holds the camera + Metis   stop it
first (`sudo systemctl stop jetson-av-mission.service jetson-av.slice`).

## Full documentation

Architecture, the accelerator map, the twelve enhancements, `--aipu-cores`
semantics, performance/`--depth-every` tuning, the flag reference, and the UDP
publish schema are in **[docs/ZEDX_METIS_CPP.md](../../docs/ZEDX_METIS_CPP.md)**.
Run commands + baselines: **[docs/SAMPLES.md](../../docs/SAMPLES.md)** §3.

## Files

| File | Role |
|---|---|
| `zedx_metis_infer.cpp` | lean detector |
| `zedx_metis_fusion.cpp` | full 3-stage fusion pipeline |
| `yolo_decode.hpp` | shared v5/v8 host decode |
| `preprocess.cu` / `.cuh` | CUDA letterbox + int8 quantize kernel |
| `CMakeLists.txt` | CUDA build; axruntime + ZED + OpenCV-CUDA + libaxldev |
