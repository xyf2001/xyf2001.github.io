# Final CD0.5 / generation — current-only scale matrix

Actual13PASS/0FAIL, process exit0, no engine errors and unchanged source SHA256. Shader6e7eda9ff084d4971432c838ffe8a042d0abcf5ef23d2a21f1c3688feeedc173; GPUWorld37e131f9bc9ce863aae8a6851fe263346e26ba43f06e7062aa99f6b01554bd3d.120measured batches+10excluded warm-up per case; this is a final-only measurement, not a percentage comparison against differently configured historical fixtures.

Backend: llvmpipe LLVM19.1.7/256bit software Vulkan, Godot4.6.3 Forward+, Xvfb, CPU affinity0–3, LP_NUM_THREADS4 and4CPU quota. Not RTX5060Ti.512terrain/768render, exact energy, friendly collisions on, no auto gun, explicitCD0.5 in both config and effective_config, seed20261016. Uniform uses actual(30,17) velocity/magnitude34.48; the separate matched capacity group uses140. Three enemy cores dead and team0-only uniform keep active count fixed. Synthetic direct initialization can fill all declared slots; it does not assert a natural spawning distribution.

| Scene / initial active / capacity | Final active | GPU TOTAL p50 / p95 ms | Actual drawn FPS / 1%low | Drawn frame p50 / p95 ms | Completed fixed steps / full wall second | Substeps / fixed step | Allocated bytes |
|---|---:|---:|---:|---:|---:|---:|---:|
| uniform / 1000 / 10000 | 1000 | 20.495 / 50.285 | 47.68 / 5.26 | 10.76 / 38.99 | 15.76 | 2 | 6828544 |
| uniform / 10000 / 10000 | 10000 | 30.463 / 39.154 | 49.17 / 16.59 | 9.37 / 45.56 | 16.34 | 2 | 6828544 |
| uniform / 1000 / 100000 | 1000 | 20.557 / 28.843 | 58.10 / 18.18 | 9.50 / 36.89 | 19.37 | 2 | 13668544 |
| uniform / 10000 / 100000 | 10000 | 30.555 / 92.129 | 40.55 / 3.80 | 9.57 / 46.91 | 13.52 | 2 | 13668544 |
| uniform / 1000 / 1000000 | 1000 | 21.124 / 78.347 | 41.77 / 5.97 | 11.12 / 77.55 | 13.85 | 2 | 82068544 |
| uniform / 10000 / 1000000 | 10000 | 31.158 / 83.324 | 39.42 / 5.12 | 10.06 / 76.33 | 13.14 | 2 | 82068544 |
| uniform / 5000 / 10000 | 5000 | 24.691 / 95.934 | 44.25 / 4.38 | 8.99 / 41.17 | 14.67 | 2 | 6828544 |
| uniform / 30000 / 30000 | 30000 | 57.763 / 93.314 | 29.92 / 4.55 | 10.24 / 80.21 | 9.97 | 2 | 8348544 |
| uniform / 50000 / 50000 | 50000 | 86.604 / 180.034 | 21.39 / 2.98 | 10.67 / 117.39 | 7.13 | 2 | 9868544 |
| uniform / 100000 / 100000 | 100000 | 186.228 / 196.165 | 13.57 / 4.27 | 10.17 / 205.50 | 4.52 | 2 | 13668544 |
| dense_crossing / 1000 / 10000 | 2 | 20.237 / 21.675 | 63.27 / 28.47 | 8.60 / 31.76 | 21.09 | 2 | 6828544 |
| fast_sniper / 1000 / 10000 | 0 | 36.240 / 38.487 | 45.33 / 18.28 | 8.69 / 51.57 | 15.11 | 6 | 6828544 |
| four_storm / 1000 / 10000 | 5270 | 35.977 / 41.628 | 42.26 / 15.94 | 11.61 / 52.85 | 14.09 | 2 | 6828544 |

