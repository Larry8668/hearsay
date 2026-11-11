# Building from source

Build, sign and run hearsay yourself. Requires Xcode command-line tools (Swift 6 toolchain), macOS
14.2+ and an Apple Silicon Mac.

## Build

```sh
make identity   # once: creates a stable self-signed "hearsay-dev" signing identity (no GUI, no sudo)
make            # swift build + bundle + sign → build/hearsay.app
make run        # build and launch
make test       # transcript ordering / formatting unit tests (pure, no audio, no window server)
```

The first build compiles FluidAudio (the on-device speech runtime) and takes about 30 s.

Why the identity matters: ad-hoc signatures change on every build, and macOS silently revokes the
**Microphone** and **System Audio Recording** grants whenever the signature changes. `make identity`
puts the certificate in its own keychain (`~/Library/Keychains/hearsay-dev.keychain-db`) with codesign
pre-authorised so builds never prompt. `make` falls back to ad-hoc with a warning if it's missing.

Always launch through LaunchServices (`make run` / `open build/hearsay.app` / double-click). If you
run the binary directly from a terminal, macOS attributes the microphone and audio-capture requests
to the *terminal* (the "responsible process"): it prompts for the terminal instead, and hearsay's own
grants are never consulted. The CLI diagnostics are the exception; they are meant to run from a
terminal.

## Logs

- File: `~/Library/Logs/hearsay/hearsay.log` (`hearsay-dev.log` for a dev build; Troubleshooting ▸ Open logs).
  Lines read `time [LEVEL] [category] message`; categories: mic, tap, engine, session, ui, update,
  model, diarize, app (also the os_log category). `Log.info(.mic, "…")`; a call without a category is `app`.
  Each session is bracketed by `===== session start … =====` / `===== session end … =====` lines.
- Rotation: the live file plus 3 rolled copies (`.1` newest … `.3` oldest), rolled at 5 MB (~20 MB cap per
  flavour). At launch everything else in the folder is deleted, and so are rolled files older than 30 days.
- Spoken text is not logged (only word counts) unless Troubleshooting ▸ "Verbose logging (includes transcript
  text)" is on (`verboseLogging` in `Prefs.store`, default off).
- Troubleshooting ▸ "Export diagnostics…" saves `hearsay-diagnostics-<date>.zip` with the log files and a
  `report.txt` (versions, permissions, settings, audio devices, model folder, transcript count; no
  transcript text). For scripts: `HEARSAY_UI_SCRIPT=diagnostics@5 HEARSAY_DIAGNOSTICS_OUT=/tmp/d.zip`.
- Unified log: `/usr/bin/log show --last 5m --info --predicate 'subsystem == "dev.hearsay.app"'`
  (use the full path: `log` is also a zsh builtin)
- `HEARSAY_VERBOSE=1` also mirrors the log to stderr.

## Dev build alongside the installed app

A build that is not `/Applications/hearsay.app` runs in **dev mode** and can run at the same time as
the Homebrew-installed app, so you never have to quit your real session to test. Dev mode is on when
the bundle is not under `/Applications`, or when `HEARSAY_DEV=1` is in the environment.
`make run` launches with `open --env HEARSAY_DEV=1`, so a repo launch is dev mode even if you copied
the build into `/Applications` by hand.

| | installed | dev |
|---|---|---|
| single-instance guard | blocks a second copy of the same bundle path | same; ignores the installed app |
| status item | waveform icon | waveform icon plus a small "dev" label; menu starts with "hearsay dev build · version" |
| hotkeys | ⌃⌥H listen, ⌃⌥P pause | ⌃⌥⇧H, ⌃⌥⇧P |
| preferences | `dev.hearsay.app` | `dev.hearsay.app.dev` (`defaults read dev.hearsay.app.dev`) |
| transcripts | `~/Documents/hearsay` | `~/Documents/hearsay-dev` (`HEARSAY_TRANSCRIPTS_DIR` still wins) |
| log | `~/Library/Logs/hearsay/hearsay.log` | `~/Library/Logs/hearsay/hearsay-dev.log` |
| `HEARSAY_AUTOMATION=1` notification | `dev.hearsay.control` | `dev.hearsay.control.dev` |

The model folder (`~/Library/Application Support/hearsay/models`) is shared. Both copies may capture
the microphone and the system tap at once; each tap excludes only its own process. The CLI probes
(`--audio-probe`, `--transcribe`) never count as running instances. Two copies of the same path
(for example two `build/hearsay.app`) are still refused; Relaunch waits for the old one to quit.

## Development aids

- `Sources/hearsay/Wiring.swift` is the single place where the audio sources and the speech engine
  are chosen (the microphone, the per-app or mixed system tap, Parakeet); swap one there to try
  another.
- `HEARSAY_AUTOSTART=1` starts listening as soon as the model is ready; `HEARSAY_AUTOMATION=1`
  lets `distributednotificationcenter` posts of `dev.hearsay.control` with object `toggle` or
  `pause` drive the session (synthesized key events don't reach the Carbon hotkeys).
- `HEARSAY_SNAPSHOT_DIR=/tmp/hs` makes the app render its windows to PNGs and the menu to `menu.txt`
  every 2 s, without needing Screen Recording permission:
  `open --env HEARSAY_SNAPSHOT_DIR=/tmp/hs build/hearsay.app`. `HEARSAY_SNAPSHOT_INTERVAL=0.1`
  shortens the interval; `HEARSAY_SNAPSHOT_SEQ=1` keeps every frame (`name-0001.png`, …) and logs
  each window's frame to `frames.txt`, for stepping through an animation.
- `HEARSAY_TRANSCRIPTS_DIR=/some/dir` makes the instance read and write its transcripts there
  instead of `~/Documents/hearsay` (unattended runs then leave the real folder alone).
- `HEARSAY_UI_SCRIPT="window@3,captions@10,pause@20"` runs those UI actions that many seconds after
  launch (`window`: open the main window, `panel`: toggle it on the live view as the bar's button
  does, `past`: select the newest saved transcript, `hideme`: toggle the "me" chip, `delete`: show
  the Trash confirm, `dark` / `light`: force the window's appearance, `small` / `large`: 700×480 /
  1200×800, `captions`: the bar's captions chevron, `pause`, `pill` / `full`: the bar's shape,
  `welcome` / `about`: those windows, `warn`: a sample warning line), so states that need a click
  can be snapshotted unattended. A step can carry text after "=": `title=Design review@6`,
  `tags=a;b@6`, `name=Priya@6` (the first voice), `search=budget@8`, `yourname=Aditya@4`,
  `diarize=microphone@4` (Settings ▸ Tell speakers apart: `off`, `microphone` or `all`);
  `edittitle`, `addtag` and `rename` open those inline editors, `more` the ⋯ menu and `export` the
  Export… panel. `HEARSAY_SNAPSHOT_ALL=1` also captures the process's other on-screen windows (a
  menu, the save panel) to `extra-<id>.png`.

First launch: the welcome window asks for Microphone access; macOS asks for System Audio Recording
the first time you start listening. If a grant doesn't take effect, use Troubleshooting ▸ Relaunch.

---
[← Back to the README](../README.md)
