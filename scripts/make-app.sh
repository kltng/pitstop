#!/bin/zsh
# Build PitStop.app (menu bar app) and install it into /Applications.
# The bundle is ad-hoc signed, but that no longer matters for keychain
# access: PitStop goes through /usr/bin/security (same as Claude Code),
# so the keychain grant rides the stable Apple-signed CLI and survives
# rebuilds. No prompts after the one-time "Always Allow" per item.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="/Applications/PitStop.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/PitStop "$APP/Contents/MacOS/PitStop"
cp Resources/PitStop-Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Bake the marketing version (from ./VERSION), a monotonic build number (commit
# count), and this checkout's path into the installed bundle. The app reads the
# version to display it and to compare against GitHub Releases, and the source
# path to offer a one-click rebuild-from-source update.
VERSION="$(tr -d '[:space:]' < VERSION 2>/dev/null)"
VERSION="${VERSION:-0.0.0}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :PitStopSourcePath string $PWD" "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :PitStopSourcePath $PWD" "$PLIST"

codesign --force --sign - "$APP"

echo "Installed $APP (v$VERSION build $BUILD)"
