#!/usr/bin/env bash
# Wraps the S2+S4 spike in a signed .app so TCC has a stable bundle to grant Accessibility to.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP="$ROOT/.build/ClipRoidSpike.app"
BUNDLE_ID="dev.philtronic.ClipRoidSpike"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -swift-version 6 "$ROOT/Spikes/SpikeApp/main.swift" -o "$APP/Contents/MacOS/ClipRoidSpike"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>ClipRoidSpike</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>ClipRoidSpike</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <!-- Accessory: no Dock icon, no menu bar. Backgrounded on purpose — the hotkey has to work
         when the app is not frontmost, which is the whole point of the test. -->
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign "ClipRoid Development" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"
