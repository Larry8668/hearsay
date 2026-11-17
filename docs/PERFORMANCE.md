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
- **The pill costs no more than the bar.** Measured 2026-11-11 (speakers, echo cancellation on,
  the 21 s clip, `ps cputime` over 18 s, two interleaved rounds): full bar 32% / 38%, pill
  35% / 28%, all within the ±3% run-to-run noise on top of the ~25% voice processing. It is the
  same dot (`PulsingDotNSView`) and the same waveform view drawing the newest 7 of the 36 level
  frames; its SwiftUI tree observes only `RecordingBarState`. The shape not shown keeps its
  window, ordered out; its waveform view skips `needsDisplay` while its window is not visible,
  and `CaptionsFeed` does nothing while the pill is up (it catches up when the bar returns).
- **Avoid on the main thread:** `SMAppService.status` is an XPC round trip (~100 ms blocked);
  `AppDelegate.refresh()` caches it for 5 s.

How to measure: `open --env HEARSAY_AUTOSTART=1 build/hearsay.app`, then
`top -l 2 -s 3 -pid $(pgrep -x hearsay) -stats cpu,mem | tail -1`, and `ps -M <pid>` for the
per-thread split (the 25% voice-processing thread runs at priority 97). `sample <pid> 4` shows
where the main thread goes. A single `top` reading varies by ±3% between runs (the engines'
load depends on what they hear); for before/after comparisons play the same clip
(`say -o clip.aiff "…"`, `afplay clip.aiff`), take `ps -o cputime= -p <pid>` at both ends of a
fixed 20 s window, and interleave the variants over a few rounds. Engines alone: `hearsay --transcribe a.wav --realtime --two b.wav`.

## Telling speakers apart

Measured 2026-11-11, same machine, release build, Streaming Sortformer v2.1 (fast tier, fp16,
`SortformerConfig.fastV2_1`, CPU + Neural Engine) on the microphone lane. Download 234 MB
(`~/Library/Application Support/hearsay/models/sortformer`); LS-EEND (DIHARD III, 100 ms steps)
43 MB.

| Measurement | Sortformer | LS-EEND | Without |
|---|---|---|---|
| CLI, one stream, 37 s clip of three voices, `--realtime`: process CPU time | 0.9 s | 2.7 s | 1.3–1.8 s |
| … as a share of one core while someone talks | within run-to-run noise (≤ 1%) | ~3% | — |
| Peak RSS of that run | 96 MB | 118 MB | 68 MB |
| Model load (warm compile cache) | 0.1 s | 0.0 s | — |
| First download + load | 113 s (234 MB) | 10 s (43 MB) | — |

CLI: `hearsay --transcribe clip.wav --realtime --diarize [sortformer|lseend] [--enrol me.wav]`
runs the engines with the diarizer on a clip (`--enrol`: play that clip in first as "me").

Where it goes:

