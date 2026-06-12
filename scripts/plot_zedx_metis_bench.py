#!/usr/bin/env python3
# =============================================================================
# scripts/plot_zedx_metis_bench.py - charts + analytics from the ZED X + Metis
# benchmark CSV (scripts/bench_zedx_metis.sh).
#
# Reads docs/assets/benchmarks/zedx_metis_bench.csv and writes PNG charts +
# a markdown analytics fragment next to it. Pure matplotlib (no seaborn).
#
# Run:  /opt/av-env/bin/python scripts/plot_zedx_metis_bench.py
# =============================================================================
import csv
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(HERE, "docs", "assets", "benchmarks")
CSV = os.path.join(OUT, "zedx_metis_bench.csv")
GREEN, BLUE, RED, GRAY = "#76B900", "#2E86DE", "#E74C3C", "#7F8C8D"


def load():
    rows = []
    with open(CSV) as f:
        for r in csv.DictReader(f):
            if not r["fps"]:
                continue
            for k in ("fps", "gr3d_avg_pct", "gr3d_max_pct", "tj_avg_c", "vdd_in_mw"):
                r[k] = float(r[k])
            rows.append(r)
    return rows


def label(r):
    base = f"{r['model'].replace('-coco','').replace('-v7','')}\n{r['mode']}@{r['fps_req']}"
    if r["sample"] == "fusion":
        base += f"\nN={r['depth_every']}" + ("" if r["bodies"] == "1" else " no-skel")
    return base


def chart_fps(rows):
    infer = [r for r in rows if r["sample"] == "infer"]
    fusion = [r for r in rows if r["sample"] == "fusion"]
    data = infer + fusion
    fig, ax = plt.subplots(figsize=(12, 5.2))
    xs = range(len(data))
    colors = [BLUE] * len(infer) + [GREEN] * len(fusion)
    bars = ax.bar(xs, [r["fps"] for r in data], color=colors)
    for b, r in zip(bars, data):
        ax.text(b.get_x() + b.get_width() / 2, b.get_height() + 0.6,
                f"{r['fps']:.0f}", ha="center", va="bottom", fontsize=9, fontweight="bold")
    ax.set_xticks(list(xs))
    ax.set_xticklabels([label(r) for r in data], fontsize=8)
    ax.set_ylabel("end-to-end FPS (headless)")
    ax.axhline(60, color=GRAY, ls="--", lw=1)
    ax.text(len(data) - 0.5, 61, "60 fps camera", color=GRAY, ha="right", fontsize=8)
    ax.set_title("ZED X -> Metis: throughput by configuration (Orin NX 16GB)")
    ax.legend(handles=[plt.Rectangle((0, 0), 1, 1, color=BLUE),
                       plt.Rectangle((0, 0), 1, 1, color=GREEN)],
              labels=["detector only (no depth)", "full fusion (depth+skeleton+track)"],
              loc="upper right", fontsize=9)
    ax.margins(x=0.01)
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, "fps_by_config.png"), dpi=130)
    plt.close(fig)


def chart_cadence(rows):
    pts = sorted([r for r in rows if r["sample"] == "fusion" and r["model"] == "yolov8s-coco"
                  and r["mode"] == "HD1200" and r["bodies"] == "1"],
                 key=lambda r: int(r["depth_every"]))
    if not pts:
        return
    n = [int(r["depth_every"]) for r in pts]
    fps = [r["fps"] for r in pts]
    fig, ax = plt.subplots(figsize=(7, 4.6))
    ax.plot(n, fps, "-o", color=GREEN, lw=2.5, ms=9)
    for x, y in zip(n, fps):
        ax.text(x, y + 0.8, f"{y:.0f}", ha="center", fontweight="bold")
    ax.set_xlabel("--depth-every N  (depth+skeleton run every Nth frame)")
    ax.set_ylabel("end-to-end FPS")
    ax.set_title("Decoupling depth cadence (yolov8s fusion, HD1200@60)\nall features stay live; depth/skeleton refresh at rate/N")
    ax.set_xticks(n)
    ax.grid(alpha=0.3)
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, "depth_cadence.png"), dpi=130)
    plt.close(fig)


def chart_gpu_power(rows):
    fig, (a1, a2) = plt.subplots(1, 2, figsize=(13, 5))
    xs = range(len(rows))
    a1.bar([x - 0.2 for x in xs], [r["gr3d_avg_pct"] for r in rows], 0.4, color=GREEN, label="GPU avg %")
    a1.bar([x + 0.2 for x in xs], [r["gr3d_max_pct"] for r in rows], 0.4, color=GRAY, label="GPU peak %")
    a1.set_ylabel("GR3D (iGPU) utilisation %")
    a1.set_title("GPU load: detector frees the GPU; fusion depth saturates it")
    a1.set_xticks(list(xs))
    a1.set_xticklabels([label(r) for r in rows], fontsize=7, rotation=35, ha="right")
    a1.legend(fontsize=9)
    a2.bar(list(xs), [r["vdd_in_mw"] / 1000 for r in rows],
           color=[BLUE if r["sample"] == "infer" else GREEN for r in rows])
    for x, r in zip(xs, rows):
        a2.text(x, r["vdd_in_mw"] / 1000 + 0.05, f"{r['vdd_in_mw']/1000:.1f}", ha="center", fontsize=8)
    a2.set_ylabel("board power VDD_IN (W)")
    a2.set_title("Total module power")
    a2.set_xticks(list(xs))
    a2.set_xticklabels([label(r) for r in rows], fontsize=7, rotation=35, ha="right")
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, "gpu_power.png"), dpi=130)
    plt.close(fig)


def write_analytics(rows):
    def g(sample, model, mode, de=None, bodies="1"):
        for r in rows:
            if (r["sample"] == sample and r["model"] == model and r["mode"] == mode
                    and r["bodies"] == bodies and (de is None or r["depth_every"] == str(de))):
                return r
        return None
    lines = ["<!-- generated by scripts/plot_zedx_metis_bench.py -->", ""]
    lines.append("| sample | model | mode | depth-every | bodies | FPS | GPU avg/peak % | power W | tj C |")
    lines.append("|---|---|---|---|---|---|---|---|---|")
    for r in rows:
        lines.append(f"| {r['sample']} | {r['model']} | {r['mode']}@{r['fps_req']} | "
                     f"{r['depth_every']} | {r['bodies']} | **{r['fps']:.1f}** | "
                     f"{r['gr3d_avg_pct']:.0f}/{r['gr3d_max_pct']:.0f} | "
                     f"{r['vdd_in_mw']/1000:.1f} | {r['tj_avg_c']:.0f} |")
    with open(os.path.join(OUT, "analytics_table.md"), "w") as f:
        f.write("\n".join(lines) + "\n")


def main():
    rows = load()
    chart_fps(rows)
    chart_cadence(rows)
    chart_gpu_power(rows)
    write_analytics(rows)
    print(f"wrote charts + analytics_table.md to {OUT} ({len(rows)} configs)")


if __name__ == "__main__":
    main()
