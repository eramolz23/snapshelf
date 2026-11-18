#!/bin/bash
# Package SnapShelf for distribution: builds into dist/, ad-hoc signs, zips.
# Unlike build.sh this never touches ~/Applications and never resets TCC grants,
# so it is safe to run while your installed copy is in use.
set -e
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)

MIN_OS=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)

rm -rf dist
APP="dist/SnapShelf.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Universal binary (Apple Silicon + Intel). The explicit -target also pins the
# deployment target: without it swiftc stamps the build machine's OS version as
# the minimum, and the app refuses to launch on anything older.
for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -target "$arch-apple-macos$MIN_OS" main.swift -o "dist/SnapShelf-$arch"
done
lipo -create dist/SnapShelf-arm64 dist/SnapShelf-x86_64 -output "$APP/Contents/MacOS/SnapShelf"
rm dist/SnapShelf-arm64 dist/SnapShelf-x86_64
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

ditto -c -k --keepParent "$APP" "dist/SnapShelf-$VERSION.zip"
echo "Release artifact: dist/SnapShelf-$VERSION.zip"
