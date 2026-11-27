#!/bin/sh
# Builds dist/Proximity Mac.app from a release build and signs it.
# Signs with $SIGN_IDENTITY when set (a stable certificate keeps camera and microphone permissions
# across rebuilds); otherwise ad-hoc, which macOS treats as a new app after every build.
set -eu
cd "$(dirname "$0")/.."

swift build -c release --product ProximityMac
BIN="$(swift build -c release --show-bin-path)/ProximityMac"

APP="dist/Proximity Mac.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ProximityMac"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"
