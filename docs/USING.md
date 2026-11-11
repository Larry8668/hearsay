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

Everywhere hearsay shows the two sides, **me is blue** and **them is orange**: the chips in the
hearsay window, the lines on the recording bar, and the two halves of its waveform.

## Several people on one source: telling speakers apart

In a meeting room everyone is on the microphone, and on a Zoom call several people can share the
"them" side. With **Settings ▸ Tell speakers apart** on (*Microphone only* is the default; *All
sources* also covers each app's audio; *Off* costs nothing), hearsay runs a small speaker model next
to the speech model and tells voices apart as they talk:

- A line ends when the speaker changes, so each line is one person. A new voice has to hold the
  floor for a moment (about half a second) before a line is cut: a "yes" in the background or two
  people briefly talking over each other does not break the line.
- The chip says who: while only one voice has been heard on the microphone it just says **me**; the
  moment a second person speaks, the first becomes **Speaker 1** and the newcomer **Speaker 2**, in
  the order they first spoke. On a call it reads **them · Zoom · Speaker 2**. Each speaker gets its
  own shade of the lane's colour (blues for the microphone, oranges for system audio).
- The transcript file carries the same labels; the header lists the speakers and the JSON sidecar
  has each line's `speakerID` and a `speakers` map (id → generated label). An id is the voice's
  key plus the speaker's number: `me#2`, `them:us.zoom.xos#1`.
- *Speaker 2* is only the default: rename the chip in the hearsay window (see *Speaker names*
  below) and the name replaces it in the lines, the captions and every export. The name is
  saved in the sidecar's `names` map under the same id.

Numbers are per session: *Speaker 1* in today's meeting is whoever spoke first, not the same person
as yesterday's *Speaker 1*. To have your own voice recognised, use **Settings ▸ Tell speakers
apart ▸ Learn my voice…** while not listening: a small panel counts down 10 seconds while you read
anything aloud, and from the next session on your voice is labelled **me** and everyone else
**Speaker 1, 2…**. The clip stays on this Mac (`~/Library/Application Support/hearsay/voice/me.wav`);
*Forget my voice* removes it. Enrolment is a hint to the model, not a voiceprint: if two voices are
very alike it may still mix them up.

The model (NVIDIA Streaming Sortformer, 234 MB) is downloaded the first time the setting is on and
kept with the speech models. It tells up to four voices apart per source; a fifth is merged into
the closest one. Two very similar voices (the same pitch and accent) can land in one slot. Turning
the setting on or off during a session restarts the affected source, so the change applies at
once. `defaults write dev.hearsay.app diarizer lseend` (or `lseend-ami`) swaps in the LS-EEND model
(43 MB, up to ten voices, less stable identities); `sortformer` is the default.

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
hearsay window (≡) and the transcript file.

**Controls.**

- **Dot**: red and gently pulsing while listening, amber when paused, grey while the speech model is
  still loading.
- **Waveform**: your microphone in the upper half (blue), what the Mac plays in the lower half
  (orange). A thin line means that side is silent. It freezes and dims while paused.
- **Time**: how long you've been listening, not counting pauses. Shows *Paused* while paused.
- **Buttons**: pause / resume, stop (finishes and saves the transcript), show / hide the
  hearsay window on its live transcript, and ⤡ to shrink to the pill. Hover a button for its name
  and shortcut. The ≡ button brings the window up without taking focus from your call (its title
  bar reads as inactive); click into it when you want to use the keyboard there.
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

A title, tags and speaker names given in the hearsay window (below) are saved into both files: the
Markdown's heading becomes the title, with the date on the line under it and the tags in the italic
line, and the lines use the names; the JSON keeps the raw voices plus `title`, `tags` and a `names`
map (keyed by voice: `me`, `them:us.zoom.xos`, or a diarized speaker's id such as `me#2`), so
other tools can tell "me" from "Aditya":

```markdown
# Design review
Tue 10 Nov 2026, 10:03–10:41 (38 min)
_Tags: design, q4 · Apps heard: Zoom · Engine: parakeet-unified-640ms · Made with hearsay, on this Mac._

**10:03:12 Priya** Thanks everyone for joining today.
```

## The menu

| Item | What it does |
|---|---|
| Status line | *Not listening*, *Listening · 12 min · 48 lines*, or the model download progress |
| Start / Stop listening | Same as ⌃⌥H |
| Pause / Resume | Same as ⌃⌥P; only shown during a session |
| Open hearsay… | The main window: the live transcript and every saved one (below) |
| Open transcript | The current session's file, or the most recent one |
| Open transcripts folder | Documents ▸ hearsay in Finder |
| Copy transcript | The current or last session as plain text |
| Export subtitles (.srt) | Writes an .srt next to the transcript (times from the start of the session) |
| Sources ▸ | Turn **Me** or **Them** off, e.g. to transcribe only a webinar. Works mid-session |
| Settings ▸ | Launch at login, daily update check, the recording bar (on / off, full bar or pill), echo cancellation (Auto / Always / Off), tell speakers apart (Off / Microphone only / All sources, *Learn my voice…*), the transcript text size, **Your name…** (what "me" is called everywhere; see below), which speech engine is in use, and the welcome window again |
| Troubleshooting ▸ | Open the log file, export diagnostics (a zip of the logs plus a system report, never your transcripts) to attach to a bug report, turn on verbose logging (also logs spoken text; off by default), jump to the Microphone / System Audio privacy settings, relaunch hearsay |
| Version line | Shows when an update is available, with *Update now*; also *Release notes*, *Check for updates now* and *About hearsay* |

## The hearsay window

**Open hearsay…** in the menu (or the ≡ button on the recording bar, or opening the app again)
shows the main window: a sidebar on the left, the transcript on the right.

```
┌───────────────┬──────────────────────────────────────────────────────────┐
│ 🔍 Search     │ ● 12:34  ⏸ Pause  ■ Stop             A A   ⧉   ⋯        │
│ ● Live        ├──────────────────────────────────────────────────────────┤
│ Listening ·   │ Design review                                         ✎  │
│ 12:34 · 48 l. │ Listening · 12:34 · 48 lines                             │
│               │ (design) (q4)  + Tag                                     │
│ TODAY         │ ✓ Aditya   ✓ Priya   ✓ them · Chrome                     │
│ Design review │──────────────────────────────────────────────────────────│
│ 14:03 · 48 l. │ 14:03:12   Aditya   So the deadline moves to Friday?     │
│ (design) (q4) │ 14:03:15   Priya    Sounds good, I'll send the…          │
│ 10:26  12 min │                                                          │
│ YESTERDAY …   │ ⋯                                                        │
└───────────────┴──────────────────────────────────────────────────────────┘
```

**Sidebar.** *Live* at the top is the current session (highlighted, with the red dot and the
listening time, while one is running; afterwards it keeps the last session until the next one
starts). Below it, every transcript saved in Documents ▸ hearsay, newest first and grouped by
day, each with its title (or its start time), length, line count, the apps heard and up to three
of its tags. New files appear as soon as they are saved. ⌃⌘S hides the sidebar.

**Search.** The field at the top of the sidebar filters the list as you type (a moment after the
last keystroke): a transcript stays listed if the text appears in its title, a tag, a speaker's
name or any of its lines, regardless of case. Esc clears it.

**Titles and tags.** The header of any transcript, the live one included, starts out as its date
(or *Live transcript*); click it, or the pencil beside it, to give it a title: Enter saves, Esc
cancels, an empty field goes back to the date. The date stays as the line underneath. Under that is
the tag row: **+ Tag** opens a small field; type and press Enter, or click one of the tags you
have used on other transcripts, which are offered as you type. The field stays open for the next
tag; Esc closes it. The × on a tag removes it. Everything is saved straight into the transcript's
files (for the live session, with its next save), and the window's title and the sidebar follow.

**Speaker names.** Right-click a speaker chip in the header (or hover it and click the pencil) and
type a name: "me" becomes "Aditya", "them · Zoom" becomes "Priya", on that transcript only, in the
lines, the chips, the live captions on the bar, and every copy and export. Colours never change:
me stays blue, them stays orange. An empty name puts the original label back. With speakers told
apart each speaker has its own chip, so *Speaker 2* can become "Anna" while *Speaker 1* stays.
To be called by your name everywhere, set **Settings ▸ Your name…** once: it replaces "me" in
every transcript, live captions and export until a transcript renames "me" itself. It never
replaces a numbered speaker: on a shared microphone it applies to your enrolled voice (*Learn my
voice…*), or to the lane while it has only one voice.

**Toolbar.** *Start listening* (or *Pause* / *Resume* and *Stop* with the listening time while a
session runs), smaller / larger text, *Copy* (plain text, one timed line each), and under ⋯:
*Export…*, *Export subtitles (.srt)*, *Copy as text* / *Copy as Markdown*, *Reveal in Finder*,
*Open in editor* and, for a saved transcript, *Move to Trash…* (confirmed inline, under the
header; the Markdown and JSON files go to the Trash together).

**Export.** *Export…* (also File ▸ Export…, ⌘E) opens a save panel with a format popup:
**Markdown** (.md, the same layout as the saved file), **JSON** (.json, the sidecar's layout with
the title, tags and names), **Plain text** (.txt, "name: text" per line, no times) and
**Subtitles** (.srt, times from the start of the session). The suggested file name is the title,
or the transcript's date name. Every format, like Copy, contains only the speakers currently
shown (next). *Export subtitles (.srt)* is the one-click shortcut that writes the .srt next to the
transcript, as before.

**Lines.** Each line has its time, a chip saying who spoke (**me** in blue, **them · Zoom** in
orange, with the app's name when known, and **Speaker 2** or **them · Zoom · Speaker 2** in its
own shade when speakers are told apart) and the text. Consecutive lines from the same speaker
show the chip once. Dimmer text at the bottom, with three pulsing dots, is what's being said right now
(the last few lines of it); it firms up into a line when the sentence ends. In a narrow window the
chip and time sit on their own line above the text. The live view scrolls along while you're at
the bottom; scroll up to reread and it stays put, with a **New lines** button to jump back down
when more arrive. A saved transcript starts at the top and shows its pauses where they happened.

**Speaker toggles.** The header has one chip per voice in the transcript (me, them · Zoom,
them · Chrome…, or their names). Click a chip to hide that voice's lines (and, live, its
in-progress words); click it again, or *Show all*, to bring them back. *Copy*, *Export…* in every
format and *Export subtitles* give what is shown, so a call with a video playing in another app
can be copied without it. The files in Documents ▸ hearsay are never affected: every line is
always saved. For the live view the choice lasts until the next session starts; for a saved
transcript, until the window is closed.

The window follows your light or dark appearance, remembers its size and position, and can be
closed with ⌘W; the session carries on without it.

While the window is open hearsay behaves like any Mac app: it has a Dock icon and the usual
menus (**hearsay** ▸ About / Settings… ⌘, / Quit, **Edit**, **View** ▸ Toggle Sidebar ⌃⌘S and
Larger / Smaller Text ⌘+ / ⌘−, **Window** ▸ Close ⌘W / Minimize ⌘M). ⌘C copies selected
transcript text; Delete on a selected transcript in the sidebar asks to move it to the Trash. Close
the window and hearsay is back to the menu bar only (the recording bar is never hidden by ⌘H).

If a permission was refused, or a source stopped, a yellow line under the live transcript's header
says what happened, with an **Open settings…** button for the right System Settings pane; the
menu shows the same under its status line.

## Privacy

Audio and text stay on this Mac. The speech model is downloaded once and kept locally. The only
network request hearsay makes is a once-a-day check for a newer release on GitHub, which you can turn
off under Settings.

---
[← Back to the README](../README.md)
