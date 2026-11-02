#!/usr/bin/env bash
# Builds Glimpse.app into ./build.
# Usage: scripts/build-app.sh [release|debug]
set -euo pipefail

CONFIGURATION="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Glimpse.app"

cd "$ROOT"

if [[ "$CONFIGURATION" == "release" ]]; then
    # A universal binary runs on Apple silicon and Intel Macs.
    swift build -c release --arch arm64 --arch x86_64
    BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
else
    swift build -c debug
    BIN_DIR="$(swift build -c debug --show-bin-path)"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Glimpse" "$APP/Contents/MacOS/Glimpse"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc signature. Apple silicon needs a signature to run the app.
codesign --force --sign - --timestamp=none "$APP" >/dev/null

# Tell Launch Services about the app, so it shows in Finder's "Open With" menu.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$APP" || true
fi

echo "Built $APP"
