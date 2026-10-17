#!/usr/bin/env python3
"""Plot archived results only. Never starts Godot or submits GPU work.

Reproduce with Python + an existing matplotlib installation:
  python3 path/to/charts/plot_performance.py
No downloads or package installation are performed.
"""

from __future__ import annotations

import csv
import hashlib
import json
from pathlib import Path
from statistics import median

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


OUT = Path(__file__).resolve().parent
EVIDENCE = OUT.parent
CAPACITY_INPUT = EVIDENCE / "capacity-uniform140" / "comparison.json"
SCALE_INPUT = EVIDENCE / "scale-current" / "current_matrix.json"
SCALE_METADATA = EVIDENCE / "scale-current" / "comparison.json"
OLD = "#CC7630"
NEW = "#2367AD"


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_csv(name: str, rows: list[dict]) -> None:
    with (OUT / name).open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def style(ax: plt.Axes) -> None:
    ax.set_axisbelow(True)
    ax.grid(axis="y", color="#DCE3EB", linewidth=0.7)
    ax.spines[["top", "right"]].set_visible(False)
    ax.spines[["left", "bottom"]].set_color("#9DAAB7")
    ax.tick_params(colors="#344252", labelsize=10)


def save(fig: plt.Figure, name: str) -> None:
    fig.savefig(OUT / f"{name}.svg", facecolor="white")
    fig.savefig(OUT / f"{name}.png", dpi=160, facecolor="white")
    plt.close(fig)


def capacity_chart() -> list[dict]:
    data = load(CAPACITY_INPUT)
    runs = {run["label"]: run for run in data["runs"]}
    rows = []
    for label in ("baseline", "current"):
        run = runs[label]
        if run["status"] != "PASS" or not run["sources_unchanged_during_run"]:
            raise ValueError(f"Unvalidated source for {label}")
        for result in run["summary"]:
            if result["status"] != "PASS" or result["scenario"] != "uniform140":
                raise ValueError("Unexpected capacity case")
            rows.append({
                "version": label,
                "active_particles": result["active"],
                "pool_capacity": result["capacity"],
                "gpu_TOTAL_p50_ms": result["gpu_batch_p50_ms"],
                "drawn_fps_average": result["drawn_fps_average"],
                "drawn_fps_1pct_low": result["drawn_fps_1pct_low"],
                "measured_batches": result["measured_batches"],
                "warmup_batches": data["warmup"],
                "initial_speed_world_units_per_sim_second": 140.0,
                "device": result["device"],
                "shader_sha256": run["source_sha256_before"]["shaders/battle.glsl"],
                "fixture_sha256": data["fixture_sha256"],
            })
    write_csv("capacity_comparison.csv", rows)

    fig, axes = plt.subplots(1, 2, figsize=(12, 7), sharey=True)
    fig.subplots_adjust(left=0.075, right=0.98, bottom=0.30, top=0.76, wspace=0.10)
    fig.suptitle("Particle pool capacity at fixed active count", y=0.965, fontsize=19, fontweight="bold")
    fig.text(0.5, 0.902, "GPU TOTAL p50 per 1/120-s fixed step, including output rendering; lower is better",
             ha="center", fontsize=11, color="#344252")
    for ax, active in zip(axes, (1000, 10000)):
        style(ax)
        for label, color, marker, title in (
            ("baseline", OLD, "s", "Old 1.4.3 / 3c1d6864b2c5"),
            ("current", NEW, "o", "Final 1.5.0 / 6e7eda9ff084"),
        ):
            selected = sorted((r for r in rows if r["version"] == label and r["active_particles"] == active),
                              key=lambda r: r["pool_capacity"])
            x = [r["pool_capacity"] for r in selected]
            y = [r["gpu_TOTAL_p50_ms"] for r in selected]
            ax.plot(x, y, color=color, marker=marker, linewidth=2.5, markersize=7, label=title)
            for capacity, elapsed in zip(x, y):
                offset = (0, 10 if label == "baseline" else -19)
                ax.annotate(f"{elapsed:.2f}", (capacity, elapsed), xytext=offset,
                            textcoords="offset points", ha="center", color=color,
                            fontsize=10, fontweight="bold")
        ax.set_title(f"{active:,} active particles", fontsize=14, pad=12)
        ax.set_xscale("log")
        ax.set_xlim(7000, 1_430_000)
        ax.set_xticks([10000, 100000, 1000000], ["10,000", "100,000", "1,000,000"])
        ax.minorticks_off()
        ax.set_xlabel("Maximum particle pool capacity", labelpad=12)
        ax.set_ylim(0, 120)
    axes[0].set_ylabel("GPU TOTAL p50 (ms)", labelpad=10)
    handles, labels = axes[0].get_legend_handles_labels()
    fig.legend(handles, labels, loc="upper center", bbox_to_anchor=(0.5, 0.865), ncol=2, frameon=False)
    fig.text(0.075, 0.17,
             "Software Vulkan: llvmpipe (LLVM 19.1.7, 256 bits) — NOT RTX 5060 Ti measurements.\n"
             "Godot 4.6.3 Forward+; 4 CPU cores; grid 512²; output 768²; speed 140; two physical substeps.\n"
             "60 measured + 10 warmup steps per case; profiling counters off; identical relevant fixture conditions.",
             fontsize=10, color="#344252", linespacing=1.65, va="top")
    fig.text(0.075, 0.052,
             "The final version is slightly slower in the 10,000-capacity cases. These are GPU batch times, not game FPS.",
             fontsize=10, color="#5F3B1E")
    save(fig, "capacity_comparison")
    return rows


