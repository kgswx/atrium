#!/bin/bash
# Builds Atrium, puts it in ~/Applications and starts it quietly, now and at every login.
# With --default it also becomes the file viewer for folders and "Show in Finder" (scripts/uninstall.sh undoes it).
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="$HOME/Applications/Atrium.app"
LABEL="io.kgswx.atrium"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

./scripts/build.sh
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x Atrium 2>/dev/null || true

mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
rm -rf "$DEST"
cp -R build/Atrium.app "$DEST"
# Only the installed copy should answer for io.kgswx.atrium.
"$LSREGISTER" -u build/Atrium.app 2>/dev/null || true
"$LSREGISTER" -f "$DEST"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$DEST/Contents/MacOS/Atrium</string><string>--background</string></array>
    <key>RunAtLoad</key><true/>
    <key>ProcessType</key><string>Interactive</string>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
PLIST
launchctl bootstrap "gui/$(id -u)" "$PLIST"

if [ "${1:-}" = "--default" ]; then "$DEST/Contents/MacOS/Atrium" --make-default; fi
echo "Installed $DEST. It is running in the background: press Option+Command+E, or open Atrium from Spotlight."
