# Performance

Measured 2026-11-09 on an M4 MacBook Air (24 GB), macOS 27.2, release build, both lanes on,
Parakeet Unified 0.6B (640 ms), `top` over 3 s. CPU is percent of one core.

| State | CPU | Memory |
|---|---|---|
| Loaded, not listening | 0–1.5% | 35 MB |
| Listening, headphones (echo cancellation off), silence | ~6% | 70 MB |
| Listening, headphones, continuous speech, bar shown | ~14% | 75 MB |
| Listening, speakers (echo cancellation on), silence | ~33% | 100 MB |
| Recording bar (its share of the above) | ~3% | — |
| Engines alone, two streams of continuous speech (CLI) | 1.5–2.5% | 65 MB |

Where it goes:

- **Apple voice processing (echo cancellation) ≈ 25%.** Intrinsic to the system AU; nothing in
  hearsay's code. That is why it is only enabled while the output is a loudspeaker
  (`EchoCancellation.auto`, see `MicCapture.swift`).
- **Speech models ≈ 1% per stream.** The encoder runs on the Neural Engine; the decoder on CPU.
  Streaming encoders process audio continuously, so silence costs about the same as speech for
  the mic lane; the system-audio lane is free while no app plays sound.
- **Recording bar ≈ 3%.** The waveform is an `NSView` that redraws itself 20×/s and the status dot
  is a `CABasicAnimation`; neither goes through SwiftUI. Earlier versions did (a `Canvas` driven
  by `@Published` and a `repeatForever` SwiftUI animation) and cost ~12%: every tick re-ran the
  window's constraint layout and SwiftUI recomputed the draggable regions of the
  movable-by-background panel on every frame.
- **Avoid on the main thread:** `SMAppService.status` is an XPC round trip (~100 ms blocked);
  `AppDelegate.refresh()` caches it for 5 s.

How to measure: `open --env HEARSAY_AUTOSTART=1 build/hearsay.app`, then
`top -l 2 -s 3 -pid $(pgrep -x hearsay) -stats cpu,mem | tail -1`, and `ps -M <pid>` for the
per-thread split (the 25% voice-processing thread runs at priority 97). `sample <pid> 4` shows
where the main thread goes. Engines alone: `hearsay --transcribe a.wav --realtime --two b.wav`.
