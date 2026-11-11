# Using hearsay

hearsay lives in the menu bar as a waveform that reads like a switch: greyed out while it is off,
**green** while listening, an **orange** pause symbol while paused, and a **yellow** warning
triangle when something needs your attention (a permission, the speech model).

## Start and stop

- **⌃⌥H** (Control-Option-H) starts or stops listening from any app.
- **⌃⌥P** (Control-Option-P) pauses and resumes.
- Or use **Start listening / Stop listening** and **Pause / Resume** in the menu, or the buttons on
  the recording bar.

While listening, hearsay transcribes two things separately:

- **me**: your microphone.
- **them**: whatever your Mac plays: Zoom, Meet in a browser, Teams, FaceTime. The app the sound
  came from is noted next to the line ("them (Zoom)").

The first time you start, macOS asks for **Microphone** and **System Audio Recording** access. If you
said no, the menu shows *Microphone access denied — Open settings…*; turn hearsay on there and start
again.

## Several apps at once

Each app that plays sound is captured on its own: a video in Zen and a Meet call in Chrome are
transcribed separately and never blend into one line, and each gets its own label and its own
caption block ("them · Zen", "them · Chrome"). Up to four apps are transcribed at once; each app
that is actually talking costs about 5% CPU and 20 MB while it talks, and nothing while silent.

Tabs inside one browser cannot be told apart: every browser mixes its tabs before the sound
leaves it, so two Zen tabs are one "them · Zen". For a meeting plus a video, keep them in
different apps. `defaults write dev.hearsay.app perAppAudio -bool false` goes back to a single
mixed stream labelled with whichever app is playing.

## Me and them: blue and orange

Everywhere hearsay shows the two sides, **me is blue** and **them is orange**: the chips in the live
transcript, the lines on the recording bar, and the two halves of its waveform.

## Speakers or headphones: echo cancellation

With the sound coming out of your Mac's speakers, your microphone hears the other side too, and
"me" would repeat what "them" just said. hearsay runs Apple's voice processing on the microphone
to cancel that (the same processing FaceTime uses; the Control Center mic modes such as Voice
Isolation apply to hearsay as well). It costs about a quarter of one CPU core, so by default it is
only on while your output is a loudspeaker: built-in speakers, a monitor, AirPlay. With headphones,
AirPods or a USB headset there is nothing to cancel and it stays off. Change this under
Settings ▸ Echo cancellation (*Auto*, *Always*, *Off*). A text-level filter also drops a "me" line
that is just a copy of what "them" said at the same moment.

## The recording bar

While a session is listening or paused, a dark bar sits at the bottom centre of the screen, just
above the Dock: live captions on top, the controls underneath. It stays on top of everything,
including a full-screen Zoom or Meet, and on every Space, and clicking it never takes focus away
from your call. It comes in two shapes, the full bar and a small pill (below); switch with the
⤡ / ⤢ button on either, or under **Settings ▸ Recording bar**. hearsay remembers which you used.

```
┌──────────────────────────────────────────────────────────┐
│ me           …so the deadline moves to Friday, which      │
│              gives us the whole week for testing          │
│ them · Zoom  sounds good, I'll send the notes over        │
└──────────────────────────────────────────────────────────┘
(●  ▁▃▅▂▇▃▁▂▅▃▁▂▅▃▁▂▅  12:34                 ⏸   ■   ≡   ˅ )
```

