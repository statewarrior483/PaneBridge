#!/bin/bash
# Builds a universal PaneBridge.app and packages it as dist/PaneBridge-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.1.0}"
APP="dist/PaneBridge.app"
DMG="dist/PaneBridge-${VERSION}.dmg"

echo "==> Building universal binary (Apple Silicon + Intel)"
swift build -c release --arch arm64 --arch x86_64
BIN_DIR=".build/out/Products/Release"
[ -x "$BIN_DIR/PaneBridge" ] || BIN_DIR=".build/apple/Products/Release"

echo "==> Assembling $APP"
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/PaneBridge" "$APP/Contents/MacOS/PaneBridge"
cp Sources/PaneBridge/Resources/client.html "$APP/Contents/Resources/client.html"
# WebRTC (low-latency UDP video) ships as a framework next to the binary.
WEBRTC=$(find .build/artifacts -path "*macos*/WebRTC.framework" -maxdepth 6 -type d | head -1)
[ -n "$WEBRTC" ] || { echo "WebRTC.framework not found; run: swift package resolve" >&2; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
ditto "$WEBRTC" "$APP/Contents/Frameworks/WebRTC.framework"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>PaneBridge</string>
  <key>CFBundleDisplayName</key><string>PaneBridge</string>
  <key>CFBundleIdentifier</key><string>app.panebridge.PaneBridge</string>
  <key>CFBundleExecutable</key><string>PaneBridge</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Sign with a stable self-signed certificate if one is set up (scripts/setup-signing.sh).
# macOS ties Screen Recording / Accessibility permissions to the signature; with ad-hoc
# signing every build looks like a brand-new app and permissions must be granted again.
SIGN_DIR="$HOME/Library/Application Support/PaneBridge-Signing"
SIGN_KC="$SIGN_DIR/signing.keychain-db"
if [ -f "$SIGN_KC" ] && [ -f "$SIGN_DIR/pw" ]; then
  echo "==> Signing with the PaneBridge self-signed certificate (not notarized)"
  security unlock-keychain -p "$(cat "$SIGN_DIR/pw")" "$SIGN_KC"
  IDENTITY=$(security find-identity -p codesigning "$SIGN_KC" | awk '/PaneBridge Self-Signed/ {print $2; exit}')
  # codesign only finds identities in the search list, so add the keychain just for this call.
  ORIG_KCS=$(security list-keychains -d user | tr -d '"' | xargs)
  restore_keychains() { security list-keychains -d user -s $ORIG_KCS; }
  trap restore_keychains EXIT
  security list-keychains -d user -s $ORIG_KCS "$SIGN_KC"
  codesign --force --deep --sign "$IDENTITY" "$APP"
  restore_keychains
  trap - EXIT
else
  echo "==> Ad-hoc signing (run scripts/setup-signing.sh so permissions survive updates)"
  codesign --force --deep --sign - "$APP"
fi
codesign -dr - "$APP" 2>&1 | grep designated

echo "==> Creating $DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "PaneBridge" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "==> Done: $DMG ($(du -h "$DMG" | cut -f1))"
