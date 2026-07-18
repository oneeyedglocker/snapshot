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

echo "Signing (ad-hoc)..."
codesign --force --deep --sign - "$APP_DIR"

echo "Built $APP_DIR"
echo "Run it with: open $APP_DIR"
