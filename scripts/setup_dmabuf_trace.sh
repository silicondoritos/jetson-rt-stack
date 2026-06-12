#!/bin/bash
# scripts/setup_dmabuf_trace.sh   arm ftrace for dma_buf zero-copy verification.
set -euo pipefail
T=/sys/kernel/debug/tracing

echo 0     | sudo tee $T/tracing_on >/dev/null
echo nop   | sudo tee $T/current_tracer >/dev/null
echo       | sudo tee $T/set_event >/dev/null
echo       | sudo tee $T/set_ftrace_filter >/dev/null

sudo tee $T/set_event >/dev/null <<'EOF'
dma_fence:dma_fence_init
dma_fence:dma_fence_emit
dma_fence:dma_fence_signaled
dma_fence:dma_fence_wait_start
dma_fence:dma_fence_wait_end
dma_fence:dma_fence_destroy
axl:axl_dmabuf_import
axl:axl_dmabuf_release
EOF

echo function_graph | sudo tee $T/current_tracer >/dev/null

sudo tee $T/set_graph_function >/dev/null <<'EOF'
dma_buf_attach
dma_buf_detach
dma_buf_map_attachment
dma_buf_unmap_attachment
dma_buf_export
dma_buf_fd
EOF

echo 16384 | sudo tee $T/buffer_size_kb >/dev/null
echo 1     | sudo tee $T/tracing_on >/dev/null
echo "Trace armed. Run workload, then: scripts/stop_dmabuf_trace.sh <output_file>"
