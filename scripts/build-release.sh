#!/bin/zsh
set -euo pipefail

# ─── Verbatim Release Builder ───
# Builds a distributable .dmg for sharing with the team.
# Usage: ./scripts/build-release.sh

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$PROJECT_DIR/Verbatim.xcodeproj"
SCHEME="Verbatim"
ARCHIVE_PATH="$PROJECT_DIR/build-release/Verbatim.xcarchive"
EXPORT_DIR="$PROJECT_DIR/build-release/export"
DMG_PATH="$PROJECT_DIR/build-release/Verbatim.dmg"

echo "🔨 Building Verbatim (Release)..."
echo ""

# Clean previous build artifacts
rm -rf "$PROJECT_DIR/build-release"
mkdir -p "$EXPORT_DIR"

# Archive
xcodebuild archive \
    -skipMacroValidation \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGN_IDENTITY="-" \
    ONLY_ACTIVE_ARCH=NO \
    2>&1 | tail -5

# The .app lives inside the archive
APP_PATH="$ARCHIVE_PATH/Products/Applications/Verbatim.app"

if [ ! -d "$APP_PATH" ]; then
    echo "❌ Build failed — Verbatim.app not found in archive."
    exit 1
fi

# Copy .app to export directory
cp -R "$APP_PATH" "$EXPORT_DIR/Verbatim.app"

# Get version from the built app
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$EXPORT_DIR/Verbatim.app/Contents/Info.plist" 2>/dev/null || echo "unknown")

# Create a .dmg with Applications symlink for drag-to-install
DMG_STAGING="$PROJECT_DIR/build-release/dmg-staging"
mkdir -p "$DMG_STAGING"
cp -R "$EXPORT_DIR/Verbatim.app" "$DMG_STAGING/"
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

# Clean up staging
rm -rf "$DMG_STAGING" "$ARCHIVE_PATH" "$EXPORT_DIR"

echo ""
echo "✅ Done! Distributable ready:"
echo "   $DMG_PATH"
echo ""
echo "Share this .dmg with your team. They open it, drag Verbatim to Applications, done."
