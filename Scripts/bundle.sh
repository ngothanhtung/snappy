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

# Copy any custom resources (e.g. MenuBarIcon.png, AppIcon.icns) into the app.
if [ -d "$ROOT/Resources" ]; then
    echo "==> Copying Resources/"
    cp -R "$ROOT/Resources/." "$APP/Contents/Resources/" 2>/dev/null || true
fi

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

echo "==> Code signing"
# IMPORTANT: macOS ties the Accessibility (TCC) grant to the code signature.
# Ad-hoc signing (`--sign -`) produces a NEW cdhash on every rebuild, which
# INVALIDATES the previously granted permission — so window control silently
# stops working after each rebuild until you re-grant.
#
# To keep the grant stable across rebuilds, sign with a stable self-signed
# identity and pass its name via MAGNET_SIGN_IDENTITY. One-time setup:
#
#   Keychain Access ▸ Certificate Assistant ▸ Create a Certificate…
#     Name: "Magnet Self-Signed"   Type: Code Signing
#   then: export MAGNET_SIGN_IDENTITY="Magnet Self-Signed"
#
IDENTITY="${MAGNET_SIGN_IDENTITY:-}"
if [ -n "$IDENTITY" ]; then
    echo "    Signing with stable identity: $IDENTITY"
    codesign --force --options runtime --sign "$IDENTITY" "$APP"
else
    echo "    WARNING: no MAGNET_SIGN_IDENTITY set — using ad-hoc signature."
    echo "    The Accessibility grant will NOT survive rebuilds; you must"
    echo "    re-grant permission after each build (see README)."
    codesign --force --sign - "$APP"
fi

echo "==> Done: $APP"
echo "    Launch with: open \"$APP\""
echo "    First launch will prompt for Accessibility permission."
