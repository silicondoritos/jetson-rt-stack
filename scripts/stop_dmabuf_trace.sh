#!/bin/bash
# scripts/stop_dmabuf_trace.sh [output_file]
set -euo pipefail
T=/sys/kernel/debug/tracing
OUT=${1:-/var/log/jetson-rt-stack/dmabuf-trace-$(date +%Y%m%d-%H%M%S).txt}
sudo mkdir -p "$(dirname "$OUT")"
echo 0 | sudo tee $T/tracing_on >/dev/null
sudo cp $T/trace "$OUT"
sudo chown "$USER:$USER" "$OUT"
echo "Saved: $OUT"
