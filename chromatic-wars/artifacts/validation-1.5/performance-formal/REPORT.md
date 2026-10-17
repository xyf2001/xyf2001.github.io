# Intermediate matched Vulkan matrix (before bounded follow-up optimization)

Both baseline 1.4.3 and current checkpoint completed all 13 cases: **26 PASS, 0 FAIL**; each case used 10 warm-up batches and 120 measured batches. Each batch completed one 1/120 simulation-second step. Normal scenes used 2 GPU substeps; the 2000-unit/s sniper scene used 6. Initial/final integer accounted energy matched every fixture, and all uniform cases retained their requested active count.

This is **software Vulkan llvmpipe (LLVM 19.1.7, 256 bits)** under Godot 4.6.3 Forward+, Xvfb, 4 llvmpipe threads, CPU affinity 0–3, and a 4-CPU cgroup quota. No other heavy CPU/GPU tests ran concurrently. These numbers are not RTX 5060 Ti results.

Identical fixture bytes ran on both versions with terrain 512×512, render 768×768, friendly physical collisions enabled, no auto gun, exact integer energy, and seed 20261016. The synthetic `uniform` velocity is **(30,17), speed 34.48**, not the 140 default game launch speed. The separate `performance-default-speed` matrix measures the latter. Uniform scenes use team 0 and mark the other 3 cores dead so combat cannot change the active workload. Statistics are read initially/finally; per-batch completion uses a 4-byte asynchronous fence read. Normal 0.25-second production telemetry is deliberately suppressed during timing.

GPU timestamp medians are sums of matched per-pass timestamps in each completed batch. Drawn FPS is from actual rendered frames while asynchronously waiting for batches, including display frames with no new simulation step. It must not be interpreted as full-game FPS or simulation throughput. 1% low is the reciprocal of the mean slowest 1% actual drawn-frame intervals. The raw JSON includes frame count, p50/p95/p99, step throughput, and every timestamp sample.

Primary profiling counters were disabled equally for both versions. Candidate/contact values are null, not zero. The current optional counters cover particle-pair and big-contact candidates/confirmed contacts (including sniper-kind-big), but do not count every wall, terrain DDA, shield, or core geometry query. The original immutable raw JSON contains an older, narrower counter-description string; this paragraph corrects that description without altering recorded evidence.

## Completed cases

| Scene | Active initial→final | Capacity | Baseline GPU p50 ms | Current GPU p50 ms | Baseline drawn FPS / 1% low | Current drawn FPS / 1% low |
|---|---:|---:|---:|---:|---:|---:|
| uniform | 1000→1000 / 1000 | 10000 | 19.48 | 20.32 | 49.7 / 7.4 | 56.9 / 23.8 |
| uniform | 10000→10000 / 10000 | 10000 | 29.13 | 33.16 | 47.6 / 14.9 | 46.8 / 15.5 |
| uniform | 1000→1000 / 1000 | 100000 | 26.86 | 20.33 | 44.3 / 6.7 | 59.6 / 22.4 |
| uniform | 10000→10000 / 10000 | 100000 | 36.64 | 33.41 | 42.4 / 9.7 | 46.9 / 18.7 |
| uniform | 1000→1000 / 1000 | 1000000 | 95.61 | 20.41 | 21.0 / 3.9 | 58.8 / 20.7 |
| uniform | 10000→10000 / 10000 | 1000000 | 103.75 | 32.98 | 21.3 / 5.8 | 48.0 / 18.1 |
| uniform | 5000→5000 / 5000 | 10000 | 23.37 | 25.96 | 59.3 / 25.0 | 53.7 / 22.6 |
| uniform | 30000→30000 / 30000 | 30000 | 54.04 | 66.14 | 35.8 / 14.0 | 30.9 / 10.7 |
| uniform | 50000→50000 / 50000 | 50000 | 83.26 | 102.70 | 26.7 / 9.8 | 21.9 / 7.2 |
| uniform | 100000→100000 / 100000 | 100000 | 183.18 | 218.59 | 13.1 / 2.8 | 11.6 / 4.1 |
| dense_crossing | 1000→2 / 2 | 10000 | 19.14 | 20.04 | 65.2 / 30.3 | 59.4 / 24.8 |
| fast_sniper | 1000→0 / 0 | 10000 | 35.49 | 36.77 | 44.7 / 16.0 | 40.8 / 12.6 |
| four_storm | 1000→5270 / 5270 | 10000 | 39.43 | 39.60 | 30.9 / 3.6 | 40.6 / 13.1 |

Capacity scaling is substantially removed at the same steady active workload: 10,000 active particles cost about 33 ms at all three current pool capacities, whereas the baseline rises from about 29 ms at a 10,000 pool to 104 ms at a 1,000,000 pool. Current low-capacity cost is higher in this intermediate version; the serial-event stage is a visible contributor. These data do not justify claiming every scene is faster.

Dense crossing, sniper, and four-way storm evolve after initialization. Their new rules can change active counts and contact work even when this particular run happens to finish at the same count. They are functional load and energy checks, not a valid direct optimization-percentage claim. Four-way storm adds 4×1080 energy, so accounted total is 5320. High-speed sniper particles start with energy 1: this case stresses motion/terrain sweep, not production of 70/30 children (the latter is separately covered by the weapon suite).

## Stage medians for 10,000 steady active particles

Each row sums both substeps where applicable. Statistics mode 7 is outside timed samples.

