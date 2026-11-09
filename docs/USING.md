# Using hearsay

hearsay lives in the menu bar as a waveform. It turns red while listening, becomes an orange pause
symbol while paused, and shows a warning triangle when something needs your attention (a
permission, the speech model).

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

## Me and them: blue and orange

Everywhere hearsay shows the two sides, **me is blue** and **them is orange**: the chips in the live
transcript, the lines on the recording bar, and the two halves of its waveform.

## The recording bar

While a session is listening or paused, a small dark capsule sits at the bottom centre of the
screen, just above the Dock. It stays on top of everything, including a full-screen Zoom or Meet,
and on every Space, and clicking it never takes focus away from your call.

```
●  ▁▃▅▂▇▃▁▂▅▃  12:34    ⏸  ■  ≡  ˄
```

- **Dot**: red and gently pulsing while listening, amber when paused, grey while the speech model is
  still loading.
- **Waveform**: your microphone in the upper half (blue), what the Mac plays in the lower half
  (orange). A thin line means that side is silent. It freezes and dims while paused.
- **Time**: how long you've been listening, not counting pauses. Shows *Paused* while paused.
- **Buttons**: pause / resume, stop (finishes and saves the transcript), and show / hide the live
  transcript window. Hover a button for its name and shortcut.
- **˄**: shows the latest words from each side above the controls (in italic while they're still
  being transcribed). Hovering over the bar for a moment does the same; click ˄ to keep it open,
  or click it again to keep it closed for the rest of the session.

Drag the bar anywhere; hearsay remembers the spot. Double-click its background to put it back at
the bottom centre. Turn it off, or turn off expanding on hover, under **Settings**.

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
| Settings ▸ | Launch at login, daily update check, show the recording bar, expand it on hover, live panel font size, which speech engine is in use, and the welcome window again |
| Troubleshooting ▸ | Open the log file, jump to the Microphone / System Audio privacy settings, relaunch hearsay |
| Version line | Shows when an update is available, with *Update now* |

## The live transcript window

Each line has its time, a chip saying who spoke (**me** in blue, **them · Zoom** in orange, with the
app's name when known) and the text. Consecutive lines from the same side show the chip once. Grey
italic text at the bottom, with three pulsing dots, is what's being said right now; it firms up into
a line when the sentence ends. The window scrolls along while you're at the bottom; scroll up to
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
