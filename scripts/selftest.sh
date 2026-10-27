#!/bin/bash
# Runs the debug self-test in a throwaway app bundle (it needs a real bundle so its window can become key).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
[ -d build/Atrium.app ] || ./scripts/build.sh
rm -rf build/AtriumSelfTest.app
cp -R build/Atrium.app build/AtriumSelfTest.app
cp .build/debug/Atrium build/AtriumSelfTest.app/Contents/MacOS/Atrium
codesign --force --sign - build/AtriumSelfTest.app >/dev/null 2>&1
REPORT="$PWD/build/selftest-report.txt"
rm -f "$REPORT"
open -n -W ${ATRIUM_FOOTPRINT:+--env ATRIUM_FOOTPRINT=1} build/AtriumSelfTest.app --args --selftest "$REPORT" || true
cat "$REPORT"
rm -rf build/AtriumSelfTest.app
grep -q "ALL PASSED" "$REPORT"
