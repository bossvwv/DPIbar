#!/bin/bash
set -e
cd "$(dirname "$0")"

APP="DPIBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 1. Compile
swiftc -O DPIBar.swift -o "$APP/Contents/MacOS/DPIBar"

# 2. Optional custom menu bar icon
if [ -f MenuIcon.png ]; then
    cp MenuIcon.png "$APP/Contents/Resources/"
fi

# 3. App metadata (LSUIElement = menu bar only, no Dock icon)
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>DPIBar</string>
  <key>CFBundleDisplayName</key><string>DPIBar</string>
  <key>CFBundleIdentifier</key><string>com.example.dpibar</string>
  <key>CFBundleExecutable</key><string>DPIBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# 4. Ad-hoc sign so macOS will run it and remember its permissions
codesign --force --deep --sign - "$APP"

echo "Built $APP"
