#!/usr/bin/env bash
# =============================================================================
# scripts/bench_zedx_metis.sh - benchmark the ZED X + Metis C++ samples
# =============================================================================
# Runs a matrix of headless configurations (model x camera mode x depth cadence)
# of zedx_metis_infer (detector only) and zedx_metis_fusion (full perception),
# samples tegrastats during each run, and writes one CSV row per config to
# docs/assets/benchmarks/zedx_metis_bench.csv. Feed that CSV to
# scripts/plot_zedx_metis_bench.py to produce the charts in docs/BENCHMARKS.md.
#
# Prereqs: samples built (examples/zedx_metis_cpp/build), models deployed, the
# ZED X free (stop jetson-av-mission first), user in the `zed` group.
#
# Run:  bash scripts/bench_zedx_metis.sh          # ~4 min, SECS=15 per case
#       SECS=20 bash scripts/bench_zedx_metis.sh  # longer windows
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$HERE/examples/zedx_metis_cpp/build"
OUTDIR="$HERE/docs/assets/benchmarks"
CSV="$OUTDIR/zedx_metis_bench.csv"
SECS="${SECS:-15}"
GAP="${GAP:-3}"          # seconds between runs to let the camera release
mkdir -p "$OUTDIR"

if [ ! -x "$BIN/zedx_metis_fusion" ] || [ ! -x "$BIN/zedx_metis_infer" ]; then
  echo "build the samples first: (cd examples/zedx_metis_cpp && cmake -B build && cmake --build build)"
  exit 1
fi

echo "sample,model,mode,fps_req,depth_every,bodies,seconds,frames,fps,gr3d_avg_pct,gr3d_max_pct,tj_avg_c,vdd_in_mw,ram_peak_mb" > "$CSV"

# aggregate one tegrastats log -> "gr3d_avg gr3d_max tj_avg vdd_avg ram_peak"
agg_ts() {
  awk '
    /GR3D_FREQ [0-9]+%/ { s=$0; sub(/.*GR3D_FREQ /,"",s); sub(/%.*/,"",s); g=s+0; gs+=g; gn++; if(g>gmax)gmax=g }
    /tj@[0-9.]+C/       { s=$0; sub(/.*tj@/,"",s);        sub(/C.*/,"",s); t=s+0; ts+=t; tn++ }
    /VDD_IN [0-9]+mW/   { s=$0; sub(/.*VDD_IN /,"",s);    sub(/mW.*/,"",s); v=s+0; vs+=v; vn++ }
    /RAM [0-9]+\//      { s=$0; sub(/.*RAM /,"",s);        sub(/\/.*/,"",s); r=s+0; if(r>rmax)rmax=r }
    END { printf "%.0f %.0f %.1f %.0f %.0f",(gn?gs/gn:0),gmax,(tn?ts/tn:0),(vn?vs/vn:0),rmax }' "$1"
}

# run_case <sample infer|fusion> <model> <mode> <fps> <depth_every|-> <bodies 0|1>
run_case() {
  local sample="$1" model="$2" mode="$3" fps="$4" de="$5" bodies="$6"
  local exe="$BIN/zedx_metis_$sample"
  local args="--model $model --mode $mode --fps $fps --headless --seconds $SECS"
  [ "$sample" = "fusion" ] && args="$args --depth-every $de"
  [ "$sample" = "fusion" ] && [ "$bodies" = "0" ] && args="$args --no-bodies"
  local label="$sample/$model/$mode@$fps"
  [ "$sample" = "fusion" ] && label="$label/N=$de/bodies=$bodies"
  printf '  %-52s ' "$label"

  local tslog; tslog="$(mktemp)"
  tegrastats --interval 500 > "$tslog" 2>/dev/null &
  local tspid=$!
  local out; out="$(sg zed -c "$exe $args" 2>/dev/null)"
  kill "$tspid" 2>/dev/null; wait "$tspid" 2>/dev/null

  local frames fps_got
  frames="$(printf '%s\n' "$out" | grep -oE '[0-9]+ frames in' | grep -oE '^[0-9]+' | tail -1)"
  fps_got="$(printf '%s\n' "$out" | grep -oE 'end-to-end [0-9.]+ FPS' | grep -oE '[0-9.]+' | tail -1)"
  local ts; ts="$(agg_ts "$tslog")"; rm -f "$tslog"
  read -r g_avg g_max tj vdd ram <<<"$ts"

  if [ -z "${fps_got:-}" ]; then
    echo "FAILED (camera busy? mission running?)"
    echo "$sample,$model,$mode,$fps,$de,$bodies,$SECS,,,$g_avg,$g_max,$tj,$vdd,$ram" >> "$CSV"
  else
    printf '%6s FPS  GPU %s%%/%s%%  %s C  %s mW\n' "$fps_got" "$g_avg" "$g_max" "$tj" "$vdd"
    echo "$sample,$model,$mode,$fps,$de,$bodies,$SECS,$frames,$fps_got,$g_avg,$g_max,$tj,$vdd,$ram" >> "$CSV"
  fi
  sleep "$GAP"
}

echo "== ZED X + Metis benchmark (SECS=$SECS/run) -> $CSV =="
echo "-- detector only (zedx_metis_infer, no depth) --"
run_case infer  yolov5s-v7-coco HD1200 60  -  1
run_case infer  yolov8s-coco    HD1200 60  -  1
run_case infer  yolov8s-coco    SVGA   120 -  1
run_case infer  yolov8l-coco    HD1200 60  -  1
echo "-- full fusion (zedx_metis_fusion: depth + skeleton + pose + tracking) --"
run_case fusion yolov8s-coco    HD1200 60  1  1
run_case fusion yolov8s-coco    HD1200 60  3  1
run_case fusion yolov8s-coco    HD1200 60  6  1
run_case fusion yolov8s-coco    HD1200 60  3  0
run_case fusion yolov8s-coco    SVGA   60  3  1
run_case fusion yolov8l-coco    HD1200 60  3  1
run_case fusion yolov8l-coco    SVGA   60  3  1
echo "== done. CSV: $CSV =="
