#!/bin/zsh
# Builds BlockWidgets.app next to this script.
set -euo pipefail
cd "${0:A:h}"
APP=BlockWidgets.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -O -o "$APP/Contents/MacOS/BlockWidgets" Sources/main.swift -framework Cocoa -framework ServiceManagement -framework CoreLocation -framework IOKit -framework CoreWLAN -framework Network
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Block Widgets</string>
  <key>CFBundleIdentifier</key><string>local.blockwidgets</string>
  <key>CFBundleExecutable</key><string>BlockWidgets</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocationUsageDescription</key><string>Чтобы показывать погоду там, где вы находитесь.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>Чтобы показывать погоду там, где вы находитесь.</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $PWD/$APP"
