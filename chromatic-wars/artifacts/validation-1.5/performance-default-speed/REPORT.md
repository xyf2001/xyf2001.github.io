# Intermediate default-speed capacity matrix

Both versions completed all six cases: **12 PASS / 0 FAIL**, exit 0. Sixty measured batches plus ten excluded warm-up batches per case; every batch advances one fixed 1/120 simulation-second step with two GPU substeps. All scenes retained exactly their requested number of live particles, and final integer accounted energy equaled initial energy.

This independent fixture uses actual velocity **normalize(30,17)×140** (stored launch speed 140), terrain 512×512, render 768×768, all team 0, three opposing cores dead, friendly physical collisions enabled, exact 1-energy particles, no automatic gun, seed 20261016. Only maximum pool capacity varies within each active-count trio. It is a synthetic capacity-isolation workload, not a complete battle.

Actual backend: **llvmpipe LLVM 19.1.7, 256 bits, software Vulkan**, Godot 4.6.3 Forward+, Xvfb. CPU affinity 0–3, LP_NUM_THREADS=4, cgroup quota 4 CPU. No other heavy test ran concurrently. These results must not be represented as RTX 5060 Ti measurements.

Primary counters are disabled equally in both versions; null means unmeasured. Normal telemetry is suppressed during measured samples. Completion uses a four-byte asynchronous GPU read, not a whole-pool read. GPU TOTAL is the median of matched per-pass timestamps; actual drawn-frame FPS includes rendering during completion waits and is not full-game FPS or simulation throughput.

| Active | Capacity | Baseline GPU p50 ms | Current GPU p50 ms | Baseline drawn FPS / 1% low | Current drawn FPS / 1% low | Baseline / current frame p95 ms |
|---:|---:|---:|---:|---:|---:|---:|
| 1000 | 10000 | 19.283 | 20.258 | 46.2 / 19.1 | 61.7 / 27.5 | 45.51 / 32.48 |
| 10000 | 10000 | 28.536 | 33.302 | 46.5 / 15.2 | 49.9 / 19.9 | 49.80 / 44.77 |
| 1000 | 100000 | 26.302 | 19.923 | 55.6 / 21.3 | 63.2 / 20.3 | 38.52 / 31.39 |
| 10000 | 100000 | 38.875 | 34.789 | 43.0 / 15.0 | 46.3 / 15.9 | 54.97 / 49.57 |
| 1000 | 1000000 | 93.111 | 20.098 | 24.1 / 8.9 | 59.2 / 22.4 | 108.67 / 34.26 |
| 10000 | 1000000 | 106.097 | 33.842 | 20.9 / 6.6 | 45.6 / 17.7 | 128.01 / 50.19 |

This confirms the capacity dependence seen in the separate low-speed matrix: current GPU time stays roughly constant when empty pool capacity rises from 10,000 to 1,000,000. It also confirms a current low-capacity regression at 10,000 active particles, so this intermediate result is retained before bounded follow-up optimization. No universal speedup claim is justified.

## Stage and host measurements

All columns below are per-batch medians in ms. Spatial construction (mode 4) is separate from spatial reset (mode 3); serial events and big-contact work is mode 6. Maintenance is modes 11+12; baseline does not have these passes. Async wait includes queueing and frame scheduling, not exact CPU blocked-on-GPU time. Physical VRAM residency and driver-internal CPU waits could not be measured.

| Version / active / capacity | Motion | Spatial reset | Spatial build | Colored contact | Serial events | Maintenance | Enqueue CPU | RT submit CPU | Async wait | Allocated bytes |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| baseline / 1000 / 10000 | 0.546 | 0.819 | 0.475 | 4.624 | 1.559 | 0.000 | 0.134 | 0.109 | 52.496 | 6747840 |
| baseline / 10000 / 10000 | 0.900 | 0.797 | 0.638 | 8.475 | 6.114 | 0.000 | 0.131 | 0.107 | 47.444 | 6747840 |
| baseline / 1000 / 100000 | 1.147 | 0.841 | 1.056 | 4.726 | 6.722 | 0.000 | 0.139 | 0.113 | 43.406 | 12867840 |
| baseline / 10000 / 100000 | 1.907 | 0.927 | 1.526 | 9.158 | 11.330 | 0.000 | 0.141 | 0.114 | 57.927 | 12867840 |
| baseline / 1000 / 1000000 | 6.813 | 0.842 | 6.849 | 4.768 | 57.874 | 0.000 | 0.154 | 0.123 | 113.382 | 74067840 |
| baseline / 10000 / 1000000 | 7.814 | 0.934 | 7.342 | 8.886 | 64.155 | 0.000 | 0.162 | 0.128 | 128.211 | 74067840 |
| current / 1000 / 10000 | 0.423 | 0.875 | 0.388 | 4.685 | 1.359 | 0.753 | 0.155 | 0.132 | 38.314 | 6828544 |
| current / 10000 / 10000 | 0.961 | 0.901 | 0.641 | 8.430 | 9.013 | 1.062 | 0.154 | 0.131 | 49.808 | 6828544 |
| current / 1000 / 100000 | 0.420 | 0.887 | 0.388 | 4.516 | 1.333 | 0.739 | 0.141 | 0.123 | 36.026 | 13668544 |
| current / 10000 / 100000 | 1.007 | 0.919 | 0.684 | 8.928 | 9.026 | 1.063 | 0.170 | 0.142 | 54.868 | 13668544 |
| current / 1000 / 1000000 | 0.421 | 0.873 | 0.375 | 4.543 | 1.344 | 0.749 | 0.148 | 0.127 | 38.812 | 82068544 |
| current / 10000 / 1000000 | 0.988 | 0.899 | 0.679 | 8.649 | 9.090 | 1.059 | 0.171 | 0.145 | 53.452 | 82068544 |

Allocated bytes are application-requested buffers/textures, not physical VRAM. The current active/free-ID lists increase allocation slightly while removing scans of empty pool slots. Full per-sample data, all initial/final states, frame p50/p95/p99, completion throughput, overflow counts, resource bytes, and engine output remain in the JSON/logs.

`comparison.json` records identical fixture SHA256, source SHA256 before/after, Git metadata when available, cgroup throttling, command lines, affinity and thread count. Both runs had unchanged source hashes. This is an intermediate pre-follow-up-optimization result; later data must be saved separately.

Throughput-definition clarification: the immutable raw field `completed_fixed_steps_per_wall_second` is 1000 divided by median single-batch wall milliseconds. Actual completed fixed-step throughput for the entire measured interval is `len(samples) / wall_seconds_measured_excluding_warmup`; the latter includes extra tag-collection frames. Neither is full-game throughput.
