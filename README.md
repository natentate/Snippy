# Snippy

A native macOS menu bar app for screenshots and screen recordings, in the spirit of CleanShot X. Built with Swift, AppKit, SwiftUI and ScreenCaptureKit, with no third-party dependencies.

**Requires macOS 14 Sonoma or later** (Apple silicon and Intel).

## Features

| Area | What you get |
|---|---|
| **Screenshots** | Capture an area (frozen screen, crosshair, pixel magnifier, size readout, Shift for a square), a window (transparent background, optional shadow), the full screen, the previous area again, or use a 5-second self-timer |
| **Scrolling capture** | Select a region, scroll, and the frames are stitched into one tall image |
| **Text capture (OCR)** | Select any area and the text is copied to the clipboard. Uses Apple's on-device Vision framework |
| **Screen recording** | MP4 (H.264, or HEVC above 4K) of an area, a window or the full screen. Options: 24/30/60 fps, cursor, click highlighting, system audio, microphone (macOS 15+), countdown |
| **GIF recording** | Same flow as video, exported as a looping GIF with your chosen fps and maximum width |
| **Quick Access overlay** | A thumbnail appears in the screen corner after each capture. From it you can copy, save, show in Finder, annotate, pin, or drag the file into any app |
| **Annotation editor** | Arrow, line, rectangle, filled rectangle, ellipse, pen, highlighter, text, numbered counters, pixelate, blur, spotlight and crop. Also: colour palette and picker, stroke sizes, select/move/delete, undo/redo, copy, save, share, pin |
| **Pinned screenshots** | An always-on-top floating image. Drag it to move, scroll to zoom; right-click for opacity, copy, save or annotate |
| **Hide desktop icons** | Covers desktop clutter with your wallpaper, and the cover shows in captures |
| **History** | The last 30 captures, under *Recent Captures* in the menu |
| **Global shortcuts** | Every action has a shortcut you can change in Settings |
| **Other** | Launch at login, PNG/JPEG/HEIC output, custom save folder, open any image or the clipboard image in the editor |

### Default shortcuts

| Action | Shortcut |
|---|---|
| Capture Area | ⌃⇧4 |
| Capture Fullscreen | ⌃⇧3 |
| Capture Window | ⌃⇧W |
| Capture Previous Area | ⌃⇧P |
| Scrolling Capture | ⌃⇧S |
| Capture Text (OCR) | ⌃⇧T |
| Record Screen (press again to stop) | ⌃⇧5 |
| Record GIF (press again to stop) | ⌃⇧6 |

While selecting:
- **Space** switches between area and window mode.
- **Return** captures the whole screen.
- **Esc** cancels.

In the editor, each tool has a single-letter shortcut (A arrow, R rectangle, T text, X pixelate, C crop, and so on).

## Install

### Option A: download the DMG

1. Open the repository's **Actions** tab, then the latest **Build** run, and download the **Snippy-dmg** artifact. If there is a tagged release, download the `.dmg` from **Releases** instead.
2. Open the DMG and drag **Snippy** to **Applications**.
3. The build is ad-hoc signed and not notarized, so macOS blocks the first launch. Right-click the app and choose **Open**, or run:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Snippy.app
   ```
4. When prompted, grant **Screen & System Audio Recording** permission (System Settings › Privacy & Security). Then quit Snippy and reopen it.

### Option B: build from source

You need Xcode 16 or later, or its Command Line Tools.

```bash
git clone https://github.com/natentate/Snippy.git
cd Snippy
make install        # builds for this Mac, copies to /Applications and launches
# or
make dmg            # universal build: build/Snippy.app + build/Snippy-<version>.dmg
```

> **Note:** an ad-hoc signature changes on every build, so macOS may ask for Screen Recording permission again after an update. Signing with a stable identity avoids this (see below).

### Signed + notarized release (optional)

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="your-notarytool-profile" \
./scripts/build-app.sh
```

To publish a GitHub Release with the DMG attached, push a tag such as `v1.0.0`.

## Project layout

```
Sources/Snippy/
  App/        entry point, menu bar, capture workflows
  Capture/    ScreenCaptureKit wrapper, selection overlay, scrolling capture, OCR
  Recording/  SCStream → AVAssetWriter recorder, GIF exporter
  Editor/     annotation model and renderer, canvas, editor window
  Output/     quick access overlay, pinned images, history, HUD and overlays
  Settings/   SwiftUI settings window
  Support/    preferences, global hotkeys, utilities
Resources/    Info.plist, entitlements
scripts/      build-app.sh (bundle, sign, DMG), make-icon.swift
```
