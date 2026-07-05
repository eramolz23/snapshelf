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

echo "Built: $APP"
echo "Open with: open \"$APP\""
