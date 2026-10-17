# F80 checkpoint: optional scale counters

Godot4.6.3 Forward+/software Vulkan llvmpipe LLVM19.1.7 (256bits), affinity0–3/LP_NUM_THREADS4/4CPU quota,512territory/768render. Not RTX5060Ti results. Shaderf80b/host73988, exact integer ledger, fixture schema3; full measured-wall throughput retains version2definition. Source and both execution-tool hashes stayed unchanged; actual exits0 and no engine errors.

13PASS,12measured+3warm-up batches. Counter deltas cover all15steps; GPU medians use only12measured. Extra atomics make these supplementary diagnostics, not primary comparison timings.

| Scene / input / cap | Candidate delta | Pair/big contact delta | GPU p50 ms |
|---|---:|---:|---:|
| uniform /1000 /10000 | 0 | 0 | 20.445 |
| uniform /10000 /10000 | 730154 | 0 | 33.089 |
| uniform /1000 /100000 | 0 | 0 | 21.070 |
| uniform /10000 /100000 | 730154 | 0 | 33.327 |
| uniform /1000 /1000000 | 0 | 0 | 21.572 |
| uniform /10000 /1000000 | 730154 | 0 | 33.475 |
| uniform /5000 /10000 | 69489 | 0 | 26.028 |
| uniform /30000 /30000 | 6878208 | 172 | 69.950 |
| uniform /50000 /50000 | 19979503 | 446 | 111.728 |
| uniform /100000 /100000 | 78646099 | 5040 | 263.225 |
| dense_crossing /1000 /10000 | 24101 | 33 | 20.766 |
| fast_sniper /1000 /10000 | 0 | 0 | 37.446 |
| four_storm /1000 /10000 | 1171960 | 71352 | 33.445 |

Drawn FPS/1%low are actual synthetic fixture frame rates, including redraws while waiting for asynchronous completion and timestamp collection, not full-game FPS. Large low-frame outliers are retained. GPU stages use matched timestamps; driver-internal CPU blocked time and physicalVRAM residency are unmeasured. Allocation bytes are requested buffers/textures. Primary counters are disabled/null; optional profiling covers particle-pair/big paths, not every wall, DDA, shield or core query. Exact original fixtures/tools, commands, SHA256, actual initial/final states, all samples and CPU quota/throttling remain beside these reports.
