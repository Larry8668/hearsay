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

- File: `~/Library/Logs/hearsay/hearsay.log` (Troubleshooting ▸ Open logs)
- Unified log: `/usr/bin/log show --last 5m --info --predicate 'subsystem == "dev.hearsay.app"'`
  (use the full path: `log` is also a zsh builtin)
- `HEARSAY_VERBOSE=1` also mirrors the log to stderr.

## Development aids

- `Sources/hearsay/Wiring.swift` is the single place where the audio sources and the speech engine are
  chosen. Until the real ones are wired in it returns the fakes in `Stubs.swift`, which produce
  canned lines so the whole UI can be exercised without permissions or a model.
- `HEARSAY_FAKE_DENY=me` (or `them`) makes the fake source fail with "permission denied".
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
  1200×800, `captions`: the bar's captions chevron, `pause`), so states that need a click can be
  snapshotted unattended.

First launch: the welcome window asks for Microphone access; macOS asks for System Audio Recording
the first time you start listening. If a grant doesn't take effect, use Troubleshooting ▸ Relaunch.

---
[← Back to the README](../README.md)
