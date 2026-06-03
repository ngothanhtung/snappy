#!/bin/bash
# Builds Magnet in release mode and assembles a Magnet.app bundle.
# Usage: ./Scripts/bundle.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Magnet.app"
BUNDLE_ID="com.local.magnet"

echo "==> Building release binary"
swift build -c release --product Magnet

BIN="$(swift build -c release --product Magnet --show-bin-path)/Magnet"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Magnet"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Magnet</string>
    <key>CFBundleDisplayName</key>     <string>Magnet</string>
    <key>CFBundleExecutable</key>      <string>Magnet</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <!-- Agent app: no Dock icon, menu-bar only. -->
    <key>LSUIElement</key>             <true/>
</dict>
</plist>
PLIST

echo "==> Ad-hoc code signing"
# Stable signature keeps the Accessibility grant across rebuilds.
codesign --force --deep --sign - "$APP"

echo "==> Done: $APP"
echo "    Launch with: open \"$APP\""
echo "    First launch will prompt for Accessibility permission."
