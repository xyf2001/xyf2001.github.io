# F80 checkpoint: optional peak counters

Godot4.6.3 Forward+/software Vulkan llvmpipe LLVM19.1.7 (256bits), affinity0–3/LP_NUM_THREADS4/4CPU quota,512territory/768render. Not RTX5060Ti results. Shaderf80b/host73988, exact integer ledger, fixture schema3; full measured-wall throughput retains version2definition. Source and both execution-tool hashes stayed unchanged; actual exits0 and no engine errors.

3PASS,12measured+3warm-up reset pulses/case. Every pulse reloads its stated live input and executes production Compute; all measured pulses pass exact input=remaining+consumed plus nonempty shape checks. This is current-rule throughput/validation, not a percentage comparison with obsolete cost-rule peaks.

| Scene / live input | GPU p50 /p95 ms | Final active range | Consumed energy range | Drawn FPS /1%low |
|---|---:|---:|---:|---:|
| dense_pulse /1000 | 20.047 /20.991 | 72–72 | 92900–92900 | 72.71 /26.29 |
| dense_pulse /5000 | 39.682 /42.644 | 187–193 | 481102–481694 | 61.14 /16.55 |
| sniper_wall_pulse /1000 | 55.764 /68.352 | 2000–2000 | 0–0 | 59.05 /12.75 |

Dense pulses use48×48units, four factions,100energy per particle moving inward140; intentional overlap causes actual contact/death every pulse. Their survivor/damage ranges vary with parallel contact ordering and subsequent1Eterrain claims. Sniper pulses use1000E100wall shots at2000speed/6substeps; every pulse ends2000live/100000energy/0consumed and1000real split events. GPU TOTAL excludes reset uploads and pre/post-statistics probes; mode7probe tags are excluded. Synthetic wall/FPS include reset and probes.

| Scene / input | Candidate delta per measured pulse | Pair/big contact delta per measured pulse |
|---|---:|---:|
| dense_pulse /1000 | 8019–8037 | 586–586 |
| dense_pulse /5000 | 125056–126499 | 3610–3737 |
| sniper_wall_pulse /1000 | 0–0 | 0–0 |

Zero sniper pair counters coexist with1000real wall split events: wall queries are outside counter scope. Optional atomic profiling timings are not substituted into primary comparisons.

Drawn FPS/1%low are actual synthetic fixture frame rates, including redraws while waiting for asynchronous completion and timestamp collection, not full-game FPS. Large low-frame outliers are retained. GPU stages use matched timestamps; driver-internal CPU blocked time and physicalVRAM residency are unmeasured. Allocation bytes are requested buffers/textures. Primary counters are disabled/null; optional profiling covers particle-pair/big paths, not every wall, DDA, shield or core query. Exact original fixtures/tools, commands, SHA256, actual initial/final states, all samples and CPU quota/throttling remain beside these reports.
