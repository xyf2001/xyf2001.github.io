# Same-rules bounded-work optimization comparison

Actual **26 PASS / 0 FAIL**, both process exits 0; 13 cases per version, 120 measured batches and 10 excluded warm-up batches per case. Here the wrapper label `baseline` means the frozen **intermediate 1.5.0** at `/workspace/chromatic-intermediate-1.5.0`, not original 1.4.3. Current differs by bounded no-op-work guards; physics rules are unchanged. The independent original-1.4.3 capacity comparison is in `performance-final-default-speed`.

Hardware is **software Vulkan llvmpipe LLVM 19.1.7, 256 bits**, Godot 4.6.3 Forward+, Xvfb, CPU affinity 0–3 / 4 llvmpipe threads / 4 CPU quota. No RTX 5060 Ti performance claim. Terrain512/render768, seed20261016, exact energy, friendly physical collisions on, auto gun off, identical fixed-step and initial fixture.

Uniform velocity is (30,17), magnitude34.48; all active particles remain live and energy1, team0, three enemy cores dead. This steady workload isolates maximum-capacity and active-count costs. Dense crossing, high-speed sniper and four-way storm are evolving functional scenes: the original warm-up leaves dense crossing with2 particles and sniper with0; their timing is not evidence about peak death/compaction cost. A separate reset-per-pulse benchmark provides that evidence.

## Completed case timings

GPU TOTAL p50 is matched per-batch timestamps. Actual drawn FPS includes rendered frames while the fixture waits for asynchronous completion and is not full-game FPS. The 1% low uses the mean slowest1% drawn-frame intervals. Actual completed fixed steps/s below equals measured sample count divided by the entire measured wall interval, including extra tag-collection frames. The legacy raw field `completed_fixed_steps_per_wall_second` is instead the reciprocal of median batch wall time; it must not be confused with this actual throughput.

| Scene / active / capacity | Initial→final active (intermediate / final) | GPU p50 ms intermediate→final | Drawn FPS / 1% low intermediate | Drawn FPS / 1% low final | Actual completed steps/s intermediate→final |
|---|---:|---:|---:|---:|---:|
| uniform / 1000 / 10000 | 1000→1000 / 1000 | 20.40→19.94 | 57.6 / 22.4 | 61.0 / 20.1 | 19.05→20.33 |
| uniform / 10000 / 10000 | 10000→10000 / 10000 | 33.78→30.91 | 38.7 / 4.3 | 35.8 / 5.0 | 12.90→11.91 |
| uniform / 1000 / 100000 | 1000→1000 / 1000 | 20.66→20.91 | 48.2 / 6.1 | 43.0 / 3.8 | 15.84→14.24 |
| uniform / 10000 / 100000 | 10000→10000 / 10000 | 33.69→31.27 | 38.8 / 4.0 | 36.8 / 4.7 | 12.93→12.26 |
| uniform / 1000 / 1000000 | 1000→1000 / 1000 | 20.61→20.34 | 54.2 / 9.3 | 51.7 / 7.8 | 17.96→17.23 |
| uniform / 10000 / 1000000 | 10000→10000 / 10000 | 33.29→30.11 | 47.1 / 17.2 | 48.6 / 12.7 | 15.65→16.14 |
| uniform / 5000 / 10000 | 5000→5000 / 5000 | 26.25→24.56 | 52.0 / 19.3 | 54.6 / 21.5 | 17.29→18.16 |
| uniform / 30000 / 30000 | 30000→30000 / 30000 | 66.97→57.26 | 23.8 / 2.9 | 30.1 / 4.3 | 7.92→10.02 |
| uniform / 50000 / 50000 | 50000→50000 / 50000 | 104.03→86.12 | 19.6 / 2.2 | 23.1 / 3.2 | 6.52→7.70 |
| uniform / 100000 / 100000 | 100000→100000 / 100000 | 223.38→203.78 | 10.1 / 1.1 | 7.9 / 1.0 | 3.35→2.62 |
| dense_crossing / 1000 / 10000 | 1000→2 / 2 | 20.07→21.61 | 47.6 / 3.9 | 35.4 / 3.4 | 15.70→11.71 |
| fast_sniper / 1000 / 10000 | 1000→0 / 0 | 36.67→38.85 | 39.1 / 5.6 | 30.3 / 3.5 | 13.04→10.11 |
| four_storm / 1000 / 10000 | 1000→5270 / 5270 | 40.10→37.55 | 40.8 / 13.8 | 31.6 / 3.3 | 13.61→10.52 |

The empty serial-event scans show a measurable reduction at meaningful steady active counts: for10,000 active /10,000capacity, serial events drop8.96→5.83ms and maintenance mode12 .737→.418ms. At100,000 steady active, the same passes drop84.18→55.82ms and3.129→.522ms. Other stages, rendering and host scheduling remain present; low active scenes show little benefit. These are observations on this software backend, not a forecast for a hardware GPU.

## Stage, host and allocation detail

