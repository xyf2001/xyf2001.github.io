# Final supplementary sustained-peak profiling

Actual3PASS/0FAIL, process exit0, frozenShader6e7eda9f/host37e131f9 unchanged.12measured+3warm-up reset pulses per scene; counters enabled only for this supplementary group.

| Scene / input live | Candidate delta per measured pulse | Contact delta per measured pulse | Final live range | GPU TOTAL p50 ms |
|---|---:|---:|---:|---:|
| dense_pulse / 1000 | 7314–7508 | 515–540 | 6–6 | 19.133 |
| dense_pulse / 5000 | 121776–122509 | 3490–3616 | 14–15 | 35.823 |
| sniper_wall_pulse / 1000 | 0–0 | 0–0 | 2000–2000 | 57.473 |

Each measured pulse independently reloads the stated live population and energy, then executes real GPU physics. Every pulse met exact remaining+consumed=input, no overflow, positive real dense-pair contacts/death or exactly1000wall-split events as appropriate. Sniper pulses end2000live/100000energy/0consumed despite zero particle-pair counters because the counters do not cover wall contact paths. No scene is measured only after its population has died.

Counter scope is instrumented particle pairs and big contacts, including sniper-kind-big; wall, territoryDDA, shield and core query counts are not comprehensive. GPU TOTAL excludes reset uploads and pre/poststatistics probes, and mode7probe tags are excluded. Synthetic FPS includes reset/probes and cannot be presented as normal-game FPS. Timings here include counter atomics and are not substituted for primary profiling=false results. Software Vulkan llvmpipe LLVM19.1.7/256bits, affinity0–3/LP4/4CPUquota,512terrain/768render/cap10000. No RTX5060Ti or physicalVRAM claim. Current70/30integer implementation is exercised; requested semantic object remains pending clarification.
