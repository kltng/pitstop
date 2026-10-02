#!/bin/zsh
# Build PitStop.app (menu bar app) and install it into /Applications.
# The bundle is ad-hoc signed, but that no longer matters for keychain
# access: PitStop goes through /usr/bin/security (same as Claude Code),
# so the keychain grant rides the stable Apple-signed CLI and survives
# rebuilds. No prompts after the one-time "Always Allow" per item.
set -euo pipefail
cd "$(dirname "$0")/.."

# PitStop's SwiftUI views need the SwiftUIMacros compiler plugin, which ships
# with Xcode but not with the standalone Command Line Tools. If the active
# developer dir lacks it (and DEVELOPER_DIR isn't already set), build with an
# installed Xcode instead — otherwise swift build dies with an opaque
# "Unknown error parsing property list" / "plugin for module 'SwiftUIMacros'
# not found".
has_swiftui_macros() {
  [[ -e "$1/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]]
}
if [[ -z "${DEVELOPER_DIR:-}" ]] && ! has_swiftui_macros "$(xcode-select -p 2>/dev/null)"; then
  for xcode in /Applications/Xcode.app /Applications/Xcode*.app(N) \
      ${(f)"$(mdfind 'kMDItemCFBundleIdentifier == "com.apple.dt.Xcode"' 2>/dev/null)"}; do
    if has_swiftui_macros "$xcode/Contents/Developer"; then
      export DEVELOPER_DIR="$xcode/Contents/Developer"
      echo "Building with $xcode (the active Command Line Tools lack SwiftUI macros)"
      break
    fi
  done
  if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    echo "error: building PitStop needs Xcode (for SwiftUI macros); install it from the App Store." >&2
    exit 1
  fi
fi

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