| Version / active / cap | Motion ms | Spatial reset ms | Spatial build ms | Colored contacts ms | Events ms | Pool maintenance11+12 ms | CPU enqueue / RT submit p50 ms | Async completion wait p50 ms | Frame p50 / p95 ms | Allocated bytes |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| intermediate / 1000 / 10000 | 0.419 | 0.902 | 0.390 | 4.605 | 1.338 | 0.762 | 0.156 / 0.131 | 40.003 | 10.12 / 35.60 | 6828544 |
| intermediate / 10000 / 10000 | 0.965 | 0.914 | 0.670 | 8.184 | 8.961 | 1.094 | 0.164 / 0.136 | 52.507 | 9.49 / 52.20 | 6828544 |
| intermediate / 1000 / 100000 | 0.428 | 0.883 | 0.395 | 4.640 | 1.356 | 0.763 | 0.158 / 0.134 | 40.621 | 10.39 / 42.72 | 13668544 |
| intermediate / 10000 / 100000 | 0.985 | 0.900 | 0.662 | 8.307 | 8.921 | 1.085 | 0.171 / 0.142 | 52.629 | 9.53 / 52.28 | 13668544 |
| intermediate / 1000 / 1000000 | 0.425 | 0.906 | 0.382 | 4.640 | 1.343 | 0.756 | 0.169 / 0.142 | 38.433 | 9.13 / 36.48 | 82068544 |
| intermediate / 10000 / 1000000 | 1.004 | 0.894 | 0.661 | 8.132 | 8.837 | 1.088 | 0.168 / 0.142 | 51.358 | 9.16 / 49.70 | 82068544 |
| intermediate / 5000 / 10000 | 0.696 | 0.882 | 0.515 | 5.978 | 4.692 | 0.932 | 0.167 / 0.142 | 44.956 | 9.67 / 41.28 | 6828544 |
| intermediate / 30000 / 30000 | 2.210 | 0.913 | 1.277 | 20.992 | 25.563 | 1.666 | 0.184 / 0.154 | 91.067 | 13.43 / 109.45 | 8348544 |
| intermediate / 50000 / 50000 | 3.414 | 0.923 | 1.883 | 37.666 | 42.039 | 2.200 | 0.188 / 0.156 | 126.971 | 11.99 / 126.25 | 9868544 |
| intermediate / 100000 / 100000 | 6.421 | 0.951 | 3.410 | 106.601 | 84.176 | 3.504 | 0.191 / 0.159 | 251.100 | 15.01 / 250.11 | 13668544 |
| final / 1000 / 10000 | 0.432 | 0.895 | 0.393 | 4.591 | 1.016 | 0.736 | 0.153 / 0.129 | 37.447 | 8.92 / 33.69 | 6828544 |
| final / 10000 / 10000 | 1.016 | 0.932 | 0.688 | 8.523 | 5.825 | 0.769 | 0.174 / 0.143 | 52.312 | 12.10 / 72.42 | 6828544 |
| final / 1000 / 100000 | 0.442 | 0.901 | 0.402 | 4.697 | 1.045 | 0.744 | 0.167 / 0.140 | 39.085 | 10.38 / 65.94 | 13668544 |
| final / 10000 / 100000 | 1.020 | 0.947 | 0.689 | 8.536 | 5.911 | 0.809 | 0.178 / 0.148 | 52.553 | 12.77 / 68.91 | 13668544 |
| final / 1000 / 1000000 | 0.426 | 0.908 | 0.408 | 4.678 | 1.031 | 0.740 | 0.154 / 0.132 | 37.732 | 9.08 / 37.73 | 82068544 |
| final / 10000 / 1000000 | 0.991 | 0.911 | 0.662 | 8.252 | 5.786 | 0.777 | 0.159 / 0.135 | 48.120 | 9.36 / 44.93 | 82068544 |
| final / 5000 / 10000 | 0.666 | 0.898 | 0.519 | 6.051 | 3.171 | 0.751 | 0.163 / 0.139 | 42.669 | 9.28 / 38.30 | 6828544 |
| final / 30000 / 30000 | 2.225 | 0.946 | 1.300 | 21.500 | 16.303 | 0.817 | 0.184 / 0.154 | 76.573 | 9.85 / 74.94 | 8348544 |
| final / 50000 / 50000 | 3.446 | 0.934 | 1.895 | 37.565 | 26.754 | 0.805 | 0.185 / 0.154 | 106.044 | 9.81 / 107.61 | 9868544 |
| final / 100000 / 100000 | 6.945 | 1.060 | 3.737 | 115.253 | 55.822 | 0.921 | 0.212 / 0.176 | 236.291 | 20.49 / 603.32 | 13668544 |

All cases validated integer energy conservation and overflow0. Candidate/contact instrumentation is disabled for primary comparison (null, not zero). Optional counters cover particle-pair and big contacts including sniper-kind-big, not every wall/terrain-DDA/shield/core query. Statistics are initial/final only; each batch uses4-byte asynchronous fence read; no full particle-pool read occurs during timing. GPU substeps=2 per normal step,6 in2000-speed sniper. Physical VRAM residency and driver-internal CPU blocked time are unmeasured; allocation bytes are requested buffers/textures, and async completion wait includes frame scheduling.

`validation_matrix_fixture.gd` is the actual fixture source. `comparison.json` includes its SHA256, game-source hashes before/after, Git metadata if available, cgroup quota/statistics, affinity and invocation. Both versions retained unchanged source hashes. Raw logs and per-sample JSON are preserved. No previous slower or failed evidence is overwritten.