def scale_chart() -> list[dict]:
    data = load(SCALE_INPUT)
    metadata = load(SCALE_METADATA)
    run = metadata["runs"][0]
    if data["failed"] or run["status"] != "PASS" or not run["sources_unchanged_during_run"]:
        raise ValueError("Unvalidated scale source")
    rows = []
    for active in (1000, 5000, 10000, 30000, 50000, 100000):
        capacity = max(active, 10000)
        result = next(r for r in data["results"] if r["scenario"] == "uniform"
                      and r["requested_active"] == active and r["capacity"] == capacity)
        if result["status"] != "PASS":
            raise ValueError("Unexpected scale failure")
        rows.append({
            "version": "current",
            "active_particles": active,
            "pool_capacity": capacity,
            "gpu_TOTAL_p50_ms": median(s["stages"]["gpu_ms_by_mode"]["TOTAL"] for s in result["samples"]),
            "drawn_fps_average": result["drawn_fps_average"],
            "drawn_fps_1pct_low": result["drawn_fps_1pct_low"],
            "completed_fixed_steps_per_wall_second": result["completed_fixed_steps_per_wall_second"],
            "measured_batches": len(result["samples"]),
            "warmup_batches": result["warmup_fixed_steps_excluded"],
            "initial_speed_world_units_per_sim_second": result["initial_normal_speed"],
            "device": result["device"],
            "shader_sha256": run["source_sha256_before"]["shaders/battle.glsl"],
            "fixture_sha256": metadata["fixture_sha256"],
        })
    write_csv("active_particle_scaling.csv", rows)

    fig, ax = plt.subplots(figsize=(10, 7))
    fig.subplots_adjust(left=0.11, right=0.96, bottom=0.29, top=0.79)
    fig.suptitle("Final version: active-particle scaling", y=0.955, fontsize=19, fontweight="bold")
    fig.text(0.5, 0.892, "GPU TOTAL p50 per 1/120-s fixed step, including output rendering; lower is better",
             ha="center", fontsize=11, color="#344252")
    style(ax)
    x = [r["active_particles"] for r in rows]
    y = [r["gpu_TOTAL_p50_ms"] for r in rows]
    ax.plot(x, y, color=NEW, marker="o", linewidth=2.5, markersize=7)
    for active, elapsed in zip(x, y):
        ax.annotate(f"{elapsed:.2f}", (active, elapsed), xytext=(0, 10),
                    textcoords="offset points", ha="center", color=NEW, fontsize=10, fontweight="bold")
    ax.set_xscale("log")
    ax.set_xlim(700, 145000)
    ax.set_xticks(x, ["1,000", "5,000", "10,000", "30,000", "50,000", "100,000"])
    ax.minorticks_off()
    ax.set_ylim(0, 215)
    ax.set_xlabel("Active particles (pool capacity = max[10,000, active])", labelpad=12)
    ax.set_ylabel("GPU TOTAL p50 (ms)", labelpad=10)
    fig.text(0.11, 0.17,
             "Software Vulkan: llvmpipe (LLVM 19.1.7, 256 bits) — NOT RTX 5060 Ti measurements.\n"
             "Final Shader 6e7eda9ff084; Godot 4.6.3; grid 512²; output 768²; two physical substeps.\n"
             "120 measured + 10 warmup steps; counters off; initial velocity (30, 17), speed ≈34.48.",
             fontsize=10, color="#344252", linespacing=1.65, va="top")
    fig.text(0.11, 0.052,
             "Separate low-speed workload: do not combine with speed-140 capacity data to calculate speedup.\n"
             "No RTX FPS prediction; no curve fitting or extrapolation.",
             fontsize=10, color="#5F3B1E", linespacing=1.55)
    save(fig, "active_particle_scaling")
    return rows


def main() -> None:
    plt.rcParams.update({"font.family": "DejaVu Sans", "svg.fonttype": "none", "font.size": 11})
    capacity_rows = capacity_chart()
    scale_rows = scale_chart()
    outputs = [p for p in OUT.iterdir() if p.suffix in (".csv", ".svg", ".png")]
    provenance = {
        "purpose": "offline plots of archived measurements; no game or GPU execution",
        "input_sha256": {str(p.relative_to(EVIDENCE)): sha(p)
                         for p in (CAPACITY_INPUT, SCALE_INPUT, SCALE_METADATA)},
        "generator_sha256": sha(Path(__file__).resolve()),
        "matplotlib_version": matplotlib.__version__,
        "capacity_rows": len(capacity_rows),
        "scale_rows": len(scale_rows),
        "output_sha256": {p.name: sha(p) for p in sorted(outputs)},
        "hardware_note": "llvmpipe software Vulkan; not RTX 5060 Ti performance",
    }
    (OUT / "plot_provenance.json").write_text(json.dumps(provenance, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Saved {len(outputs)} chart/CSV files and provenance to {OUT}")


if __name__ == "__main__":
    main()
