# Final actual dense-death and sniper-split peak pulses

Intermediate1.5.0 versus finalShader6e7eda9f/host37e131f9, same two fixture originals and explicit target-switch CD0.5. Both3cases PASS, actual process exits0, all critical source SHA256 unchanged.20measured+3excluded warm-up pulses/case. This comparison checks peak execution and integer invariants, not a claim that all new gameplay rules equal the intermediate version.

Backend: Godot4.6.3 Forward+/software Vulkan llvmpipe LLVM19.1.7 (256bits), affinity0–3, LP_NUM_THREADS4,4CPU quota,512terrain/768render/capacity10000. These are not RTX5060Ti measurements.

| Scene / live input | Intermediate GPU p50 / p95 ms | Final GPU p50 / p95 ms | Intermediate / final drawn FPS | Final 1%low / frame p95 ms | Final live after each pulse | Final energy consumed per pulse |
|---|---:|---:|---:|---:|---:|---:|
| dense_pulse / 1000 | 20.591 / 24.623 | 22.531 / 26.190 | 86.66 / 63.96 | 15.42 / 36.33 | 6–6 | 99400–99400 |
| dense_pulse / 5000 | 36.557 / 40.156 | 35.900 / 38.779 | 67.83 / 69.97 | 18.36 / 45.84 | 12–15 | 498500–498800 |
| sniper_wall_pulse / 1000 | 55.233 / 61.920 | 56.411 / 61.256 | 57.09 / 57.32 | 13.08 / 69.88 | 2000–2000 | 0–0 |

Each pulse reinstalls the actual input and executes the production GPU pipeline. Dense scenes place four equal-energy factions in48×48units moving inward at140; intentional overlap produces real collisions and deaths. Each normal carries100energy. Every measured pulse had positive collision count, positive consumed energy, fewer surviving entities and exact remaining+consumed=input. Dense5000 outcomes vary between pulses because contact ordering is parallel; both versions produced12–15survivors and498500–498800consumed in this run. No single sample is presented as the outcome of every pulse.

Sniper pulses place1000energy100projectiles atx1022.7/y64…960 moving at2000 with6substeps; every pulse ended with2000live,1000split events,100000remaining and0consumed. This validates current integer conservation and actual wall-split load. The semantic object of the requested70/30 rule is still awaiting clarification; this result does not resolve that ambiguity.

There is no consistent blanket peak-speed improvement: dense1000 and wall-sniper medians are slightly higher here while dense5000 is slightly lower. No precise hardware optimization percentage is claimed. The primary capacity improvement is separately established by the steady uniform140 matched comparison.

GPU TOTAL includes only one real fixed-step production batch, its substeps and regular output rendering; reset uploads and pre/post-statistics probes are excluded, and mode7probe tags are explicitly excluded. Drawn FPS and wall durations include reset/probes/asynchronous completion and are synthetic fixture presentation rates, not full-game FPS. CPU submit/completion timings and every matched GPU stage/sample remain in raw JSON. Counters are equally disabled/null for this primary comparison; separate profiling runs use extra atomics. Pair/big contact counters do not include all wall, territoryDDA, shield or core geometry queries. Allocated resource bytes describe requested buffers/textures, not physicalVRAM.

Fixture originals andSHA256, exact process commands/exits, source SHA256 before/after, initial/final states and all measured samples are retained beside this report. Historical b879 groups remain separate.
