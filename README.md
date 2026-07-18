# Snapshot

A tiny menu-bar app for macOS that does one thing: hold a rolling buffer of
your gameplay (15/30/60s, your choice) and, on a hotkey, save it as an mp4.
No OBS, no scenes, no config sprawl — an instant-replay button.

## How it works

- Captures via `ScreenCaptureKit`, bound to a specific app's window (default:
  World of Warcraft, auto-detected by name) or a specific display.
- Video is encoded to H.264 in real time (VideoToolbox, hardware accelerated)
  and kept in a **RAM ring buffer** — never written to disk until you save.
  This mirrors how OBS's own Replay Buffer works: encoded frames in memory,
  one write to disk on trigger. No continuous disk I/O, no temp file cleanup.
- Audio (system audio only, no mic) is buffered as raw PCM and AAC-encoded
  at save time.
- Default hotkey **⌘⇧R** saves the last N seconds (15/30/60, set via the
  **Clip Length** menu) to `~/Movies/Snapshot Clips/`. A brief on-screen
  toast (top-right corner, click-through, visible over fullscreen/windowed
  games) confirms the save succeeded — the menu bar icon flash alone is easy
  to miss mid-game.

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
   app (the game) has focus. Snapshot proactively triggers this prompt at
   launch (via `AXIsProcessTrustedWithOptions`); if you miss it or it never
   appeared, go to System Settings → Privacy & Security → Accessibility →
   enable Snapshot yourself, then relaunch the app.

### Making permissions stick across rebuilds

By default `build-app.sh` signs ad-hoc (`codesign --sign -`), which gives
every rebuild a *different* signing identity — macOS/TCC then treats each
build as an unrecognized app and re-prompts for both permissions every time,
even though an old build still shows as "granted" in System Settings (it's
a stale entry for a signature that no longer exists on disk).

One-time fix:

1. Keychain Access → **Certificate Assistant → Create a Certificate...** →
   name it anything (e.g. `Snapshot Local Dev`), Identity Type **Self Signed
   Root**, Certificate Type **Code Signing** → Create.
2. Clear out any stale grants from earlier ad-hoc builds:
   ```sh
   tccutil reset ScreenCapture com.oneeyedglocker.snapshot
   tccutil reset Accessibility com.oneeyedglocker.snapshot
   ```
3. Build with that identity from now on:
   ```sh
   SNAPSHOT_SIGN_IDENTITY="Snapshot Local Dev" ./scripts/build-app.sh
   open build/Snapshot.app
   ```
   Grant both permissions once when prompted. Future rebuilds signed with the
   same identity should keep the grant.

## Using it

Click the menu bar icon (● record icon):

- **Capture Target** — pick the app or display to record. Your choice is
  remembered and auto-selected next launch (falls back to searching for
  "World of Warcraft" by name if nothing's saved).
- **Clip Length** — 15s / 30s / 60s. Takes effect immediately, even mid-recording
  (no need to stop/restart). Persisted across launches.
- **Start/Stop Recording** — begins/ends the rolling buffer.
- **Save Last Ns Now** — same as the hotkey, useful without a keyboard.
- **Show Clips Folder** — opens `~/Movies/Snapshot Clips/` in Finder.

## Tuning

Everything's in `Sources/Snapshot/Settings.swift`:

- `exportSeconds` — clip length; user-adjustable at runtime via the Clip
  Length menu (backed by UserDefaults), defaults to 30s.
- `availableClipLengths` — the options offered in that menu (default
  `[15, 30, 60]`); add/remove values here.
- `bufferSeconds` — how much extra slack is kept in RAM beyond the export
  window, so trimming to a keyframe never comes up short (`exportSeconds +
  10`).
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
- Ad-hoc code signing (`codesign --sign -`) is fine for a one-off run but its
  identity shifts on every rebuild, forcing repeat permission prompts (and
  leaving stale "granted" entries in System Settings for old builds). See
  "Making permissions stick across rebuilds" above.
