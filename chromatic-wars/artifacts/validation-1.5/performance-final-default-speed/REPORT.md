# Final matched default-speed capacity comparison

Original frozen **1.4.3** versus final current: **12 PASS / 0 FAIL**, both actual process exits0, no engine errors, unchanged source SHA256 within each run. Each version ran six cases,60 measured batches plus10 excluded warm-up batches. Each batch is one1/120sim-second step with2GPU substeps. Every case retained its exact active count and integer total energy; overflow0.

Actual backend: **llvmpipe LLVM19.1.7,256bits software Vulkan**, Godot4.6.3 Forward+, Xvfb. CPU affinity0–3, LP_NUM_THREADS4, cgroup quota400000/100000 (4CPU). No RTX5060Ti measurement or FPS promise. Terrain512², render768², exact energy, friendly physical collisions on, automatic gun off, seed20261016. Same initial lattice, all team0, three enemy cores dead; velocity normalize(30,17)×140 and stored launch speed140.

## Primary observed results

| Active | Maximum capacity | Baseline GPU TOTAL p50 ms | Final GPU TOTAL p50 ms | Baseline drawn FPS / 1%low | Final drawn FPS / 1%low | Baseline / final frame p95 ms |
|---:|---:|---:|---:|---:|---:|---:|
| 1000 | 10000 | 20.528 | 22.854 | 43.6 / 4.9 | 29.0 / 4.8 | 58.98 / 113.86 |
| 10000 | 10000 | 30.092 | 31.855 | 33.6 / 4.2 | 48.7 / 19.2 | 99.84 / 46.80 |
| 1000 | 100000 | 27.641 | 23.037 | 46.6 / 19.6 | 34.3 / 3.0 | 44.04 / 77.43 |
| 10000 | 100000 | 44.495 | 31.697 | 23.5 / 3.1 | 45.5 / 8.7 | 162.67 / 48.71 |
| 1000 | 1000000 | 100.732 | 26.010 | 17.6 / 2.7 | 29.0 / 3.8 | 178.44 / 115.75 |
| 10000 | 1000000 | 113.968 | 32.854 | 15.1 / 2.1 | 30.8 / 2.3 | 235.83 / 71.56 |

At10,000 steady active particles, baseline GPU time rises30.09→113.97ms when pool capacity grows100×, while final stays31.85–32.85ms. At1,000 active, baseline20.53→100.73ms versus final22.85–26.01ms. This removes the dominant empty-capacity linear cost; it does not prove that capacity has literally no cost. Requested resource memory still grows, and this software-renderer run contains scheduling/render-time variation. At small capacity, final is slightly slower than baseline; do not claim universal improvement.

Final indirect normal groups are16 at1,000active and157 at10,000active across all capacities. For1,000active, final motion medians .53/.53/.49ms, spatial-build .43/.40/.44ms, and serial events1.14/1.09/1.11ms across10k/100k/1M. The residual difference is not an empty-slot scan in these active passes. Full per-stage data below preserves other costs.

## Stage, host, actual completion and allocation detail

| Version / active / cap | Motion ms | Index reset ms | Index build ms | Colored contacts ms | Serial events ms | Maintenance11+12 ms | CPU enqueue / RT submit p50 ms | Async wait p50 ms | Actual completed steps/s | Allocated bytes |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| baseline / 1000 / 10000 | 0.604 | 0.875 | 0.501 | 4.960 | 1.656 | 0.000 | 0.130 / 0.106 | 39.623 | 14.52 | 6747840 |
| baseline / 10000 / 10000 | 0.945 | 0.830 | 0.678 | 9.091 | 6.340 | 0.000 | 0.141 / 0.112 | 49.005 | 11.19 | 6747840 |
| baseline / 1000 / 100000 | 1.154 | 0.839 | 1.101 | 4.813 | 6.940 | 0.000 | 0.144 / 0.116 | 50.650 | 15.55 | 12867840 |
| baseline / 10000 / 100000 | 2.207 | 0.945 | 1.723 | 10.107 | 11.892 | 0.000 | 0.150 / 0.122 | 67.518 | 7.84 | 12867840 |
| baseline / 1000 / 1000000 | 7.411 | 0.935 | 7.347 | 5.066 | 62.284 | 0.000 | 0.164 / 0.130 | 127.671 | 5.86 | 74067840 |
| baseline / 10000 / 1000000 | 8.164 | 0.979 | 8.103 | 10.373 | 67.799 | 0.000 | 0.161 / 0.129 | 142.416 | 5.03 | 74067840 |
| current / 1000 / 10000 | 0.530 | 1.096 | 0.426 | 5.315 | 1.138 | 0.770 | 0.171 / 0.141 | 48.793 | 9.61 | 6828544 |
| current / 10000 / 10000 | 1.036 | 0.944 | 0.700 | 9.001 | 6.249 | 0.787 | 0.158 / 0.132 | 50.376 | 16.13 | 6828544 |
| current / 1000 / 100000 | 0.528 | 1.038 | 0.400 | 5.204 | 1.085 | 0.793 | 0.169 / 0.141 | 45.165 | 11.30 | 13668544 |
| current / 10000 / 100000 | 1.032 | 0.911 | 0.714 | 9.129 | 6.086 | 0.804 | 0.167 / 0.139 | 50.416 | 15.17 | 13668544 |
| current / 1000 / 1000000 | 0.485 | 0.998 | 0.441 | 5.611 | 1.111 | 0.787 | 0.183 / 0.153 | 49.642 | 9.62 | 82068544 |
| current / 10000 / 1000000 | 1.036 | 0.935 | 0.675 | 9.528 | 6.191 | 0.840 | 0.175 / 0.146 | 56.260 | 10.27 | 82068544 |

GPU TOTAL medians use matched unique per-batch timestamps. Drawn FPS/1%low/p50/p95/p99 come from actual rendered frames during the synthetic wait loop, including redraws without a new simulation step; they are not full-game FPS. The actual completed steps/s column is len(samples)/entire measured wall interval, including extra tag-collection frames. The immutable raw field completed_fixed_steps_per_wall_second instead inverts median single-batch wall time; do not confuse the two.

Normal .25-second production telemetry is suppressed during samples, with initial/final small-table readbacks and4-byte async batch fences. Thus this is a compute-capacity fixture rather than an in-game latency test. Async wait includes frame scheduling/queue latency and is not exact blocked CPU-GPU time. Driver-internal blocked time and physical VRAM residency could not be measured. Allocated bytes are application-requested buffers/textures, not physical VRAM. Primary profiling counters are disabled equally; null means unmeasured. Optional counts cover particle-pair/big contacts, not every wall, territory-DDA, shield or core query.

Baseline cgroup throttling during this run:7events/505699µs; final:1event/56429µs. No concurrent heavy test was scheduled, but shared-host/display scheduling still varies; keep all raw tails and avoid exact hardware speedup claims.

`validation_matrix_fixture.gd` is the actual identical fixture source. `comparison.json` retains invocation, cgroup quota/statistics, CPU affinity/threads, fixture SHA256, Git metadata if available and all key source SHA256 before/after. Raw JSON/logs contain all720 measured batches, timestamp stages, actual frame samples and initial/final integer states. Earlier intermediate and failed records remain separate and unmodified. A separate same-rules NOP benchmark in performance-nop-optimization isolates bounded empty-work changes; performance-peak-pulses tests nonempty collision/death/split peaks.

