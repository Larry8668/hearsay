# Using hearsay

hearsay lives in the menu bar as a waveform. It turns red while listening and shows a warning
triangle when something needs your attention (a permission, the speech model).

## Start and stop

- **⌃⌥H** (Control-Option-H) starts or stops listening from any app.
- Or use **Start listening / Stop listening** in the menu.

While listening, hearsay transcribes two things separately:

- **me**: your microphone.
- **them**: whatever your Mac plays: Zoom, Meet in a browser, Teams, FaceTime. The app the sound
  came from is noted next to the line ("them (Zoom)").

The first time you start, macOS asks for **Microphone** and **System Audio Recording** access. If you
said no, the menu shows *Microphone access denied — Open settings…*; turn hearsay on there and start
again.

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
| Show live transcript | A small floating window with the transcript as it happens |
| Open transcript | The current session's file, or the most recent one |
| Open transcripts folder | Documents ▸ hearsay in Finder |
| Copy transcript | The current or last session as plain text |
| Export subtitles (.srt) | Writes an .srt next to the transcript (times from the start of the session) |
| Sources ▸ | Turn **Me** or **Them** off, e.g. to transcribe only a webinar. Works mid-session |
| Settings ▸ | Launch at login, daily update check, live panel font size, which speech engine is in use, and the welcome window again |
| Troubleshooting ▸ | Open the log file, jump to the Microphone / System Audio privacy settings, relaunch hearsay |
| Version line | Shows when an update is available, with *Update now* |

## The live transcript window

Your lines are blue, theirs orange with the app's name underneath. Grey italic text at the bottom is
what's being said right now; it firms up into a line when the sentence ends. The window scrolls along
while you're at the bottom; scroll up to reread and it stays put.

Along the bottom: start/stop, **Copy all**, smaller/larger text, and the pin (keep above all windows,
including a full-screen call). The window never takes keyboard focus away from your call app.

## Privacy

Audio and text stay on this Mac. The speech model is downloaded once and kept locally. The only
network request hearsay makes is a once-a-day check for a newer release on GitHub, which you can turn
off under Settings.

---
[← Back to the README](../README.md)