| Version / capacity | TOTAL | Motion (2) | Spatial reset (3) | Index build (4) | Colored collisions (5) | Serial events / big (6) | Maintenance (11+12) | Render (8+9+10) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| baseline / 10000 | 29.133 | 0.946 | 0.840 | 0.659 | 8.406 | 5.916 | 0.000 | 10.174 |
| baseline / 100000 | 36.638 | 1.946 | 0.860 | 1.527 | 8.382 | 11.124 | 0.000 | 10.903 |
| baseline / 1000000 | 103.749 | 7.606 | 0.871 | 7.253 | 8.318 | 62.964 | 0.000 | 14.304 |
| current / 10000 | 33.155 | 0.984 | 0.881 | 0.671 | 8.185 | 8.822 | 1.071 | 10.630 |
| current / 100000 | 33.413 | 0.986 | 0.910 | 0.673 | 8.259 | 8.832 | 1.077 | 10.693 |
| current / 1000000 | 32.980 | 0.972 | 0.891 | 0.646 | 8.083 | 8.796 | 1.069 | 10.611 |

## CPU, completion, frame intervals, allocations

GPU fences below are asynchronous completion wall time and include frame scheduling; they are not measurements of CPU blocked inside a driver. Driver-internal synchronization time and physical VRAM residency were unavailable. Buffer/texture allocation bytes are explicitly reported as application-requested allocation, not physical VRAM use.

| Version / active / capacity | Enqueue CPU p50 ms | Render-thread submit p50 ms | Async completion wait p50 ms | Drawn frame p50 / p95 ms | Allocated bytes |
|---|---:|---:|---:|---:|---:|
| baseline / 1000 / 10000 | 0.140 | 0.113 | 38.024 | 11.35 / 46.81 | 6747840 |
| baseline / 10000 / 10000 | 0.143 | 0.117 | 50.085 | 10.55 / 47.90 | 6747840 |
| baseline / 1000 / 100000 | 0.151 | 0.121 | 47.352 | 11.86 / 48.72 | 12867840 |
| baseline / 10000 / 100000 | 0.152 | 0.122 | 55.758 | 9.74 / 54.46 | 12867840 |
| baseline / 1000 / 1000000 | 0.165 | 0.132 | 118.713 | 11.47 / 131.08 | 74067840 |
| baseline / 10000 / 1000000 | 0.163 | 0.129 | 125.790 | 10.62 / 121.34 | 74067840 |
| baseline / 5000 / 10000 | 0.133 | 0.110 | 40.563 | 8.54 / 34.71 | 6747840 |
| baseline / 30000 / 30000 | 0.158 | 0.127 | 72.310 | 9.23 / 67.95 | 8107840 |
| baseline / 50000 / 50000 | 0.154 | 0.124 | 101.160 | 9.11 / 96.79 | 9467840 |
| baseline / 100000 / 100000 | 0.173 | 0.137 | 205.385 | 11.09 / 214.82 | 12867840 |
| current / 1000 / 10000 | 0.156 | 0.131 | 40.963 | 11.36 / 34.84 | 6828544 |
| current / 10000 / 10000 | 0.161 | 0.137 | 50.424 | 9.21 / 48.47 | 6828544 |
| current / 1000 / 100000 | 0.153 | 0.129 | 37.556 | 9.33 / 34.29 | 13668544 |
| current / 10000 / 100000 | 0.173 | 0.144 | 51.767 | 9.41 / 47.98 | 13668544 |
| current / 1000 / 1000000 | 0.157 | 0.134 | 37.989 | 9.55 / 35.00 | 82068544 |
| current / 10000 / 1000000 | 0.158 | 0.135 | 51.020 | 9.48 / 46.62 | 82068544 |
| current / 5000 / 10000 | 0.158 | 0.134 | 44.646 | 9.47 / 40.25 | 6828544 |
| current / 30000 / 30000 | 0.183 | 0.152 | 85.189 | 9.43 / 82.03 | 8348544 |
| current / 50000 / 50000 | 0.189 | 0.155 | 123.313 | 10.90 / 120.04 | 9868544 |
| current / 100000 / 100000 | 0.192 | 0.158 | 242.988 | 12.98 / 239.07 | 13668544 |

## Evidence and reproducibility

`baseline_matrix.log`, `current_matrix.log` preserve actual process output; `baseline_matrix.json`, `current_matrix.json` retain all 3120 measured batches and initial/final states. `comparison.json` records invocation, affinity, thread count, cgroup throttling before/after, fixture SHA256, Git commit when available, and SHA256 for shader, GPU host, settings and other relevant sources before and after execution. All recorded source hashes remained unchanged within each run. The baseline is a frozen snapshot without a Git worktree; current checkpoint was `69633f51b06d6d528ef1f30c37371dcffecacb02`.

This directory is retained as an intermediate result. Later bounded optimizations and their reruns must be saved separately; no failed, slower or superseded result is overwritten. This matrix does not replace full battles, long-term stability tests, Windows export verification, or RTX hardware testing.

Throughput-definition clarification: the immutable raw field `completed_fixed_steps_per_wall_second` is 1000 divided by median single-batch wall milliseconds. Actual completed fixed-step throughput for the entire measured interval is `len(samples) / wall_seconds_measured_excluding_warmup`; the latter includes extra tag-collection frames. Neither is full-game throughput.
