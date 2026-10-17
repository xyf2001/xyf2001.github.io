# Optional nonempty peak-pulse counters

Actual3PASS/0FAIL/exit0;12 measured pulses plus3warmup each. Every pulse resets physical state and independently validates integer energy and shape. Counters below describe each measured pulse, excluding reset/statistics probes. Software Vulkan llvmpipe, not RTX5060Ti; times and synthetic drawn FPS with counters enabled are not primary performance-comparison data.

| Scenario | Initial active | Final active range | Candidate range/pulse | Confirmed contact range/pulse | Consumed energy range/pulse |
|---|---:|---:|---:|---:|---:|
| dense_pulse | 1000 | 6 | 7489–7508 | 540 | 99400 |
| dense_pulse | 5000 | 14–15 | 121763–122408 | 3481–3616 | 498500–498600 |
| sniper_wall_pulse | 1000 | 2000 | 0 | 0 | 0 |

Dense5000 pulses intentionally contain many overlapping physical contacts. Their final counts/ordering can vary; all measured pulses preserve exact total energy and show real entity removal. The sniper pulse has1000right-wall contacts and1000verified70/30splits, but0in this particle-pair/big counter because walls are outside its scope. Zero is not evidence of no physical interaction.

Full reset uploads and pre/post small-table probes are outside GPU TOTAL. Drawn FPS/wall times include those reset/probe costs and are labelled synthetic in raw JSON. Exact parent/peak fixture sources and both SHA256 are preserved; source hashes remain unchanged.
