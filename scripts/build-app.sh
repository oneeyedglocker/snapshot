#!/bin/bash
# Builds the SPM executable and packages it into Snapshot.app so macOS treats
# it as a real app: stable TCC (Screen Recording / Accessibility) permission
# entries, an Info.plist, no dock icon (LSUIElement).
set -euo pipefail

cd "$(dirname "$0")/.."

echo "Building (release)..."
# Use xcrun rather than a bare `swift` — on some machines PATH resolves
# `swift` to an unrelated tool (e.g. the OpenStack `python-swiftclient`
# package installs its own `swift` entry point). xcrun goes straight to the
# active Xcode's toolchain, bypassing PATH entirely.
xcrun swift build -c release

APP_DIR="build/Snapshot.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"

cp ".build/release/Snapshot" "$APP_DIR/Contents/MacOS/Snapshot"
cp "Packaging/Info.plist" "$APP_DIR/Contents/Info.plist"

# Ad-hoc signing (the default, "-") gives every rebuild a different signing
# identity, so macOS/TCC treats each build as a new, unrecognized app and
# re-prompts for Screen Recording/Accessibility every time. Set
# SNAPSHOT_SIGN_IDENTITY to a certificate's name (e.g. one you made via
# Keychain Access > Certificate Assistant > Create a Certificate, type "Code
# Signing") to get a stable identity whose permission grants survive rebuilds.
SIGN_IDENTITY="${SNAPSHOT_SIGN_IDENTITY:--}"
echo "Signing (identity: $SIGN_IDENTITY)..."
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR"
if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "Note: ad-hoc signature — expect repeat permission prompts on future"
    echo "rebuilds. See README 'Permissions' section to make this stable."
fi

echo "Built $APP_DIR"
echo "Run it with: open $APP_DIR"
