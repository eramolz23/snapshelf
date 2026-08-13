# SnapShelf

A tiny macOS menu-bar screenshot tool. Capture with a hotkey, and the shot pins as a
floating thumbnail in the bottom-left corner until you're done with it — copy it, drag
it into any window, mark it up, crop, blur secrets, extract its text, or share a link.

Single Swift file, no dependencies, no Apple Developer account needed.

## Features

- **Capture**: `⌃⌘2` area (press **Space** during selection for window capture),
  `⌃⌘1` full screen, or use the menu bar icon
- **Pinned thumbnails** stack bottom-left and stay until dismissed (✕)
- **Auto-copy** — every capture is on the clipboard immediately
- **Drag** a thumbnail into any window (Slack, Finder, mail…) to drop the PNG
- **Click** a thumbnail → big centered editor: pen, highlighter, arrow, box, text,
  blur/pixelate, crop — with per-stroke width (S/M/L), color picker, and full undo (⌘Z)
- **OCR** button — on-device text recognition straight to the clipboard
- **Link** button — uploads to [litterbox](https://litterbox.catbox.moe) and copies a
  share URL (public link, 72-hour expiry — blur secrets first)
- **History** window — searchable grid of every capture, including search by the
  *text inside* the screenshots (background OCR index)
- Captures persist in `~/Pictures/SnapShelf/` (auto-cleaned after 60 days)
- Starts at login (toggleable), Restart menu item

## Build & install

Requires Xcode Command Line Tools (`xcode-select --install`).

```sh
./build.sh
open ~/Applications/SnapShelf.app
```

Grant **Screen Recording** permission when prompted on first capture
(System Settings → Privacy & Security → Screen Recording).

Note: the build is ad-hoc signed, so every rebuild invalidates that permission —
`build.sh` resets it automatically and macOS will re-prompt once.

## Installing a prebuilt zip (no Xcode)

If you downloaded `SnapShelf-x.y.z.zip` (e.g. from a GitHub release): unzip and move
`SnapShelf.app` to `~/Applications`. The app isn't notarized (no Apple Developer
account), so the first launch is blocked once:

1. Double-click the app — macOS says it can't be opened.
2. Open **System Settings → Privacy & Security**, scroll down, click **Open Anyway**,
   and confirm. (On macOS 14 and earlier, right-click → Open → Open also works.)

Terminal alternative: `xattr -dr com.apple.quarantine ~/Applications/SnapShelf.app`,
then open normally. After the first launch it behaves like any other app.

## Cutting a release

```sh
./release.sh   # builds dist/SnapShelf-<version>.zip — no install, no permission reset
```

Bump `CFBundleShortVersionString` in `Info.plist` first. `gen_icon.sh` regenerates
`AppIcon.icns` if the icon design changes.

## Configuration

Constants at the top of `main.swift` — hotkeys, thumbnail size, cleanup age.
Edit and re-run `./build.sh`.
