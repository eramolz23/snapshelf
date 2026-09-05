#!/bin/bash
# Compile the real app types with synthetic tests instead of starting the app.
set -euo pipefail
cd "$(dirname "$0")"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/snapshelf-tests.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
awk '/^let app = NSApplication.shared$/ { exit } { print }' main.swift > "$scratch/main.swift"
if [[ "${1:-}" == "--review" ]]; then
    app="dist/SnapShelfReview.app"
    mkdir -p "$app/Contents/MacOS"
    cat tests/review.swift >> "$scratch/main.swift"
    swiftc -swift-version 5 "$scratch/main.swift" -o "$app/Contents/MacOS/SnapShelfReview"
    cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SnapShelfReview</string>
<key>CFBundleIdentifier</key><string>local.luke.snapshelf.review</string>
<key>CFBundleName</key><string>SnapShelf Review</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
    codesign --force --sign - "$app"
    echo "Review bundle: $PWD/$app"
    echo "Launch with: open '$PWD/$app'"
    exit 0
fi
cat tests/regression.swift >> "$scratch/main.swift"
swiftc -swift-version 5 "$scratch/main.swift" -o "$scratch/regression"
"$scratch/regression"
