# Verbatim

Real-time speech-to-text for macOS. Hold a shortcut, speak, and your words are transcribed instantly — powered by on-device ML models.

## Install

### Option A — Homebrew (recommended)

```bash
brew install --cask xofvr/tap/verbatim
```

Homebrew downloads Verbatim, installs it to **Applications**, and clears the
macOS "quarantine" flag for you — so it just opens, no extra steps. Update
later with `brew upgrade --cask verbatim`.

### Option B — Direct download

1. Grab the latest `.dmg` from [**Releases**](../../releases)
2. Open it and drag **Verbatim** into **Applications**
3. Run this once in **Terminal**, then open Verbatim normally:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Verbatim.app
   ```

> **Why the extra step for Option B?** Verbatim isn't notarized by Apple yet
> (that needs a paid Apple Developer account). macOS tags anything downloaded
> from the web with a "quarantine" flag and blocks un-notarized apps — sometimes
> with a misleading *"Verbatim is damaged and can't be opened"* message. The app
> is **not** actually damaged; the command just removes that download flag.
> Homebrew (Option A) does this for you automatically.

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

On Xcode 16/26 the **Metal Toolchain** is a separate download, and the MLX
dependency needs it to compile its shaders. Install it once:

```bash
xcodebuild -downloadComponent MetalToolchain
```

Then build:

```bash
# Clone the repo
git clone <repo-url>
cd Verbatim

# Open in Xcode
open Verbatim.xcodeproj

# Or build a distributable .dmg from the command line
./scripts/build-release.sh
```

The build script outputs a correctly-sealed `.dmg` in `build-release/`.

By default it produces an **ad-hoc signed** build (free, no Apple account
needed). To produce a **notarized** build that opens with a plain double-click,
set up an Apple Developer account and export these before running the script:

```bash
export DEVELOPER_ID_APP="Developer ID Application: Your Name (TEAMID)"
export NOTARY_PROFILE="verbatim"   # created via: xcrun notarytool store-credentials
```
