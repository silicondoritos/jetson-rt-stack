#!/bin/bash
# scripts/verify_dmabuf_zerocopy.sh
# Run ZED X + Metis inference, capture ftrace + perf, check four zero-copy invariants.
# Output: pass/fail JSON + raw trace in /var/log/jetson-rt-stack/dmabuf-verify-<ts>/
set -euo pipefail

: "${AXL_MODEL:=/opt/axelera/models/yolov8n-coco.json}"

TS=$(date +%Y%m%d-%H%M%S)
LOG=/var/log/jetson-rt-stack/dmabuf-verify-$TS
sudo mkdir -p "$LOG"; sudo chown "$USER:$USER" "$LOG"

echo "[1/6] Sanity: dmabuf heaps + sysfs stats"
test -e /dev/dma_heap/linux,cma         || { echo "FAIL: missing /dev/dma_heap/linux,cma"; exit 2; }
test -d /sys/kernel/dmabuf/buffers      || { echo "FAIL: CONFIG_DMABUF_SYSFS_STATS not enabled"; exit 2; }

echo "[2/6] Arm ftrace"
sudo "$(dirname "$0")/setup_dmabuf_trace.sh"

echo "[3/6] Start GStreamer pipeline (5 s, 300 frames)"
gst-launch-1.0 -v \
    nvarguscamerasrc sensor-id=0 num-buffers=300 ! \
    'video/x-raw(memory:NVMM),width=1920,height=1080,format=NV12,framerate=60/1' ! \
    nvvidconv ! 'video/x-raw(memory:NVMM),format=NV12' ! \
    axinferencenet model="$AXL_MODEL" device=metis-0:01:0 \
                   import-mode=dmabuf output-buffer-mode=dmabuf ! \
    fakesink sync=false 2>&1 | tee "$LOG/gst.log" &
GST_PID=$!

sleep 1
GST_CHILD=$(pgrep -P "$GST_PID" gst-launch-1.0 2>/dev/null || echo "$GST_PID")
sudo perf record -F 999 -g -p "$GST_CHILD" -o "$LOG/gst.perf.data" -- sleep 4 &
PERF_PID=$!

wait "$GST_PID"   || true
wait "$PERF_PID" || true

echo "[4/6] Stop ftrace"
sudo "$(dirname "$0")/stop_dmabuf_trace.sh" "$LOG/trace.txt"

echo "[5/6] Capture /sys/kernel/dmabuf/buffers"
sudo find /sys/kernel/dmabuf/buffers -maxdepth 2 -type f \
    \( -name exporter_name -o -name size -o -name attachments -o -name mmap_count \) \
    -printf '%p\n' -exec cat {} \; | tee "$LOG/dmabuf-sysfs.txt"

echo "[6/6] Check invariants"
python3 "$(dirname "$0")/check_dmabuf_invariants.py" \
    --trace "$LOG/trace.txt" \
    --sysfs "$LOG/dmabuf-sysfs.txt" \
    --perf  "$LOG/gst.perf.data" \
    --json  "$LOG/result.json"
cat "$LOG/result.json"
