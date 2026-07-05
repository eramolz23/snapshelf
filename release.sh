#!/bin/bash
# Package SnapShelf for distribution: builds into dist/, ad-hoc signs, zips.
# Unlike build.sh this never touches ~/Applications and never resets TCC grants,
# so it is safe to run while your installed copy is in use.
set -e
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)

swiftc -O -swift-version 5 main.swift -o SnapShelf

rm -rf dist
APP="dist/SnapShelf.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp SnapShelf "$APP/Contents/MacOS/SnapShelf"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

ditto -c -k --keepParent "$APP" "dist/SnapShelf-$VERSION.zip"
echo "Release artifact: dist/SnapShelf-$VERSION.zip"