All cases passed exact integer accounted-energy checks; uniform remained at the requested live count with unchanged total live energy. Dense/sniper/storm evolve: after warm-up the original dense scene is nearly empty, and1-energy fast snipers expire on hostile territory. These are retained functional scenes, not evidence about nonempty collision/death/split peaks. Separate reset-per-pulse tests cover those peaks.

## Stage/CPU/completion medians

| Scene / active / cap | Motion ms | Grid reset ms | Grid build ms | Colored contacts ms | Events/big ms | Maintenance11+12 ms | Enqueue / RT-submit CPU ms | Async completion wall ms |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| uniform / 1000 / 10000 | 0.443 | 0.886 | 0.399 | 4.702 | 1.028 | 0.731 | 0.170 / 0.141 | 39.480 |
| uniform / 10000 / 10000 | 0.991 | 0.915 | 0.689 | 8.428 | 5.867 | 0.753 | 0.166 / 0.139 | 49.026 |
| uniform / 1000 / 100000 | 0.433 | 0.905 | 0.405 | 4.745 | 1.040 | 0.739 | 0.157 / 0.131 | 38.987 |
| uniform / 10000 / 100000 | 0.996 | 0.907 | 0.655 | 8.319 | 5.842 | 0.784 | 0.163 / 0.137 | 48.662 |
| uniform / 1000 / 1000000 | 0.439 | 0.899 | 0.395 | 4.817 | 1.061 | 0.774 | 0.170 / 0.140 | 40.623 |
| uniform / 10000 / 1000000 | 1.011 | 0.936 | 0.683 | 8.593 | 5.904 | 0.797 | 0.169 / 0.141 | 49.037 |
| uniform / 5000 / 10000 | 0.693 | 0.897 | 0.513 | 6.136 | 3.197 | 0.754 | 0.155 / 0.132 | 42.142 |
| uniform / 30000 / 30000 | 2.237 | 0.915 | 1.303 | 21.416 | 16.442 | 0.845 | 0.181 / 0.151 | 77.703 |
| uniform / 50000 / 50000 | 3.430 | 0.913 | 1.888 | 37.900 | 27.039 | 0.819 | 0.185 / 0.153 | 106.657 |
| uniform / 100000 / 100000 | 6.458 | 0.916 | 3.406 | 105.114 | 52.496 | 0.841 | 0.190 / 0.156 | 207.256 |
| dense_crossing / 1000 / 10000 | 0.357 | 0.892 | 0.339 | 4.069 | 0.384 | 0.677 | 0.156 / 0.132 | 36.964 |
| fast_sniper / 1000 / 10000 | 1.063 | 2.659 | 1.018 | 12.284 | 1.060 | 2.075 | 0.349 / 0.320 | 53.326 |
| four_storm / 1000 / 10000 | 0.686 | 0.896 | 0.628 | 14.181 | 4.594 | 0.770 | 0.185 / 0.153 | 57.276 |

GPU times are matched unique timestamp pairs. Drawn FPS includes frames redrawn while waiting for asynchronous completion, so it is not game FPS. Actual completed fixed-step throughput now uses sample count divided by the entire measured wall interval, including extra timestamp-collection frames; the reciprocal of median batch wall time is separately namedmedian_batch_completion_rate_per_wall_second. Normal production telemetry is suppressed during samples, initial/final small state is read, and per-batch fence is4bytes; no whole-pool read occurs during measurement.

Candidate/contact counters are disabled/null for primary timing. The separate optional counters cover particle pairs and big-contact paths, not every wall, territoryDDA, shield or core geometry query. Driver-internal CPU blocked time and physical VRAM residency are unmeasured; async completion wall includes scheduling and requested allocation bytes are not measured VRAM.

Exact version2fixture source, SHA256, code hashes before/after, Git metadata, CPU quota/throttle statistics, invocation and all raw samples are retained alongside this report. Historicalb879/oldfixture data remains unchanged. A Git-only checkpoint during the run changed metadata but no recorded source bytes.

