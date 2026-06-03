#!/bin/bash
# Builds Magnet in release mode and assembles a Magnet.app bundle.
# Usage: ./Scripts/bundle.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Snappy.app"          # user-facing app name
BUNDLE_ID="com.local.magnet"    # internal identity (kept stable for TCC)

echo "==> Building release binary"
swift build -c release --product Magnet

BIN="$(swift build -c release --product Magnet --show-bin-path)/Magnet"

echo "==> Assembling $APP"
rm -rf "$APP" "$ROOT/Magnet.app" # drop any legacy bundle from before the rename
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Magnet"

# Copy any custom resources (e.g. MenuBarIcon.png) into the app.
if [ -d "$ROOT/Resources" ]; then
    echo "==> Copying Resources/"
    cp -R "$ROOT/Resources/." "$APP/Contents/Resources/" 2>/dev/null || true
fi

# App icon: Finder needs an .icns. Drop a square PNG at Resources/AppIcon.png
# (ideally 1024×1024) and it is converted automatically here.
ICON_PLIST=""
APP_ICON_PNG="$ROOT/Resources/AppIcon.png"
if [ -f "$APP_ICON_PNG" ]; then
    echo "==> Generating AppIcon.icns from AppIcon.png"
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
        sips -z "$s" "$s"             "$APP_ICON_PNG" --out "$ICONSET/icon_${s}x${s}.png"    >/dev/null
        sips -z "$((s*2))" "$((s*2))" "$APP_ICON_PNG" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    rm -f "$APP/Contents/Resources/AppIcon.png" # ship only the .icns
    ICON_PLIST="    <key>CFBundleIconFile</key>        <string>AppIcon</string>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Snappy</string>
    <key>CFBundleDisplayName</key>     <string>Snappy</string>
    <key>CFBundleExecutable</key>      <string>Magnet</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <!-- Agent app: no Dock icon, menu-bar only. -->
    <key>LSUIElement</key>             <true/>
$ICON_PLIST
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
if [ -n "$ICON_PLIST" ]; then
    touch "$APP" # nudge Finder to refresh the icon
    echo "    If Finder still shows the old icon, run: killall Finder"
fi
