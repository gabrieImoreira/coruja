#!/bin/sh
# Builds Sabia.app: a proper double-clickable bundle wrapping the same single
# binary the CLI install (`swift build -c release` + /usr/local/bin) uses.
# Ad-hoc signed (codesign -s -) so it runs on Apple Silicon without needing an
# Apple Developer account — recipients still see Gatekeeper's "unidentified
# developer" prompt once, since it isn't notarized. See README for the
# right-click-Open workaround.
set -eu
cd "$(dirname "$0")/.."

APP=".build/Sabia.app"
rm -rf "$APP"

echo "==> swift build -c release"
swift build -c release

echo "==> assembling $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/sabia "$APP/Contents/MacOS/sabia"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "==> ad-hoc codesign"
codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP"

echo "==> zipping"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Packaging/Info.plist)
ZIP=".build/sabia-${VERSION}-macos.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "done: $APP"
echo "done: $ZIP"
