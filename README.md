# Verbatim

Real-time speech-to-text for macOS. Hold a shortcut, speak, and your words are transcribed instantly — powered by on-device ML models.

## Download

Grab the latest `.dmg` from [**Releases**](../../releases).

## Install

1. Open the downloaded **Verbatim-x.x.x.dmg**
2. Drag **Verbatim** into **Applications**
3. Open Verbatim from Applications — macOS will block it the first time
4. Go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**
5. You only need to do this once

## First Launch

Verbatim runs in your **menu bar** (top-right of your screen). On first launch, you'll walk through a short setup:

- Grant **microphone** permission
- Grant **accessibility** permission (for the keyboard shortcut)
- Pick a transcription model
- Set your push-to-talk shortcut

## Requirements

- macOS 15 (Sequoia) or later
- Apple Silicon Mac (M1 or newer)

## Building from Source

You need Xcode 16+ installed.

```bash
# Clone the repo
git clone <repo-url>
cd Verbatim

# Open in Xcode
open Verbatim.xcodeproj

# Or build from the command line
./scripts/build-release.sh
```

The build script outputs a `.dmg` in `build-release/` that you can share directly.
