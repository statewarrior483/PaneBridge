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

echo "==> Ad-hoc signing (not notarized)"
codesign --force --deep --sign - "$APP"

echo "==> Creating $DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "PaneBridge" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "==> Done: $DMG ($(du -h "$DMG" | cut -f1))"
