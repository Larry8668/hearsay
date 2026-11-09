# Performance

Measured 2026-11-09 on an M4 MacBook Air (24 GB), macOS 27.2, release build, both lanes on,
Parakeet Unified 0.6B (640 ms), `top` over 3 s. CPU is percent of one core.

| State | CPU | Memory |
|---|---|---|
| Loaded, not listening | 0–1.5% | 35 MB |
| Listening, headphones (echo cancellation off), silence | ~6% | 70 MB |
| Listening, headphones, continuous speech, bar shown | ~14% | 75 MB |
| Listening, speakers (echo cancellation on), silence | ~33% | 100 MB |
| Listening, echo cancellation off, two apps talking at once (two "them" streams) | ~24% | 85 MB |
| Recording bar (its share of the above) | ~3% | — |
| Engines alone, two streams of continuous speech (CLI) | 1.5–2.5% | 65 MB |

Where it goes:

- **Apple voice processing (echo cancellation) ≈ 25%.** Intrinsic to the system AU; nothing in
  hearsay's code. That is why it is only enabled while the output is a loudspeaker
  (`EchoCancellation.auto`, see `MicCapture.swift`).
- **Per-app system audio**: one process tap and one model stream per app that plays
  (`PerAppAudioTap`, `PerAppEngine`). A stream opens on an app's first voiced chunk and closes
  after 20 s without audio; silent apps forward nothing. Each app talking costs ~5% (its model
  stream, RTF 0.045) and ~20 MB; the taps themselves are negligible.
- **Speech models ≈ 1% per stream.** The encoder runs on the Neural Engine; the decoder on CPU.
  Streaming encoders process audio continuously, so silence costs about the same as speech for
  the mic lane; the system-audio lane is free while no app plays sound.
- **Recording bar ≈ 3–5%.** The waveform is an `NSView` that redraws itself 20×/s and the status dot
  is a `CABasicAnimation`; neither goes through SwiftUI. Earlier versions did (a `Canvas` driven
  by `@Published` and a `repeatForever` SwiftUI animation) and cost ~12%: every tick re-ran the
  window's constraint layout and SwiftUI recomputed the draggable regions of the
  movable-by-background panel on every frame.
- **Live captions on the bar ≈ +1.5%.** Measured with the speakers on and echo cancellation off
  (so both lanes transcribe the same speech), CPU over 20 s of one speech clip: bar off ~11%,
  the old controls-only bar ~16%, the bar with captions ~17%. What keeps it there:
  - The bar's SwiftUI tree never observes `AppModel`. `AppModel` publishes on every partial
    event (several a second per lane, often with unchanged text); the bar watches
    `RecordingBarState` (phase, panel visibility: de-duplicated copies) and `CaptionsFeed`,
    which publishes only when a caption's text changes, at most ~5×/s.
  - The waveform fills plain rects batched per colour and opacity (~20 fills a frame). One
    antialiased rounded-rect path per bar cost ~5% at 142 bars × 20 frames/s. Rendering into
    our own bitmap and setting it as the layer's contents was worse still (a new image per tick).
  - The caption scroll is a 0.25 s animation scoped to the text view, only when a line wraps.
  - The window never changes size (captions on/off happen inside it), so no window layout.
- **Avoid on the main thread:** `SMAppService.status` is an XPC round trip (~100 ms blocked);
  `AppDelegate.refresh()` caches it for 5 s.

How to measure: `open --env HEARSAY_AUTOSTART=1 build/hearsay.app`, then
`top -l 2 -s 3 -pid $(pgrep -x hearsay) -stats cpu,mem | tail -1`, and `ps -M <pid>` for the
per-thread split (the 25% voice-processing thread runs at priority 97). `sample <pid> 4` shows
where the main thread goes. A single `top` reading varies by ±3% between runs (the engines'
load depends on what they hear); for before/after comparisons play the same clip
(`say -o clip.aiff "…"`, `afplay clip.aiff`), take `ps -o cputime= -p <pid>` at both ends of a
fixed 20 s window, and interleave the variants over a few rounds. Engines alone: `hearsay --transcribe a.wav --realtime --two b.wav`.

## Audio glitches

Symptom: a YouTube video playing through the speakers froze for a moment whenever hearsay started,
stopped, paused or resumed.

How it was measured (2026-11-09, M4 MacBook Air, built-in speakers, macOS 27.2): a small monitor
process plays silence on the default output through its own IOProc and logs every callback whose
sample time jumps or arrives late, plus output-device property changes (`DeviceIsRunningSomewhere`,
buffer size, rate, overloads). Each candidate cause was then triggered on its own with
`hearsay --audio-probe mic|system` (launched via `open -W -n`) while the monitor ran. A jump is
what every other app sees: the device's IO stopped, so a browser's audio clock (and the video
synced to it) stalls.

| Action | Output stalls |
|---|---|
| System tap: create process tap + aggregate, start, stop, destroy | none |
| Mic, voice processing off: start / stop | none |
| Mic, voice processing on: first start (`setVoiceProcessingEnabled` + `engine.start`) | 2 × ~0.5 s |
| Mic, voice processing on: `engine.stop()` | none |
| Mic, voice processing on: releasing the engine (VP unit disposed) | 2 × ~0.5 s, ~0.5 s after release |
| Restarting a stopped voice-processing engine (tap removed + reinstalled) | none |
| Ducking configuration set before vs after enabling voice processing | no difference |

So the glitch is entirely Apple's voice processing (cause 1); the process tap (cause 2) is
silent. `setVoiceProcessingEnabled(true)` also blocks for ~2 s. Each VPIO start or release puts the
output device through two stop/restart cycles (`DeviceIsRunningSomewhere` 1→0→1 twice).

What hearsay does about it:

- **Pause / Resume never touch the devices.** Sources keep running; each lane's gate closes, chunks
  are discarded, the engines flush (trailing text becomes final lines) and restart with fresh
  state on resume. Verified live: no stalls, no `mic: stopped` / `systemtap: stopped` in the log.
  Cost: while paused the mic stays open (recording indicator on) and voice processing keeps using
  ~25% CPU.
- **Stop parks the voice-processing engine** (`VoiceProcessingPark`): it is stopped, not released.
  A stopped engine does not hold the microphone (the input device stops running). The next Start
  on the same devices reuses it: no stall, and the mic is up in ~60 ms instead of ~2.4 s. It is
  released after 10 min unused once the output is idle (nothing playing, so inaudible), or when the
  output device changes; quitting releases it (2 stalls if something is playing at that moment).
- **Start**: the first voice-processing start of a run still costs the 2 stalls; nothing in the
  public API avoids them. Both sources now start concurrently and off the main thread, so the
  system lane is listening ~30 ms after Start instead of waiting for voice processing.

Measured live (app, `say` playing through the speakers): Start 2 stalls; Pause, Resume, Stop,
Start-again and Stop: none; Quit: 2 (release).
