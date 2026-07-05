#!/bin/bash
# Build SnapShelf.app into ~/Applications. No Apple Developer account needed —
# ad-hoc signed, personal use only.
set -e
cd "$(dirname "$0")"

swiftc -O -swift-version 5 main.swift -o SnapShelf

APP="$HOME/Applications/SnapShelf.app"
mkdir -p "$APP/Contents/MacOS"
cp SnapShelf "$APP/Contents/MacOS/SnapShelf"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

# Ad-hoc signature changes every build, which silently invalidates the old
# Screen Recording grant (toggle still shows on, capture fails). Clear it so
# macOS re-prompts cleanly on first capture.
tccutil reset ScreenCapture local.luke.snapshelf >/dev/null 2>&1 || true

echo "Built: $APP"
echo "Note: grant Screen Recording again on first capture (rebuild resets it)."
echo "Open with: open \"$APP\""
