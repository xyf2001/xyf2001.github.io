# Same-rules nonempty collision/death/split pulses

Actual **6 PASS / 0 FAIL**, intermediate1.5.0 and final each3cases,20 measured +3warmup pulses/case, both process exits0, no engine errors, source/fixture hashes unchanged. Each pulse fully restores identical physical state before timing; all subsequent physics is actual production Compute. Every measured/warmup pulse independently passed shape and integer-energy assertions. This addresses the original continuously evolving dense/sniper cases becoming nearly empty before measurement.

Backend: **software Vulkan llvmpipe LLVM19.1.7 256bits**, Godot4.6.3 Forward+, Xvfb, CPU affinity0–3/LP_NUM_THREADS4/4CPU quota. Not RTX5060Ti performance. All cases terrain512/render768, capacity10000, same steps and full physical collision rules. Primary optional counters disabled for both versions.

| Scenario / initial active | Initial energy/pulse | First sample final active | First sample consumed / remaining energy | First sample collision metric / sniper splits | Intermediate GPU p50 / p95 ms | Final GPU p50 / p95 ms |
|---|---:|---:|---:|---:|---:|---:|
| dense_pulse / 1000 | 100000 | 6 | 99400 / 600 | 540 / 0 | 20.154 / 24.084 | 20.312 / 23.387 |
| dense_pulse / 5000 | 500000 | 14 | 498600 / 1400 | 3616 / 0 | 37.824 / 137.124 | 36.586 / 39.341 |
| sniper_wall_pulse / 1000 | 100000 | 2000 | 0 / 100000 | 0 / 1000 | 55.648 / 61.626 | 53.945 / 55.503 |

Dense pulses place4teams of100-energy ordinary particles in a48×48 square around(512,512), aiming inward at140. Initial overlaps are intentional peak-load input. A pulse must actually execute pair contacts, consume energy and reduce active count; energy-only correctness would not pass a quiet/empty fixture. All pulses satisfy the same shape and conservation requirements, but dense contact outcomes are not bit-identical. Across both primary runs,1000-density final active remains6, while5000-density final active ranges13–15 and consumed energy498500–498700. Contact counts also vary (about3423–3620 in5000-density). The table shows the first measured pulse; all per-pulse variations remain in raw JSON. This is a many-contact parallel physical workload, and no precise percentage claim relies on identical final trajectories.

Sniper pulses place1000 team0 snipers,100energy each, atx1022.7/y64..960 moving2000units/s into the right wall. SixGPU substeps execute one real wall contact per initial sniper, then70/30 children continue. A pulse must end with2000active,1000split events,100000remaining energy andzero energy dissipation. All prior children and big-tail slots are cleared before each reset. This reset fixture requires1.5 binding/layout interfaces and is not run against1.4.3.

## Measured stage medians (ms)

| Version / scenario / count | TOTAL | Motion | Spatial reset | Spatial build | Colored contacts | Serial events | Maintenance11+12 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| intermediate / dense_pulse / 1000 | 20.154 | 0.402 | 0.906 | 0.359 | 5.641 | 0.502 | 0.733 |
| intermediate / dense_pulse / 5000 | 37.824 | 0.521 | 0.905 | 0.473 | 22.479 | 0.674 | 0.914 |
| intermediate / sniper_wall_pulse / 1000 | 55.648 | 1.450 | 2.695 | 1.338 | 24.671 | 7.585 | 2.509 |
| final / dense_pulse / 1000 | 20.312 | 0.407 | 0.909 | 0.409 | 5.700 | 0.460 | 0.780 |
| final / dense_pulse / 5000 | 36.586 | 0.525 | 0.900 | 0.406 | 21.812 | 0.575 | 0.895 |
| final / sniper_wall_pulse / 1000 | 53.945 | 1.426 | 2.632 | 1.216 | 24.094 | 7.702 | 2.098 |

These samples did not show a marked peak-load regression from the dirty/guard optimization.20samples per case are retained with p95/raw data; small timing differences are not a precise optimization-percentage claim. These are synthetic pulses, not full-game FPS.

GPU TOTAL surrounds exactly one production fixed-step batch plus normal output rendering. Full resets, pre/post statistics, completion probes and mode7probe timestamps are outside TOTAL or explicitly excluded from stage sums. Drawn FPS and sample wall time still include resets/probes and are explicitly labelled synthetic harness rates in JSON; do not use them as game FPS. Physical VRAM residency and precise driver-internal CPU waits are unmeasured. Allocation bytes are buffers/textures requested by the application.

`comparison.json` records both actual fixture assets, SHA256 and source before/after hashes; `validation_matrix_fixture.gd` and `peak_load_validation_fixture.gd` preserve exact originals. Every raw sample contains input reset SHA, initial/final counts/energy, consumed delta, shape validity, timestamp tags and optional counter deltas. Previous matrices remain unchanged. Optional candidate/contact counters cover particle pairs and big-contact paths, not every terrain/wall/shield/core query.

