#!/bin/bash
# Builds build/Atrium.app: a release binary from the Swift package, Info.plist, icon, signature.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
SIGN_ID="${SIGN_ID:--}"   # "-" signs ad hoc; a real identity keeps folder permissions across rebuilds
APP="build/Atrium.app"

# Universal when the toolchain can (Xcode), Apple silicon only otherwise (Command Line Tools).
if swift build -c release --arch arm64 --arch x86_64 >/dev/null 2>&1; then
  BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
else
  swift build -c release
  BIN_DIR="$(swift build -c release --show-bin-path)"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Atrium" "$APP/Contents/MacOS/Atrium"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"

if [ ! -f build/AppIcon.icns ]; then
  swift scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/"

codesign --force --sign "$SIGN_ID" "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Atrium"), $(du -sh "$APP" | cut -f1))"
