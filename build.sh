#!/bin/sh
# Usage: ./build.sh            build + ad-hoc sign
#        SIGN="Developer ID Application: …" ./build.sh notarize
#        (notarize needs APPLE_ID, TEAM_ID, APP_SPECIFIC_PASSWORD)
set -e
cd "$(dirname "$0")"
APP="build/True Full Screen.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -Osize -target arm64-apple-macos14 -import-objc-header Sources/Bridge.h Sources/main.swift -o "$APP/Contents/MacOS/TrueFullScreen"
strip -x "$APP/Contents/MacOS/TrueFullScreen"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --options runtime --timestamp --sign "${SIGN:--}" "$APP"

if [ "$1" = notarize ]; then
  ditto -c -k --keepParent "$APP" build/upload.zip
  xcrun notarytool submit build/upload.zip --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_SPECIFIC_PASSWORD" --wait
  xcrun stapler staple "$APP"
  ditto -c -k --keepParent "$APP" "build/True-Full-Screen.zip"
  rm build/upload.zip
fi
