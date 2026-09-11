# Extended performance testing — September 9, 2026

The optimized builds remain responsive with short chats, but long transcripts
still cause visible pauses and substantial memory use. Midnight's cancellation
fix held up under repeated testing. Switching models exposed a separate memory
retention issue that a clean Midnight restart cleared.

Completed: **34 UI/terminal stress cases, 33 model generation trials, and five
cancellation cycles**. All cases completed their operational checks; the timing
and memory results below still identify performance problems.

## Conditions and interpretation

Tests ran on an Apple M5 Max with 64 GiB RAM and 18 logical CPUs, using the existing
release executables. Server and UI benchmarks ran separately; the two clients
were measured sequentially. All conversations, files, and terminal producers were
synthetic and isolated from saved user conversations.

UI gaps are periods without PTY output, including the beginning and end of each
measured stream. They measure observed output activity, not individual character
paint time. RSS was sampled every 500 ms and is not a lifetime maximum or proof
of a leak. These workloads are diagnostic stress cases, not universal guarantees.
The mock intentionally streams until interrupted rather than enforcing the
request's token cap; the fast and minute-long cases exceed a normal 4,096-token
response. They measure UI headroom, not that model configuration's usual output.

## History scaling

Each prior assistant reply contained 4 KiB of Markdown. Each case streamed for
12 seconds, crossing an autosave interval. There were two repetitions per history
size and client, at 180 columns × 40 rows. The target stream rate was 20 chunks/s;
actual mock timestamps are saved alongside the results.

Largest output gap observed across the two repetitions:

| Prior turns | Standard | Experimental |
| ---: | ---: | ---: |
| 0 | 0.064 s | 0.064 s |
| 40 | 0.272 s | 0.558 s |
| 120 | 0.815 s | 1.660 s |
| 240 | 1.597 s | 3.395 s |

At 240 turns, Standard took up to 2.48 seconds to persist a cancelled response;
Experimental took up to 1.50 seconds. Peak sampled RSS reached approximately
1.30 GiB and 1.71 GiB respectively. Every case completed the interrupt and the
application remained alive.

After clearing the server's retained model memory, a separate 120-turn check
still showed 0.77-second Standard and 1.61-second Experimental output gaps. There
were no swap-outs or page-outs during those checks. Long-history pauses therefore
remain reproducible with a clean server memory baseline.

## Streaming format and window size

Additional 12-second cases covered faster plain-text streams, repeated Markdown
code blocks, visible/hidden reasoning, and 80-column windows. All interrupted
successfully. The faster case targeted 100 chunks/s and actually delivered about
69–70 chunks/s; it produced roughly 74 KB of text. Maximum output gaps were
0.127 seconds Standard and 0.143 seconds Experimental.

At 40 prior turns, showing reasoning produced approximately the same largest
gap as hiding it: 0.27 seconds Standard and 0.55–0.56 seconds Experimental.
Repeated Markdown blocks produced gaps of 0.27 and 0.87 seconds respectively.
These observations do not suggest that italic reasoning itself is the dominant
latency cost.

At 120 turns and 80 columns, gaps were 0.79 seconds Standard and 0.83 seconds
Experimental. Experimental's wider-layout delay is concentrated in the initial
update: its code inspector can disappear when a new assistant response begins,
changing the width of the entire existing transcript. The narrower layout avoids
that particular inspector transition. Source inspection supports this mechanism;
the contribution of each layout pass was not separately timed.

## Model input scaling and cancellation

All 33 generation trials completed. The same short requested answer was used with
increasing synthetic reference text. GPT-OSS used low effort; LFM and Laguna used
default effort. LFM sometimes produced a longer answer instead of the requested
word, so total completion times do not represent equal output work. First-text
latency is the more useful comparison here.

With 128 KiB of reference text (approximately 21,600–23,400 actual prompt tokens),
two repetitions produced these first-text ranges:

| Model | First text |
| --- | ---: |
| GPT-OSS 20B Q4, low effort | 8.67–9.37 s |
| LFM2.5 1.2B 4-bit | 2.95 s |
| Laguna XS 2.1 Q4 | 8.21–9.21 s |

Midnight's runtime status requests completed within 2 ms in these observations,
with no polling failures. Larger inputs cause real prefill waits without making
the HTTP status endpoint unresponsive. This was not a full-context-capacity test.

Five GPT-OSS cancellation cycles all recovered. The first successful follow-up
probe started 0.108–0.112 seconds after disconnect; its answer completed within
0.704–0.760 seconds. Probes were spaced approximately 100 ms apart, so these are
observed recovery bounds rather than exact server admission timestamps.

