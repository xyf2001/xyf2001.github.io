# Final strict default-speed capacity comparison

Original1.4.3 versus finalShader6e7eda9f/host37e131f9: actual12PASS/0FAIL, both process exits0, all source hashes unchanged, all active counts and integer total energy preserved.60measured+10excluded warm-up batches/case; one1/120sim-second step per batch,2GPU substeps. Both use the exact same version2fixture bytes, explicitCD0.5, actual velocitynormalize(30,17)×140,512terrain,768render, exact energy, friendly collisions, no auto gun and seed20261016.

The two effective configuration dictionaries differ only because1.4.3 does not expose growth_curve_time and sniper_split_angle (final values1200 and8). This fixture disables gun emissions and contains no snipers or large balls, so neither field participates in this workload. Relevant particle physics, initial state, step, output, and explicit CD settings match; the whole dictionary is not claimed to be key-identical.

Backend is software Vulkan llvmpipe LLVM19.1.7/256bits, Godot4.6.3 Forward+, Xvfb; CPU affinity0–3/LP_NUM_THREADS4/4CPU quota. These are not RTX5060Ti results. Three enemy cores are dead and all particles team0, isolating live workload from combat. Synthetic initialization is not a claim about normal spawning distribution.

| Active | Capacity | Baseline GPU p50 / p95 ms | Final GPU p50 / p95 ms | Baseline drawn FPS / 1%low | Final drawn FPS / 1%low | Baseline / final frame p95 ms |
|---:|---:|---:|---:|---:|---:|---:|
| 1000 | 10000 | 19.257 / 22.905 | 19.776 / 21.238 | 39.71 / 17.56 | 63.27 / 29.04 | 47.30 / 30.84 |
| 10000 | 10000 | 28.654 / 31.142 | 30.476 / 33.780 | 48.61 / 16.87 | 51.24 / 20.04 | 42.52 / 43.07 |
| 1000 | 100000 | 26.385 / 32.609 | 20.096 / 23.976 | 46.03 / 15.51 | 63.37 / 26.75 | 45.03 / 32.03 |
| 10000 | 100000 | 37.667 / 42.525 | 30.204 / 32.650 | 43.32 / 15.62 | 53.27 / 22.12 | 52.92 / 41.86 |
| 1000 | 1000000 | 94.095 / 100.967 | 20.200 / 35.321 | 23.67 / 8.60 | 59.71 / 11.44 | 110.20 / 31.99 |
| 10000 | 1000000 | 105.067 / 113.558 | 32.501 / 47.416 | 21.52 / 7.29 | 45.36 / 8.28 | 123.93 / 51.85 |

For1000steady active, baselineGPU p50 rises19.26→94.10ms as maximum capacity rises10k→1M, while final remains19.78–20.20ms. For10000active, baseline28.65→105.07ms versus final30.20–32.50ms. This removes the dominant linear empty-slot cost. It does not mean capacity is literally free: allocation memory grows and scheduling/render/cache variation remains. At10kcapacity/10kactive final is slightly slower, so there is no universal improvement claim.

Final indirect normal groups remain16 for1000active and157 for10000active at all capacities. Actual counts, rather than requested capacity alone, drive motion/build/splat work. The new packed generation does not add a storage buffer.

## Stage, CPU, completion and allocation medians

| Version / active / cap | Motion ms | Grid reset ms | Grid build ms | Colored collision ms | Events/big ms | Maintenance11+12 ms | CPU enqueue / RT submit ms | Async completion wall ms | Actual fixed steps/full wall second | Allocated bytes |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| baseline / 1000 / 10000 | 0.546 | 0.800 | 0.480 | 4.526 | 1.575 | 0.000 | 0.127 / 0.105 | 53.654 | 13.24 | 6747840 |
| baseline / 10000 / 10000 | 0.892 | 0.796 | 0.647 | 8.504 | 6.152 | 0.000 | 0.131 / 0.108 | 47.699 | 16.20 | 6747840 |
| baseline / 1000 / 100000 | 1.154 | 0.849 | 1.075 | 4.746 | 6.813 | 0.000 | 0.131 / 0.107 | 48.068 | 15.34 | 12867840 |
| baseline / 10000 / 100000 | 1.937 | 0.854 | 1.537 | 8.923 | 11.337 | 0.000 | 0.143 / 0.117 | 56.873 | 14.44 | 12867840 |
| baseline / 1000 / 1000000 | 6.975 | 0.873 | 6.979 | 4.762 | 58.386 | 0.000 | 0.155 / 0.123 | 115.445 | 7.89 | 74067840 |
| baseline / 10000 / 1000000 | 7.848 | 0.890 | 7.240 | 8.886 | 63.478 | 0.000 | 0.154 / 0.124 | 125.693 | 7.17 | 74067840 |
| current / 1000 / 10000 | 0.418 | 0.870 | 0.388 | 4.494 | 0.981 | 0.717 | 0.148 / 0.126 | 37.454 | 21.09 | 6828544 |
| current / 10000 / 10000 | 1.007 | 0.870 | 0.655 | 8.545 | 5.992 | 0.769 | 0.171 / 0.143 | 48.176 | 17.08 | 6828544 |
| current / 1000 / 100000 | 0.432 | 0.877 | 0.382 | 4.685 | 0.998 | 0.711 | 0.159 / 0.135 | 37.486 | 21.12 | 13668544 |
| current / 10000 / 100000 | 0.964 | 0.905 | 0.649 | 8.532 | 5.931 | 0.748 | 0.147 / 0.126 | 46.797 | 17.76 | 13668544 |
| current / 1000 / 1000000 | 0.438 | 0.886 | 0.388 | 4.691 | 1.029 | 0.717 | 0.149 / 0.127 | 36.864 | 19.68 | 82068544 |
| current / 10000 / 1000000 | 0.977 | 0.948 | 0.680 | 9.279 | 6.031 | 0.749 | 0.159 / 0.134 | 50.654 | 15.12 | 82068544 |

GPU medians are matched timestamp pairs. DrawnFPS/1%low/framep50p95p99 measure actual rendered frames including redraws while waiting for async completion, not full-game FPS. The completed-throughput field uses sample count divided by entire measured wall interval including timestamp-collection frames; the p50 reciprocal is separately named. Normal telemetry is suppressed during sampling; initial/final small tables and4-byte batch fences are used. No full-pool read occurs in timing.

Counters are disabled/null equally for primary comparison. Optional counters elsewhere cover particle pairs and big-contact paths, not every wall/territoryDDA/shield/core query. Driver-internal CPU blocked time and physicalVRAM residency are unmeasured. Async completion includes scheduling; allocation bytes are application-requested buffers/textures, not physicalVRAM.

Exact fixture original, SHA256, both versions source hashes/Git metadata, CPUquota/throttling, commands, initial/final states and every sample remain in comparison.json, the fixture source and raw logs/JSON. Historicalb879 and olderfixture groups remain separate and are not spliced into this comparison.

