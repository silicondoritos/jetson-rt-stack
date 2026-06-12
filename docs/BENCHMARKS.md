---
title: Benchmarks
layout: default
nav_order: 29
description: "Measured ZED X to Axelera Metis throughput, GPU load, power, and thermals on the Jetson Orin NX 16GB: detector-only and full sensor-fusion configurations, reproducible via scripts/bench_zedx_metis.sh."
---

# ZED X + Metis benchmarks (Orin NX 16GB)

Real, reproducible numbers for the C++ samples in [examples/zedx_metis_cpp/](https://github.com/silicondoritos/jetson-rt-stack/tree/main/examples/zedx_metis_cpp). Every row below was measured headless on the reference device, with `tegrastats` sampled during each run. Regenerate the whole dataset and charts on any device with:

```bash
# build samples, stop the ROS mission so the camera/Metis are free, then:
bash scripts/bench_zedx_metis.sh                       # -> docs/assets/benchmarks/zedx_metis_bench.csv
/opt/av-env/bin/python scripts/plot_zedx_metis_bench.py  # -> the PNGs below
```

See [ZED X + Metis C++]({{ '/ZEDX_METIS_CPP' | relative_url }}) for the architecture and [Samples & Tests]({{ '/SAMPLES' | relative_url }}) for run commands.

## Method

- **Device:** Jetson Orin NX 16GB, L4T R36.4.3 / JetPack 6.2, MAXN_SUPER. Axelera Metis M.2 (PCIe), Stereolabs ZED X (GMSL2).
- **Samples:** `zedx_metis_infer` (detector only: grab, letterbox+quantize, Metis, decode+NMS) and `zedx_metis_fusion` (adds NEURAL_LIGHT stereo depth, skeleton/body tracking, IMU-fused pose, per-object distance + world position, IoU tracking).
- **Measure:** headless, ~14 s measured per config in this dataset (the harness passes `--seconds $SECS`, default 15, configurable). Display/encode cost is excluded; this is the raw compute ceiling. `fps` is end-to-end (camera grab through decode/fusion). GPU %, power, and temperature are `tegrastats` averages/peaks over the run.
- **Models:** `yolov5s-v7-coco` and `yolov8s-coco` run batch-4 (one frame per AIPU core); `yolov8l-coco` is large enough that it runs single-core batch-1. See [the aipu-cores explanation]({{ '/ZEDX_METIS_CPP' | relative_url }}#how---aipu-cores-actually-works-and-why-yolov8l-is-single-core).
- Some run-to-run variance (a few fps) is normal: depth cost depends on scene texture, and the board shares one iGPU.

## Throughput by configuration

![FPS by configuration]({{ '/assets/benchmarks/fps_by_config.png' | relative_url }})

{% include_relative assets/benchmarks/analytics_table.md %}

## Decoupling depth cadence (`--depth-every`)

The single biggest tuning lever for the full-fusion app. Stereo depth (computed inside `grab()`) and the skeleton net are the only heavy iGPU consumers; detection runs on the Metis NPU and is nearly free. Running depth + skeleton every Nth frame, while detection/display/pose run every frame, lifts throughput with **no feature lost** (the IoU tracker carries distance/velocity/time-to-collision forward; depth and skeletons just refresh at rate/N).

![Depth cadence sweep]({{ '/assets/benchmarks/depth_cadence.png' | relative_url }})

yolov8s fusion at HD1200@60: **35 fps** (depth every frame) to **53 fps** (every 6th), all features live. The live display tuning session recorded the same lever at 45 → 57 fps (`--depth-every` 1 → 3); depth cost is scene-dependent and this dataset was recorded in short ~14 s windows, so a few fps of offset between sessions is expected. The trend, not the exact row, is the result. Flag semantics: [ZED X + Metis C++]({{ '/ZEDX_METIS_CPP' | relative_url }}#--depth-every-n-keep-all-features-and-still-go-fast).

## GPU load and power

![GPU and power]({{ '/assets/benchmarks/gpu_power.png' | relative_url }})

The detector-only path leaves the iGPU almost idle (~24% average, the ZED rectification) because detection is on the Metis NPU. Full fusion drives the iGPU hard: depth-every-frame peaks GR3D at 98% and pulls 17.3 W; raising `--depth-every` drops both. Thermals stayed at ~60 to 61 C throughout (no throttling; the Orin NX throttles far higher).

## What the data says

- **Detection is free.** Detector-only yolov8s hits the 60 fps camera at HD1200 (56 fps) and **92 fps at SVGA@120**, at ~24% GPU. The Metis carries it; the GPU is idle. yolov8l (single-core) is the exception at ~37 fps, NPU-inference-bound.
- **Depth is the cost, not detection.** Adding NEURAL_LIGHT depth + skeleton is what pulls the GPU to saturation. `--depth-every` is how you buy throughput back without dropping features.
- **Best "all features, fast"**: `yolov8s --depth-every 3` to `6` gives **46 to 53 fps** with depth, skeleton, pose, world-frame, and tracking all live.
- **Most accurate**: yolov8l caps near **37 to 39 fps** regardless of cadence, because its single-core Metis inference (not depth) is the bottleneck there.
- **Skeleton cost**: at N=3, `--no-bodies` vs bodies is ~44 vs ~46 fps and a lower GPU peak (77% vs 86%) - the body net is a real but modest GPU consumer.
- **Power**: 13.5 to 14 W detector, up to 17.3 W at full depth-every-frame fusion. All within the module's MAXN_SUPER envelope.

Raw data: [`docs/assets/benchmarks/zedx_metis_bench.csv`](https://github.com/silicondoritos/jetson-rt-stack/blob/main/docs/assets/benchmarks/zedx_metis_bench.csv).
