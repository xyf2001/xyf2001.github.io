# Final supplementary particle-pair profiling

Actual13PASS/0FAIL, exit0, frozenShader6e7eda9f/host37e131f9 unchanged.12measured+3warm-up batches per scene; profiling is explicitly enabled. These extra atomic counters are not used for the primary before/after timing comparisons.

| Scene | Input active | Capacity | Candidate delta | Contact delta | GPU TOTAL measured p50 ms |
|---|---:|---:|---:|---:|---:|
| uniform | 1000 | 10000 | 0 | 0 | 20.236 |
| uniform | 10000 | 10000 | 730154 | 0 | 30.836 |
| uniform | 1000 | 100000 | 0 | 0 | 20.147 |
| uniform | 10000 | 100000 | 730154 | 0 | 31.469 |
| uniform | 1000 | 1000000 | 0 | 0 | 20.118 |
| uniform | 10000 | 1000000 | 730154 | 0 | 29.644 |
| uniform | 5000 | 10000 | 69489 | 0 | 24.215 |
| uniform | 30000 | 30000 | 6878208 | 172 | 57.846 |
| uniform | 50000 | 50000 | 19979503 | 446 | 145.526 |
| uniform | 100000 | 100000 | 78646099 | 5040 | 222.458 |
| dense_crossing | 1000 | 10000 | 24640 | 21 | 20.526 |
| fast_sniper | 1000 | 10000 | 0 | 0 | 36.154 |
| four_storm | 1000 | 10000 | 1170320 | 68473 | 31.779 |

Counter deltas span all15production fixed steps including3warm-ups; GPU p50 uses only12measured batches. Counters cover instrumented particle-pair and big-contact paths (including sniper-versus-big), not every wall, territoryDDA, shield or core geometry query. A zero pair-contact count is not proof that a scene had no wall impacts. Primary profiling=false data has null/disabled counters, not zero collisions.

Uniform uses the original low-speed(30,17)fixture in this scale group; the separate matched uniform140 group validates default-speed capacity behavior. The original dense_crossing and fast_sniper inputs diminish during warm-up; sustained real death/split load is separately measured with peak pulses. No full-game FPS or physicalVRAM claim is made. Backend: software Vulkan llvmpipe LLVM19.1.7/256bits, Godot4.6.3, affinity0–3/LP4/4CPUquota,512terrain/768render. All raw samples, initial/final actual active counts and energy, stage timestamps, CPU enqueue/completion, exact fixture and source hashes are saved alongside.
