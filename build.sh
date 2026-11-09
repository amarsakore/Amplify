#!/bin/zsh
# Builds Amplify.app (menu bar audio booster) with the Swift command line tools.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Amplify.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Universal binary (Apple silicon + Intel). macOS 14.2 is the first release with process taps.
MIN_MACOS=14.2
for ARCH in arm64 x86_64; do
  swiftc -O -parse-as-library -swift-version 5 \
    -target "$ARCH-apple-macos$MIN_MACOS" \
    -framework SwiftUI -framework AppKit -framework CoreAudio -framework AudioToolbox -framework ServiceManagement \
    Sources/*.swift -o "build/Amplify-$ARCH"
done
lipo -create build/Amplify-arm64 build/Amplify-x86_64 -output "$APP/Contents/MacOS/Amplify"
rm build/Amplify-arm64 build/Amplify-x86_64

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Amplify</string>
  <key>CFBundleDisplayName</key><string>Amplify</string>
  <key>CFBundleIdentifier</key><string>com.amplify.menubar</string>
  <key>CFBundleExecutable</key><string>Amplify</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.2</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAudioCaptureUsageDescription</key>
  <string>Amplify captures the audio playing on your Mac so it can boost its volume.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $PWD/$APP"
