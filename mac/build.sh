#!/bin/bash
# Builds "Hey Aside.app" (macOS 27+, Apple silicon).
#
#   ./build.sh            build into build/
#   ./build.sh install    build, then copy to ~/Applications
#
# Signing: macOS keeps microphone/speech permission grants only while the
# app's signature stays the same. Create a free self-signed "code signing"
# certificate named "Hey Aside Local Signing" in Keychain Access once
# (Certificate Assistant > Create a Certificate...), and every rebuild keeps
# its permissions. Without it the app is signed ad hoc and macOS asks again
# after each rebuild. Override the name with HEYASIDE_SIGN_ID.
set -euo pipefail
cd "$(dirname "$0")"
APP="build/Hey Aside.app"
IDENTITY="${HEYASIDE_SIGN_ID:-Hey Aside Local Signing}"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  echo "note: no \"$IDENTITY\" signing identity; signing ad hoc (permissions reset on each rebuild)"
  IDENTITY="-"
fi
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target arm64-apple-macos27.0 \
  -framework AppKit -framework AVFoundation -framework Speech -framework SwiftUI -framework ServiceManagement -framework CoreAudio -framework Metal -framework MetalKit -framework CoreText -framework WebKit \
  Sources/*.swift -o "$APP/Contents/MacOS/HeyAside"
cp Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/" || true
[ -d Resources/Chimes ] && cp -R Resources/Chimes "$APP/Contents/Resources/" || true
codesign --force -s "$IDENTITY" "$APP"
echo "built $APP"

if [ "${1:-}" = "install" ]; then
  pkill -f "Hey Aside.app/Contents/MacOS/HeyAside" 2>/dev/null || true
  mkdir -p "$HOME/Applications"; rm -rf "$HOME/Applications/Hey Aside.app"
  cp -R "$APP" "$HOME/Applications/"
  echo "installed ~/Applications/Hey Aside.app"
fi
