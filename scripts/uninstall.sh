#!/bin/bash
# Gives "Show in Finder" back to Finder, stops Atrium and removes it and its login job.
set -euo pipefail
DEST="$HOME/Applications/Atrium.app"
LABEL="io.kgswx.atrium"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

if [ -x "$DEST/Contents/MacOS/Atrium" ]; then
  "$DEST/Contents/MacOS/Atrium" --restore-finder
else
  defaults delete -g NSFileViewer 2>/dev/null || true
fi
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
pkill -x Atrium 2>/dev/null || true
"$LSREGISTER" -u "$DEST" 2>/dev/null || true
rm -rf "$DEST"
echo "Atrium removed; Finder is the file viewer again. Settings stay in ~/Library/Preferences/io.kgswx.atrium.plist."
