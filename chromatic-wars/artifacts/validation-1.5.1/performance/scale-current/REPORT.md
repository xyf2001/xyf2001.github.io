# F80 checkpoint: actual scale matrix

Godot4.6.3 Forward+/software Vulkan llvmpipe LLVM19.1.7 (256bits), affinity0–3/LP_NUM_THREADS4/4CPU quota,512territory/768render. Not RTX5060Ti results. Shaderf80b/host73988, exact integer ledger, fixture schema3; full measured-wall throughput retains version2definition. Source and both execution-tool hashes stayed unchanged; actual exits0 and no engine errors.

13PASS,120measured+10warm-up batches/case. Each batch is one1/120simulation-second fixed step and regular output render, normally2GPU substeps; the configured2000-speed sniper scenario uses6. Uniform velocity is(30,17), speed34.48; separate uniform140 results cover default particle speed.

| Scene | Input→final active | Capacity | GPU p50 / p95 ms | Drawn FPS /1%low | Frame p95 ms | Completed steps/full wall second | Allocated bytes |
|---|---:|---:|---:|---:|---:|---:|---:|
| uniform | 1000→1000 | 10000 | 20.886 /70.591 | 44.44 /4.80 | 48.48 | 14.61 | 6828672 |
| uniform | 10000→10000 | 10000 | 34.055 /92.834 | 35.26 /4.19 | 65.45 | 11.75 | 6828672 |
| uniform | 1000→1000 | 100000 | 20.416 /84.049 | 48.66 /4.57 | 37.82 | 16.18 | 13668672 |
| uniform | 10000→10000 | 100000 | 32.240 /48.783 | 44.62 /6.85 | 47.98 | 14.83 | 13668672 |
| uniform | 1000→1000 | 1000000 | 20.052 /25.131 | 60.08 /21.81 | 35.28 | 19.81 | 82068672 |
| uniform | 10000→10000 | 1000000 | 33.185 /70.015 | 39.90 /4.59 | 50.46 | 13.30 | 82068672 |
| uniform | 5000→5000 | 10000 | 25.527 /43.785 | 47.94 /5.57 | 40.85 | 15.93 | 6828672 |
| uniform | 30000→30000 | 30000 | 66.467 /113.438 | 27.41 /3.32 | 85.22 | 9.14 | 8348672 |
| uniform | 50000→50000 | 50000 | 106.714 /233.536 | 18.01 /2.27 | 139.47 | 6.00 | 9868672 |
| uniform | 100000→100000 | 100000 | 238.246 /341.338 | 9.65 /0.95 | 267.13 | 3.22 | 13668672 |
| dense_crossing | 1000→1 | 10000 | 20.284 /25.106 | 61.93 /25.92 | 32.59 | 20.59 | 6828672 |
| fast_sniper | 1000→0 | 10000 | 36.295 /44.839 | 44.22 /15.90 | 54.49 | 14.74 | 6828672 |
| four_storm | 1000→5270 | 10000 | 38.324 /46.713 | 42.37 /11.45 | 54.49 | 14.12 | 6828672 |

Original dense_crossing and fast_sniper populations largely expire during warm-up; these rows validate evolution/integer accounting rather than sustained peaks. The separate reloaded peak pulses require real nonempty collisions/deaths or wall splits on every measured pulse. Four-storm initial particles plus output energy are reconciled without equating initial/final population.

| Scene / input / cap | Motion2 ms | Space reset3 ms | Space build4 ms | Pair5 ms | Serial6 ms | Maintenance11+12 ms | CPU enqueue / RT submit ms | Completion fence wall ms |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| uniform /1000 /10000 | 0.443 | 0.920 | 0.405 | 4.843 | 1.280 | 0.745 | 0.160 /0.134 | 41.215 |
| uniform /10000 /10000 | 0.966 | 0.914 | 0.711 | 8.957 | 8.225 | 0.804 | 0.176 /0.147 | 55.011 |
| uniform /1000 /100000 | 0.435 | 0.904 | 0.393 | 4.772 | 1.261 | 0.728 | 0.157 /0.134 | 37.397 |
| uniform /10000 /100000 | 0.935 | 0.881 | 0.687 | 8.566 | 8.110 | 0.776 | 0.161 /0.136 | 50.672 |
| uniform /1000 /1000000 | 0.413 | 0.873 | 0.387 | 4.644 | 1.232 | 0.715 | 0.150 /0.129 | 38.087 |
| uniform /10000 /1000000 | 0.975 | 0.894 | 0.685 | 8.882 | 8.085 | 0.793 | 0.173 /0.145 | 52.219 |
| uniform /5000 /10000 | 0.652 | 0.892 | 0.507 | 6.146 | 4.332 | 0.749 | 0.164 /0.136 | 43.280 |
| uniform /30000 /30000 | 2.086 | 0.941 | 1.308 | 24.145 | 23.293 | 0.818 | 0.174 /0.146 | 85.724 |
| uniform /50000 /50000 | 3.302 | 0.941 | 1.966 | 45.368 | 39.075 | 0.833 | 0.191 /0.159 | 129.812 |
| uniform /100000 /100000 | 6.058 | 0.910 | 3.488 | 133.145 | 75.705 | 0.872 | 0.193 /0.161 | 261.570 |
| dense_crossing /1000 /10000 | 0.359 | 0.880 | 0.347 | 4.131 | 0.379 | 0.692 | 0.154 /0.134 | 37.285 |
| fast_sniper /1000 /10000 | 1.078 | 2.650 | 1.000 | 12.272 | 1.060 | 2.127 | 0.346 /0.320 | 53.505 |
| four_storm /1000 /10000 | 0.684 | 0.846 | 0.604 | 15.713 | 5.487 | 0.757 | 0.179 /0.151 | 56.687 |

This f80checkpoint includes actual mechanical CCD corrections and new high-energy rules; earlier cost-rule data is not a pure optimization baseline. A subsequent exact full-own-territory guard may be compared separately without replacing these measurements.

Drawn FPS/1%low are actual synthetic fixture frame rates, including redraws while waiting for asynchronous completion and timestamp collection, not full-game FPS. Large low-frame outliers are retained. GPU stages use matched timestamps; driver-internal CPU blocked time and physicalVRAM residency are unmeasured. Allocation bytes are requested buffers/textures. Primary counters are disabled/null; optional profiling covers particle-pair/big paths, not every wall, DDA, shield or core query. Exact original fixtures/tools, commands, SHA256, actual initial/final states, all samples and CPU quota/throttling remain beside these reports.
