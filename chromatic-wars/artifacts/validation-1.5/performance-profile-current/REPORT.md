# Optional current counters (separate from primary timing)

Actual13PASS/0FAIL/exit0 with counters enabled,12 measured batches plus3warm-up batches per case. Counter deltas cover all15 fixed steps, not just the12 measured batches. These instrumentation-enabled times are not substituted for the profiling-disabled matched comparison. Backend is llvmpipe software Vulkan, not RTX5060Ti.

| Scene | Initial active / maximum capacity | Final active | Candidates over15steps | Confirmed contacts over15steps |
|---|---:|---:|---:|---:|
| uniform | 1000 / 10000 | 1000 | 0 | 0 |
| uniform | 10000 / 10000 | 10000 | 730154 | 0 |
| uniform | 1000 / 100000 | 1000 | 0 | 0 |
| uniform | 10000 / 100000 | 10000 | 730154 | 0 |
| uniform | 1000 / 1000000 | 1000 | 0 | 0 |
| uniform | 10000 / 1000000 | 10000 | 730154 | 0 |
| uniform | 5000 / 10000 | 5000 | 69489 | 0 |
| uniform | 30000 / 30000 | 30000 | 6878208 | 172 |
| uniform | 50000 / 50000 | 50000 | 19979503 | 446 |
| uniform | 100000 / 100000 | 100000 | 78646099 | 5040 |
| dense_crossing | 1000 / 10000 | 48 | 24640 | 21 |
| fast_sniper | 1000 / 10000 | 0 | 0 | 0 |
| four_storm | 1000 / 10000 | 2824 | 1170803 | 68314 |

Candidates/confirmed contacts cover particle pairs and big-contact paths (including sniper-kind-big), not every wall, territoryDDA, shield or core geometric query. Zero for the fast-sniper particle-pair counter does not mean zero wall contacts. Normal scenes execute2substeps/fixedstep;2000-speed sniper6substeps. Low early uniform contact counts are genuine at this short15-step interval and must not be compared as though this were the130-step primary run.

The100k scene still executes many spatial candidates relative to confirmed contacts. The optimized finite-neighborhood queries preserve all required collisions; dense active-work cost remains a limitation, and no unmeasured hardware speedup is claimed. Raw per-batch times, CPU submit, wait and allocation data remain in JSON; physical VRAM/driver blocked time remain unmeasured. All source hashes remained unchanged.
