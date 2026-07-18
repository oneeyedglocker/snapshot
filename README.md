# Snapshot

A tiny menu-bar app for macOS that does one thing: hold a rolling ~30 second
buffer of your gameplay and, on a hotkey, save it as an mp4. No OBS, no
scenes, no config sprawl — an instant-replay button.

## How it works

- Captures via `ScreenCaptureKit`, bound to a specific app's window (default:
  World of Warcraft, auto-detected by name) or a specific display.
- Video is encoded to H.264 in real time (VideoToolbox, hardware accelerated)
  and kept in a **RAM ring buffer** — never written to disk until you save.
  This mirrors how OBS's own Replay Buffer works: encoded frames in memory,
  one write to disk on trigger. No continuous disk I/O, no temp file cleanup.
- Audio (system audio only, no mic) is buffered as raw PCM and AAC-encoded
  at save time.
- Default hotkey **⌘⇧R** saves the last 30 seconds to
  `~/Movies/Snapshot Clips/`.

## Build & run

Requires Xcode's command line tools (or Xcode itself) on macOS 13+.

```sh
./scripts/build-app.sh
open build/Snapshot.app
```

This packages the executable into a real `.app` bundle (rather than running
the raw SPM binary) so macOS gives it a stable identity — important because
Screen Recording / Accessibility permissions are granted per app bundle, and
you don't want to re-approve on every rebuild during development... though
with ad-hoc signing you may still see occasional re-prompts after rebuilding;
see "Permissions" below.

For quick iteration without repackaging, `swift run` also works, but macOS
will treat each build as a "new app" for permission purposes.

## First launch

You'll be prompted for two permissions:

1. **Screen Recording** — required to capture anything. System Settings →
   Privacy & Security → Screen Recording → enable Snapshot, then relaunch.
2. **Accessibility** — required for the global hotkey to fire while another
   app (the game) has focus. System Settings → Privacy & Security →
   Accessibility → enable Snapshot.

## Using it

Click the menu bar icon (● record icon):

- **Capture Target** — pick the app or display to record. Your choice is
  remembered and auto-selected next launch (falls back to searching for
  "World of Warcraft" by name if nothing's saved).
- **Start/Stop Recording** — begins/ends the rolling buffer.
- **Save Last 30s Now** — same as the hotkey, useful without a keyboard.
- **Show Clips Folder** — opens `~/Movies/Snapshot Clips/` in Finder.

## Tuning

Everything's in `Sources/Snapshot/Settings.swift`:

- `exportSeconds` — clip length (default 30s).
- `bufferSeconds` — how much extra slack is kept in RAM beyond the export
  window, so trimming to a keyframe never comes up short (default 40s).
- `videoBitrate`, `frameRate`, `keyframeIntervalSeconds` — quality/size
  tradeoffs.
- Hotkey defaults to ⌘⇧R; change `hotkeyKeyCode`/`hotkeyModifiers` defaults
  or extend the menu with a picker if you want it configurable at runtime.

## Notes / known limitations

- Built and reasoned about against the documented ScreenCaptureKit /
  VideoToolbox / AVFoundation APIs, but not compiled on real macOS hardware
  as part of this change (no Mac toolchain in the environment it was written
  in). Build it with `./scripts/build-app.sh` and if Xcode flags an API
  mismatch against your SDK version, those are usually quick fixes.
- App-bound capture targets the window that's largest/on-screen for that
  process at start time; if WoW is minimized or not yet launched when you
  hit "Start Recording", pick it again from the menu once it's up.
- Ad-hoc code signing (`codesign --sign -`) is fine for personal use but its
  identity can shift between rebuilds, occasionally forcing you to
  re-approve permissions. If that gets annoying, create a free self-signed
  certificate in Keychain Access and sign with that instead.
