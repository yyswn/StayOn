#!/bin/bash
# Builds StayOn.app (Apple silicon and Intel, macOS 13+) and packages StayOn.dmg.
# Nothing is installed; the result is written to this folder.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/StayOn.app"
rm -rf build StayOn.dmg
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/stage

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos13" StayOn.swift -o "build/StayOn-$arch"
done
lipo -create build/StayOn-arm64 build/StayOn-x86_64 -output "$APP/Contents/MacOS/StayOn"
cp Info.plist "$APP/Contents/Info.plist"

swiftc -swift-version 5 make-icon.swift -o build/make-icon
build/make-icon build/icon.png
ICONSET=build/AppIcon.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" build/icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) build/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"

cp -R "$APP" build/stage/
ln -s /Applications build/stage/Applications
hdiutil create -quiet -volname StayOn -srcfolder build/stage -ov -format UDZO StayOn.dmg
hdiutil verify -quiet StayOn.dmg

echo "Built $(pwd)/StayOn.dmg"