- **Sortformer runs on the Neural Engine**: one inference per 480 ms of audio (6 output frames of
  80 ms, 7 frames of look-ahead), so its CPU share is the mel spectrogram and the state update,
  too small to separate from the speech model's own variance between runs. LS-EEND runs on the
  CPU (FluidAudio's recommendation; its ANE build is slower) at ten inferences a second.
- **Nothing while the lane is silent.** The diarizer is fed only while the chunk has a voiced
  20 ms frame (the tracker's −44 dBFS threshold) and for 1.2 s after (its look-ahead plus one
  chunk, so the frames of the speech get decided); skipped stretches are bridged by sample
  anchors (`FluidDiarizer.anchors`), so its frame clock still lines up with the lane's. Off
  (Settings ▸ Tell speakers apart ▸ Off) loads nothing: zero cost, no memory.
- **Word attribution costs nothing extra**: the Unified speech model already records the encoder
  frame at which it emitted each token (`consumeTokenTimings`); the tracker maps those onto the
  diarizer's frames instead of estimating when a word was spoken from when it appeared.
- **Enrolment** (the 10 s clip played into a new microphone-lane diarizer at every session start)
  is ~21 Neural Engine calls, well under a second, once per session.

Live app numbers (`top -l 2 -s 3`, Settings ▸ Tell speakers apart ▸ Microphone only, a clip of
three voices through the speakers with echo cancellation off): see the table at the top; the
diarizer's share could not be separated from the ±3% run-to-run variation of the speech model.

Chosen model: Sortformer. On the synthetic three-voice clip (`say -v Samantha / Daniel / Karen`
and, in a second variant, `Moira` as the third voice) all three FluidAudio diarizers found the
same turn boundaries (within 80 ms of the clip's), but only Sortformer told the third voice
(Moira) apart from the first; both LS-EEND variants (DIHARD III and AMI) merged her into
Samantha's slot, and all three merged Karen into Samantha's (two similar synthetic female
voices). Sortformer's slots are also stable across the session, which is what the labels need,
and its enrolment recognised the enrolled voice as "me" when another voice spoke first
(LS-EEND did too on that clip). Its limits: four slots per stream, and quiet or distant speech
can be missed (it is trained to ignore background conversations). Settings ▸ Tell speakers
apart ▸ Model offers LS-EEND as "More speakers, up to 10" for meetings with more than four voices.

Four voices, 2026-11-12 (release build, a 51 s clip of nine turns: `say -v Samantha / Daniel /
Karen / Moira`, 0.4 s gaps):

| Measurement | Sortformer | LS-EEND (DIHARD III) | Without |
|---|---|---|---|
| CLI, one stream, unpaced: RTF (wall / audio) | 0.058 | 0.044 | 0.029 |
| Peak RSS / peak footprint | 99 MB / 67 MB | 119 MB / 54 MB | 71 MB / 50 MB |
| `--realtime`: speakers found (voices in the clip: 4) | 3 (Karen merged into Samantha) | 2 (all three female voices merged) | — |
| Live, through the "them" tap: speakers found / speakers with lines | 4 / 4, but Karen merged into Samantha and Moira split over two slots mid-sentence | 2 / 2 | — |
| `[diarize]` tentative revisions over the clip | 2 | 0 | — |

LS-EEND's settled frames came without any look-ahead revisions on this clip, and its turn
boundaries matched Sortformer's to within 0.1 s; what it lacks here is telling similar voices
apart. Live, Sortformer used all four slots, but not one per voice: Karen shared Samantha's, and
one of Moira's lines moved to a fresh slot halfway (`tentative #3 … settled as #4`, then a turn).
With exactly four voices the slots run out and such flips happen; they are why captions now
name only settled speakers and a speaker is numbered only with a line (see USING.md, Tell
speakers apart).

### Sentences split between two speakers: measured, nothing changed

Complaint: in a meeting of four around one MacBook, one person's sentence sometimes became two
lines with two different speakers (one 34-minute session: 233 speaker-change cuts, the first after
only 0.6 s of a "new" voice). Candidate fixes were measured with `hearsay --eval-speakers` (see
EVAL-SPEAKERS.md for the data, the definitions and how to rerun) on six AMI meetings recorded by
one microphone in the middle of the table, four people each, ten minutes each (60 min, 8,487
reference words, ~410 reference turns), 2026-11-17, M4 MacBook Air, release build, Parakeet
Unified 640 ms, Sortformer unless stated. The rule set in advance: adopt a change only if word
accuracy does not drop, the split-sentence rate drops by at least 20% (relative), merged-minority
words rise by no more than the split words saved, and WER is unchanged.

| Configuration | Word acc. | Split / 100 turns (n) | strict | split words | merged lines / words | Interjections | Lines | Cuts | WER |
|---|---|---|---|---|---|---|---|---|---|
| **Current (hold 0.6 s)** | **95.2%** | **10.5 (43)** | **4.9** | **107** | **97 / 163** | **43.8%** | **566** | **193** | **37.5%** |
| Noise floor: silence gap 1.15 s (not a speaker rule) | 95.2% | 10.4 (43) | 5.8 | 120 | 93 / 161 | 49.1% | 563 | 194 | 37.6% |
| Noise floor: silence gap 1.25 s | 95.0% | 12.3 (50) | 5.4 | 119 | 97 / 167 | 47.1% | 562 | 192 | 37.8% |
| a. hold 1.0 s | 94.6% | 9.7 (40) | 4.4 | 108 | 97 / 194 | 42.5% | 545 | 130 | 38.9% |
| a. hold 1.5 s | 93.7% | 9.2 (38) | 4.6 | 103 | 107 / 251 | 37.7% | 532 | 78 | 38.1% |
| a. hold 2.0 s | 92.7% | 11.8 (49) | 6.5 | 136 | 111 / 295 | 38.7% | 533 | 49 | 37.8% |
| b. cut at a pause ≥ 0.25 s within ±1 s | 95.1% | 10.3 (42) | 5.4 | 110 | 92 / 166 | 44.8% | 566 | 193 | 37.6% |
| c. A-B-A, ≤ 3 words, ≤ 2.5 s, gaps ≤ 1 s | 95.2% | 9.8 (40) | 4.9 | 103 | 97 / 163 | 43.8% | 566 | 193 | 37.5% |
| c. A-B-A, ≤ 5 words, ≤ 4 s, gaps ≤ 1 s | 94.8% | 8.8 (36) | 4.6 | 99 | 97 / 163 | 38.1% | 566 | 193 | 37.5% |
| d. word lead 0.1 s (frames before a word that decide who said it; now 0.25 s) | 95.3% | 11.7 (48) | 5.6 | 104 | 105 / 171 | 44.8% | 568 | 193 | 37.7% |
| d. word lead 0 s | 95.3% | 12.2 (50) | 5.6 | 104 | 107 / 175 | 42.5% | 566 | 193 | 37.7% |
| a + b: hold 1.0 s, cut at pause | 94.8% | 8.8 (36) | 4.4 | 97 | 93 / 193 | 42.5% | 544 | 129 | 38.3% |
| a + b + c: hold 1.0 s, cut at pause, A-B-A ≤ 3 words | 94.9% | 8.5 (35) | 4.4 | 96 | 93 / 193 | 42.5% | 544 | 129 | 38.3% |
| a + c: hold 1.0 s, A-B-A ≤ 3 words | 94.7% | 9.5 (39) | 4.4 | 107 | 97 / 194 | 42.5% | 545 | 130 | 38.9% |
| b + c: cut at pause, A-B-A ≤ 3 words | 95.1% | 9.5 (39) | 5.4 | 106 | 92 / 166 | 44.8% | 566 | 193 | 37.6% |
| LS-EEND (DIHARD III), hold 0.6 s | 78.2% | 13.7 (56) | 10.0 | 309 | 104 / 258 | 43.3% | 571 | 212 | 37.4% |
| LS-EEND (AMI; not in the menu), hold 0.6 s | 62.7% | 5.9 (24) | 4.4 | 127 | 118 / 434 | 33.3% | 527 | 15 | 37.3% |

What the table says:

- **Nothing passes.** The largest split-rate drop is all three together (−19%, just short of
  the bar and inside the noise below), bought with 0.3 points of accuracy, 30 more merged words
  for 11 split words saved and +0.8 WER. Alone, the best is A-B-A smoothing of lines up to five
  words (−16%), which costs word accuracy (−0.4 points) and a fifth of the interjections ("yeah" by B
  between two of A's lines is usually a real "yeah"). A longer hold trades splits for merges almost
  one for one and worse: at 1.5 s, 4 split words saved, 88 more of someone else's words inside
  lines, 1.5 points of accuracy lost; at 2.0 s everything is worse. Cutting at a pause changes
  nothing measurable: people hand over without one, so the pause nearest the diarizer's boundary
  is usually the boundary already. The 0.25 s word lead in use is the best of the three tried.
- **The noise floor is large.** Nudging the silence gap by 0.05 s, which has nothing to do with
  speakers, moves the split rate between 10.4 and 12.3 and interjection recall by five points:
  model resets land elsewhere and the far-field transcript shifts. Any change under ~15% is
  inside that band.
- **What a split is, in this data.** Read through, most split turns are one or two words at the
  edge of a turn landing in the neighbour's line ("…belong to a dog. Thank you." with *dog* and the
  thanks on the next speaker's line) or a stretch the diarizer gave to another slot for several seconds; the
  first is word timing at an overlap, the second the model's own confusion, and neither is a
  hold or smoothing problem.
- **LS-EEND is clearly worse** at telling four people apart from one microphone (78% of words to
  the right person against 95%, three times the split words). Its AMI-trained variant splits
  little only because it hears almost everyone as one voice (15 cuts in an hour, 63% accuracy).
  Sortformer stays the default and the menu advice stands.
- **Latency.** Adopting A-B-A live would have to hold back a short line until the next one is
  final: on these meetings 3–8% of lines, delayed by 5 s on average (median 4–6 s, up to 15 s), or
  relabel lines after they are written. Not built, since the rule fails on accuracy alone.

The experiments stay as CLI flags (`--speaker-hold`, `--cut-at-pause`, `--smooth-aba`,
`--word-lead`) for the next idea to be measured against; the app's defaults are unchanged.

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
