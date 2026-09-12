#!/usr/bin/env bash
# Builds Resources/AppIcon.icns from Scripts/make-icon.swift.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"

swiftc -swift-version 6 -O "$ROOT/Scripts/make-icon.swift" -o "$WORK/make-icon"
"$WORK/make-icon" "$ICONSET"

# iconutil is strict about which names it accepts; drop anything it does not expect.
cd "$ICONSET"
for f in *.png; do
    case "$f" in
        icon_16x16.png|icon_16x16@2x.png|icon_32x32.png|icon_32x32@2x.png|\
icon_128x128.png|icon_128x128@2x.png|icon_256x256.png|icon_256x256@2x.png|\
icon_512x512.png|icon_512x512@2x.png) ;;
        *) rm -f "$f" ;;
    esac
done

mkdir -p "$ROOT/Resources"
iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
echo "Built $ROOT/Resources/AppIcon.icns"