## Embedded terminal

Four Experimental cases covered an idle or output-producing foreground process
at 80 and 180 columns, with simultaneous chat streaming. The active producer
wrote about 0.5 MB over each run (roughly 40 KB/s), and had a fixed deadline.

All chat interruptions completed within 0.071 seconds. Foreground terminal
interruptions stopped the producer within 0.043 seconds. Applications exited
cleanly and all recorded app, shell, and producer processes were gone afterward.

In the wide active-output case, 205 of 253 markers were observed on the rendered
screen; their p95 latency was 0.094 seconds and maximum was 0.114 seconds. Not all
intermediate markers are expected to survive scrolling and frame coalescing.
The narrow terminal is hidden while chat has focus, so its visible-marker data
does not cover that hidden interval.

The wide active-output case used about one CPU core on average during streaming,
with sampled app RSS around 275 MiB. The idle-output comparison used about 0.94
cores and 262 MiB. The harness used about 0.008 cores. These are single-run samples.

## Memory observations

After switching Laguna → GPT-OSS, Midnight reported 28.317 GB active memory rather
than its original 11.182 GB. It stayed elevated through 30 seconds of quiet
sampling and a normal GPT-OSS request. A later switching run ended at 30.538 GB.
A clean restart restored the original GPT-OSS model at 11.182 GB active memory.

This is active allocation, not merely a cumulative peak or recyclable allocator
cache. The MLX compiled-graph cache is a source-supported retention hypothesis:
its cache is thread-local, while compiled-function destruction erases entries
from the calling thread's cache. The exact retention path has not been isolated
in a standalone reproducer, so it is not presented as a proven root cause.

For the client, even a fresh 12-second streamed response grew RSS from roughly
56 MiB to 343 MiB while the saved conversation was only about 20 KB. Growth was
smooth through the autosave interval. SwiftTUI's text-layout cache retains up to
256 entries keyed by full text and layout options, so successive response prefixes
can retain considerably more layout data than the final answer alone. That is
a candidate explanation, not a measured accounting of every retained byte.

The one-minute, no-history soak made that growth clearer:

| Client | Final answer | Peak sampled RSS | RSS after 10 s idle | Largest output gap |
| --- | ---: | ---: | ---: | ---: |
| Standard | 92,649 bytes | 1,719 MiB | 1,719 MiB | 0.144 s |
| Experimental | 92,738 bytes | 1,727 MiB | 1,727 MiB | 0.157 s |

Both cancelled successfully, but memory did not return toward startup levels
during the idle observation. No swap-outs, page-outs, or new compressions were
recorded during any of the 14 format/width/soak cases. Retained layout data and
allocator behavior need to be separated before labeling this an unbounded leak.

The next optimization targets are memory retained for growing text layouts,
whole-history layout cost, and Experimental's inspector-related reflow. The model
switching memory retention warrants a separate backend investigation.

## Reproduction and artifacts

```sh
python3 scripts/transcript-stress.py .build/release/lowlight \
  --turns 0 40 120 240 --repeat 2 --seconds 12
python3 scripts/transcript-stress.py .build/release/lowlight \
  --turns 0 --seconds 60 --idle-after-stop 10
python3 scripts/terminal-output-stress.py \
  ../lowlight-experiments/.build/release/lowlight \
  --producer-seconds 25 --stream-seconds 12
```

The server harness is `scripts/midnight-performance.py`; model switching requires
explicit model paths and a restore path. It should be run separately from UI
timing tests. Restore uses the original model path and a 4,096-token output cap,
which matches the tested setup; it is not a general snapshot of every runtime
option.

Raw evidence is under the Standard checkout's `.build/diagnostics/`:

- `performance-expanded-ui-20260909/`: history repetitions and event/RSS timelines.
- `performance-expanded-formats-20260909/`: format, width, rate, and soak cases.
- `performance-expanded-server-20260909-complete/`: 27 trials, five cancellation
  cycles, and quiet memory snapshots.
- `performance-expanded-server-long-20260909/`: six larger-input trials and the
  clean-restart memory receipt.
- `performance-expanded-terminal-20260909.log`: embedded-terminal results and
  the temporary directory containing rendered-screen evidence.

The earlier incomplete server run was a harness error involving `stream_options`
on a non-streaming probe; it is excluded. The corrected run completed all cases.

[performance-results.json](performance-results.json) preserves the complete case
results, build hashes, hardware, paging deltas, and restart receipts alongside
this report. Test processes were cleaned up. Midnight was left ready with the
original GPT-OSS model and its normal active-memory baseline.