**Captions.** One block per side that has spoken in the last 10 seconds, **me** first, then
**them** (with the app's name). Each block shows the last two lines of what that side is saying,
like subtitles: new words appear on the bottom line and older lines slide up and out at the
top. Words still being transcribed are slightly dimmer and firm up when the sentence ends; a
block keeps its last words while the recogniser is making up its mind, so it never blinks
mid-sentence. A side that has been quiet for 10 seconds fades away; with nobody talking the card
just says *Listening…*. The captions only ever show the latest lines; the full text is in the
live transcript window (≡) and the transcript file.

**Controls.**

- **Dot**: red and gently pulsing while listening, amber when paused, grey while the speech model is
  still loading.
- **Waveform**: your microphone in the upper half (blue), what the Mac plays in the lower half
  (orange). A thin line means that side is silent. It freezes and dims while paused.
- **Time**: how long you've been listening, not counting pauses. Shows *Paused* while paused.
- **Buttons**: pause / resume, stop (finishes and saves the transcript), show / hide the live
  transcript window, and ⤡ to shrink to the pill. Hover a button for its name and shortcut.
- **˅ / ˄**: hides or shows the captions, leaving just the controls. hearsay remembers your choice.
  Nothing happens on hover: the bar never changes size unless you click this.

Drag the bar anywhere; hearsay remembers the spot. Double-click its background to put it back at
the bottom centre. Turn the bar off completely under **Settings ▸ Recording bar ▸ Show recording
bar**.

**The pill.** For a call where the bar is in the way: a capsule the height of the controls and
no wider than they need, with the dot, a short waveform, pause / resume, stop, and ⤢ back to the
full bar.

```
(●  ▁▃▅▂▇▃▁   ⏸   ■   ⤢ )
```

Drag it anywhere, including right up against the screen's left or right edge; hearsay remembers
its spot separately from the bar's, so you can keep the bar at the bottom and the pill in a
corner. Double-click its background to put it back at the bottom centre. It has no captions and
no clock: the live transcript window has everything.

## Pausing

Pause stops listening to both sides completely (nothing is captured or transcribed) but keeps the
session: Resume carries on in the same transcript file. The transcript marks each pause where it
happened, and the header counts it:

```
# Call transcript — Mon 9 Nov 2026, 14:03–14:41 (38 min, 4 min paused)
…
_— paused 4 min —_
```

Stopping or quitting while paused saves the transcript as usual.

## Where transcripts go

Every session is saved to **Documents ▸ hearsay** as the call goes on, named by its start time:

```
2026-11-09 14.03 hearsay.md     the readable transcript
2026-11-09 14.03 hearsay.json   the same lines with exact timestamps, for other tools
```

The file is rewritten at most once a second while you talk and completed (end time, duration) when
you stop or quit. Lines are in the order they were spoken, even when one side's text arrives a moment
later. A session in which nobody spoke leaves no file.

## The menu

| Item | What it does |
|---|---|
| Status line | *Not listening*, *Listening · 12 min · 48 lines*, or the model download progress |
| Start / Stop listening | Same as ⌃⌥H |
| Pause / Resume | Same as ⌃⌥P; only shown during a session |
| Show live transcript | A small floating window with the transcript as it happens |
| Open transcript | The current session's file, or the most recent one |
| Open transcripts folder | Documents ▸ hearsay in Finder |
| Copy transcript | The current or last session as plain text |
| Export subtitles (.srt) | Writes an .srt next to the transcript (times from the start of the session) |
| Sources ▸ | Turn **Me** or **Them** off, e.g. to transcribe only a webinar. Works mid-session |
| Settings ▸ | Launch at login, daily update check, the recording bar (on / off, full bar or pill), echo cancellation (Auto / Always / Off), live panel font size, which speech engine is in use, and the welcome window again |
| Troubleshooting ▸ | Open the log file, jump to the Microphone / System Audio privacy settings, relaunch hearsay |
| Version line | Shows when an update is available, with *Update now* |

## The live transcript window

Each line has its time, a chip saying who spoke (**me** in blue, **them · Zoom** in orange, with the
app's name when known) and the text. Consecutive lines from the same side show the chip once. Dimmer
text at the bottom, with three pulsing dots, is what's being said right now (the last few lines of
it); it firms up into a line when the sentence ends. In a narrow window the chip and time sit on
their own line above the text. The window scrolls along while you're at the bottom; scroll up to
reread and it stays put, with a **New lines** button to jump back down when more arrive.

Along the bottom: **Copy all**, **Export SRT**, **Reveal in Finder**, smaller/larger text, and the pin
(keep above all windows, including a full-screen call). The window follows your light or dark
appearance and never takes keyboard focus away from your call app.

## Privacy

Audio and text stay on this Mac. The speech model is downloaded once and kept locally. The only
network request hearsay makes is a once-a-day check for a newer release on GitHub, which you can turn
off under Settings.

---
[← Back to the README](../README.md)
