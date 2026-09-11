# Responsiveness investigation — September 9, 2026

See [extended performance testing](PERFORMANCE.md) for subsequent long-history,
streaming, terminal-output, and model-memory measurements.

Three separate causes reproduced: GPT-OSS can generate silently until its output
budget runs out; Midnight failed to notice cancellation during that silence;
and debug builds of the terminal UI became slow with long transcripts.

## Model comparison

Tested local Midnight on the same Mac with a 4,096-token output limit, temperature
zero, and the same short conversation ending in “write me some python code”.
These are individual observations, not a throughput benchmark; answer lengths
and model sizes differ.

| Model / effort | Direct API completion time | Result |
| --- | ---: | --- |
| GPT-OSS 20B Q4 / default | 118.600 s | No answer; server reported empty generation |
| GPT-OSS 20B Q4 / low | 2.738 s | Complete; first answer text at 0.549 s |
| LFM2.5 1.2B 4-bit / default | 0.235 s | Complete |
| Laguna XS 2.1 Q4 / default | 2.062 s | Complete |

Both Lowlight variants completed three-turn conversations with LFM and Laguna.
Both also completed GPT-OSS conversations at low effort; Experimental was retested
after an earlier cancellation left the server busy. The original GPT-OSS model
was restored after testing. Memory settled near 11.9 GB active after switching;
these observations did not demonstrate a persistent multi-model memory leak.

For responsive everyday GPT-OSS chat, use `/effort low`. This is separate from
input/context capacity: the original screenshot's approximately 154 / 118k tokens
was nowhere near the context limit. More input is allowed. More output budget may
allow a silent reasoning turn to finish, but also allows a longer wait.

Lowlight permits ten minutes without stream data and thirty minutes per request.
`/thinking on` or Ctrl-T shows provider-supplied reasoning in muted italic text.
The tested Midnight/MLX GPT-OSS path did not expose that reasoning in its response
stream, so enabling the display cannot make those silent tokens visible.

## Cancellation

Before the server fix, closing a real TCP connection during GPT-OSS generation
left every follow-up probe rejected as `model_busy` for the entire 40-second
observation window. Lowlight itself stopped promptly; the model kept running.

Midnight's NIO HTTP pipelining assistance paused socket reads after request end.
That prevented it from observing a disconnect during silent generation. The
server now keeps reads active; its existing in-flight guard still ignores extra
pipelined requests, and responses close the connection.

The real TCP regression failed before the change at its two-second cancellation
deadline and passed afterward in 0.025 seconds. All 14 selected HTTP cancellation,
lifecycle, and decoding tests passed. After rebuilding and restarting the actual
server, the first follow-up probe at 0.511 seconds was accepted and completed at
1.157 seconds. Both clients also stopped in under 0.3 seconds and completed their
next prompt successfully.

## Long transcripts

A synthetic fixture streamed 20 chunks per second for 12 seconds, crossing the
autosave interval, with zero or 40 prior 4 KiB replies. The mock server continued
writing promptly while debug clients stalled. Profiling the Standard debug build
found most sampled main-thread time in layout and its diagnostic shadow-layout
checks, with much less in Markdown parsing. Explicit row equality alone did not
materially resolve the pauses.

The normal launch and source-install defaults now use optimized release builds;
`LOWLIGHT_BUILD_CONFIGURATION=debug ./run.sh` retains a development option.
The existing transcript layout and scroll identifiers are preserved.

| Standard, 40 prior turns | Debug | Release |
| --- | ---: | ---: |
| Send to request start | 3.301 s | 0.250 s |
| Largest observed terminal-output gap | 2.001 s | 0.383 s |
| Ctrl-C to saved stopped response | 2.302 s | 0.133 s |

| Experimental, 40 prior turns | Debug | Release |
| --- | ---: | ---: |
| Send to request start | 4.555 s | 0.292 s |
| Largest observed terminal-output gap | 4.551 s | 0.531 s |
| Ctrl-C to saved stopped response | 2.009 s | 0.087 s |

Terminal-output gaps measure writes observed by a PTY reader, not the precise
moment an answer character appears onscreen. The fixture is intentionally heavy;
optimized builds reduce these pauses but do not make transcript cost independent
of history length.

Reproduce without loading a model or touching real conversations:

```sh
swift build -c release --product lowlight
python3 scripts/transcript-stress.py .build/release/lowlight
```

## Local evidence

Paths below are relative to the Standard `lowlight` checkout.

- Model matrix: `.build/diagnostics/midnight-20260909-174525/results.json`
- Failed cancellation: `.build/diagnostics/midnight-20260909-175054/results.json`
- Fixed cancellation and Experimental follow-ups: `.build/diagnostics/midnight-20260909-180050/results.json`
- Both clients' cancellation retest: `.build/diagnostics/midnight-20260909-180203/results.json`

All API/TUI diagnostic conversations were temporary fixtures. Raw artifacts under
`.build` are local and are not included in source control.

## Deployment and checks

The normal `~/.lowlight/bin/lowlight` command now uses the tested release build;
its installed executable matches the release build's SHA-256. Experimental's
`run.sh` now selects its tested release build. Midnight was restarted through its
menu-bar app with the cancellation fix, and the original GPT-OSS model is ready.

Validation passed: 108 Standard tests, 124 Experimental tests, 14 selected Midnight
HTTP tests, Standard terminal/session/search smoke coverage, Experimental code
pane and embedded-terminal smoke coverage, and both reasoning-display checks.
Both installers also passed configuration-selection and release-install smoke
coverage, including resource copying and preservation of existing data.
