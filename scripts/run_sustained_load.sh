#!/bin/bash
# scripts/run_sustained_load.sh DURATION_SEC
# Sustained load generator for MAXN_SUPER HV rail verification (§3.6).
set -euo pipefail
DUR="${1:-300}"
END=$(($(date +%s) + DUR))

gst-launch-1.0 nvarguscamerasrc sensor-id=0 ! \
    'video/x-raw(memory:NVMM),width=1920,height=1080,framerate=60/1' ! \
    nvv4l2h265enc bitrate=20000000 ! fakesink &
P1=$!

( while [ "$(date +%s)" -lt "$END" ]; do
    /opt/axelera/voyager/bin/inference.py yolov8n-coco --metis pcie \
        --input /opt/axelera/test-clips/traffic_1080p60.mp4 --loop
  done ) &
P2=$!

stress-ng --cpu 4 --cpu-method matrixprod --timeout "${DUR}s" &
P3=$!

wait "$P3"
kill "$P1" "$P2" 2>/dev/null || true
