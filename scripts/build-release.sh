#!/bin/zsh
set -euo pipefail

# ─── Verbatim Release Builder ───
# Builds a distributable, properly-sealed .dmg.
#
# Two modes, chosen automatically:
#
#   1. AD-HOC (default, free, no Apple account needed)
#      The whole app bundle is sealed with a valid ad-hoc signature + hardened
#      runtime. This fixes the "Verbatim is damaged and can't be opened" error
#      that an unsealed bundle triggers after a quarantined download.
#      Users still clear quarantine once after downloading (see README).
#
#   2. DEVELOPER ID + NOTARIZED (frictionless double-click install)
#      Requires a paid Apple Developer account. Set these env vars:
#
#        export DEVELOPER_ID_APP="Developer ID Application: Your Name (TEAMID)"
#        export NOTARY_PROFILE="verbatim"
#
#      Create the notarytool keychain profile once:
#        xcrun notarytool store-credentials "verbatim" \
#            --apple-id you@example.com --team-id TEAMID \
#            --password <app-specific-password>
#
# Usage: ./scripts/build-release.sh

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$PROJECT_DIR/Verbatim.xcodeproj"
SCHEME="Verbatim"
ARCHIVE_PATH="$PROJECT_DIR/build-release/Verbatim.xcarchive"
EXPORT_DIR="$PROJECT_DIR/build-release/export"
ENTITLEMENTS="$PROJECT_DIR/Verbatim/Verbatim.entitlements"

DEVELOPER_ID_APP="${DEVELOPER_ID_APP:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

# Decide signing mode
if [[ -n "$DEVELOPER_ID_APP" ]]; then
    SIGN_IDENTITY="$DEVELOPER_ID_APP"
    TS_FLAG="--timestamp"           # secure timestamp required for notarization
    NOTARIZE=1
    echo "🔏 Signing mode: Developer ID — $DEVELOPER_ID_APP"
    if [[ -z "$NOTARY_PROFILE" ]]; then
        echo "⚠️  DEVELOPER_ID_APP is set but NOTARY_PROFILE is not — will sign but NOT notarize."
        NOTARIZE=0
    fi
else
    SIGN_IDENTITY="-"               # ad-hoc
    TS_FLAG="--timestamp=none"
    NOTARIZE=0
    echo "🔏 Signing mode: ad-hoc (set DEVELOPER_ID_APP + NOTARY_PROFILE to notarize)"
fi

echo "🔨 Building Verbatim (Release)..."
echo ""

# Clean previous build artifacts
rm -rf "$PROJECT_DIR/build-release"
mkdir -p "$EXPORT_DIR"

# Archive unsigned — we sign the whole bundle explicitly below so every nested
# binary (incl. Sparkle.framework) is sealed. (The old build left the bundle
# seal broken, which is what produced the "damaged" Gatekeeper error.)
xcodebuild archive \
    -skipMacroValidation \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGNING_ALLOWED=NO \
    ARCHS=arm64 \
    2>&1 | tail -5

APP_PATH="$ARCHIVE_PATH/Products/Applications/Verbatim.app"
if [ ! -d "$APP_PATH" ]; then
    echo "❌ Build failed — Verbatim.app not found in archive."
    exit 1
fi

cp -R "$APP_PATH" "$EXPORT_DIR/Verbatim.app"
APP="$EXPORT_DIR/Verbatim.app"

# ─── Sign: seal the entire bundle with hardened runtime + the app's entitlements ───
# --deep signs nested code (Sparkle.framework and its helpers) too. Hardened
# runtime is on for both modes (required for notarization, harmless for ad-hoc).
# NOTE (Developer ID): if notarization ever rejects a nested Sparkle binary,
# sign Sparkle's XPCServices / Autoupdate / Updater.app individually first —
# see https://sparkle-project.org/documentation/sandboxing/ and the Sparkle
# code-signing guide. The ad-hoc path below is verified to produce a valid seal.
echo "🔏 Sealing bundle..."
codesign --force --deep --options runtime $TS_FLAG \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" \
    "$APP"

# Fail loudly if the seal is not valid — this is the check the old script lacked.
codesign --verify --deep --strict --verbose=2 "$APP"
echo "   seal verified ✓"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || echo "unknown")

# ─── Notarize the app (Developer ID mode only) ───
if [[ "$NOTARIZE" == "1" ]]; then
    echo "📤 Notarizing app (this can take a few minutes)..."
    ZIP="$PROJECT_DIR/build-release/Verbatim.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    echo "   app notarized + stapled ✓"
fi

# ─── Build the .dmg with an Applications symlink for drag-to-install ───
DMG_STAGING="$PROJECT_DIR/build-release/dmg-staging"
mkdir -p "$DMG_STAGING"
cp -R "$APP" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

DMG_NAME="Verbatim-${VERSION}.dmg"
DMG_PATH="$PROJECT_DIR/build-release/$DMG_NAME"

hdiutil create \
    -volname "Verbatim" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDZO \
    "$DMG_PATH" \
    2>&1 | tail -3

rm -rf "$DMG_STAGING"

# ─── Sign + notarize + staple the .dmg itself (Developer ID mode only) ───
if [[ "$NOTARIZE" == "1" ]]; then
    echo "📤 Notarizing DMG..."
    codesign --force $TS_FLAG --sign "$DEVELOPER_ID_APP" "$DMG_PATH"
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG_PATH"
    echo "   DMG notarized + stapled ✓"
fi

# Clean up intermediate artifacts
rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR"

echo ""
echo "✅ Done! Distributable ready:"
echo "   $DMG_PATH"
echo ""
if [[ "$NOTARIZE" == "1" ]]; then
    echo "This DMG is notarized — users just double-click and open. 🎉"
else
    echo "Ad-hoc build. The app is correctly sealed (no more 'damaged' error),"
    echo "but because it isn't notarized, after downloading users run once:"
    echo "   xattr -dr com.apple.quarantine /Applications/Verbatim.app"
fi
