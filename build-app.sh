#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="iPad Mirror"
INSTALL_DIR="/Applications"

echo "=== Building $APP_NAME ==="

# Build with Xcode
xcodebuild \
    -project "$SCRIPT_DIR/iPadMirror.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -derivedDataPath "$SCRIPT_DIR/.build/xcode" \
    build 2>&1 | grep -E "BUILD|error:|warning:" || true

BUILD_PRODUCT="$SCRIPT_DIR/.build/xcode/Build/Products/Release/$APP_NAME.app"

if [ ! -d "$BUILD_PRODUCT" ]; then
    echo "Build failed!"
    exit 1
fi

# Kill the app if running
pkill -x "iPad Mirror" 2>/dev/null || true
sleep 1

# Remove old copies from both locations
rm -rf "$HOME/Applications/$APP_NAME.app" 2>/dev/null || true
rm -rf "$INSTALL_DIR/$APP_NAME.app" 2>/dev/null || true

# Install to /Applications (system-level, better Siri discovery)
echo "Installing to $INSTALL_DIR..."
cp -R "$BUILD_PRODUCT" "$INSTALL_DIR/$APP_NAME.app"

# Unregister stale copies from Launch Services
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
"$LSREGISTER" -u "$HOME/Applications/$APP_NAME.app" 2>/dev/null || true
"$LSREGISTER" -u "$BUILD_PRODUCT" 2>/dev/null || true

# Re-register with Launch Services so Siri and Spotlight discover the app
echo "Registering with Launch Services..."
"$LSREGISTER" -f "$INSTALL_DIR/$APP_NAME.app"

# Reset Siri's shortcut index for this app by poking the database
echo "Resetting Siri shortcut cache..."
killall siriactionsd 2>/dev/null || true
sleep 1

echo ""
echo "=== Done! ==="
echo "App installed to $INSTALL_DIR/$APP_NAME.app"
echo ""
echo "To launch:"
echo "  open '/Applications/iPad Mirror.app'"
echo ""
echo "The app will register its Siri phrases on launch."
echo "Siri phrases:"
echo "  'Hey Siri, connect iPad Mirror'"
echo "  'Hey Siri, disconnect iPad Mirror'"
echo "  'Hey Siri, toggle iPad Mirror'"
echo "  'Hey Siri, is iPad Mirror connected'"
echo ""
echo "If Siri still doesn't recognize phrases, try:"
echo "  1. Quit and relaunch the app"
echo "  2. Wait ~30 seconds for Siri to index"
echo "  3. Check System Settings > Siri & Spotlight > App Shortcuts"
