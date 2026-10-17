# F80 checkpoint: matched default-speed capacity matrix

Godot4.6.3 Forward+/software Vulkan llvmpipe LLVM19.1.7 (256bits), affinity0–3/LP_NUM_THREADS4/4CPU quota,512territory/768render. Not RTX5060Ti results. Shaderf80b/host73988, exact integer ledger, fixture schema3; full measured-wall throughput retains version2definition. Source and both execution-tool hashes stayed unchanged; actual exits0 and no engine errors.

Original1.4.3 and current each6PASS,60measured+10warm-up batches, same fixture original/initial layout, normalized(30,17)×140 velocity, same fixed step and2substeps. All particles team0, all territory team0, guns paused and three enemy cores dead. Actual particle counts/energy remain exactly the requested population. Mechanical corrections may alter later trajectories; capacity scaling within each version is the strongest empty-slot evidence.

| Active | Capacity | Old GPU p50 /p95 ms | F80 GPU p50 /p95 ms | Old drawn FPS /1%low | F80 drawn FPS /1%low | F80 steps/full wall second |
|---:|---:|---:|---:|---:|---:|---:|
| 1000 | 10000 | 19.167 /24.382 | 21.198 /40.209 | 49.19 /19.45 | 49.48 /9.16 | 16.22 |
| 10000 | 10000 | 30.648 /70.701 | 34.414 /40.788 | 42.52 /5.93 | 44.41 /10.27 | 14.80 |
| 1000 | 100000 | 25.698 /26.689 | 20.391 /22.152 | 52.56 /22.62 | 54.89 /24.57 | 18.30 |
| 10000 | 100000 | 36.732 /39.034 | 34.208 /41.268 | 45.16 /17.83 | 43.41 /15.54 | 14.47 |
| 1000 | 1000000 | 100.029 /230.578 | 20.471 /23.445 | 17.69 /2.10 | 63.37 /23.29 | 21.12 |
| 10000 | 1000000 | 105.766 /111.379 | 34.014 /37.131 | 21.67 /7.47 | 48.19 /19.67 | 16.06 |

At1000active, old GPU median rises19.17→100.03ms for10k→1Mmaximum capacity; current stays20.39–21.20ms. At10000active, old30.65→105.77ms versus current34.01–34.41ms. This removes the dominant capacity-linear empty work, not allocation memory or all cache/scheduler effects. New accurate mechanics cost more at small capacity; no universal speedup is claimed. Current normal indirect groups remain16/157for1k/10klive, independent of capacity.

Whole effective configuration dictionaries are not key-identical. Old lacks growth_curve_time, gun_discharge_duration and sniper_split_angle; current removes particle_cost_delay and particle_cost_growth. This no-gun/no-sniper/no-big/own-territory fixture does not use those fields. Relevant emission-off state, geometry, initial particle data, step, render size and collision toggle match.

Drawn FPS/1%low are actual synthetic fixture frame rates, including redraws while waiting for asynchronous completion and timestamp collection, not full-game FPS. Large low-frame outliers are retained. GPU stages use matched timestamps; driver-internal CPU blocked time and physicalVRAM residency are unmeasured. Allocation bytes are requested buffers/textures. Primary counters are disabled/null; optional profiling covers particle-pair/big paths, not every wall, DDA, shield or core query. Exact original fixtures/tools, commands, SHA256, actual initial/final states, all samples and CPU quota/throttling remain beside these reports.
