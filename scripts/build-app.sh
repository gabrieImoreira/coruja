#!/bin/sh
# Builds Coruja.app: a proper double-clickable bundle wrapping the same single
# binary the CLI install (`swift build -c release` + /usr/local/bin) uses.
# Ad-hoc signed (codesign -s -) so it runs on Apple Silicon without needing an
# Apple Developer account — recipients still see Gatekeeper's "unidentified
# developer" prompt once, since it isn't notarized. See README for the
# right-click-Open workaround.
set -eu
cd "$(dirname "$0")/.."

APP=".build/Coruja.app"
rm -rf "$APP"

echo "==> swift build -c release"
swift build -c release

echo "==> prefetching whisper model (skips if already cached)"
.build/release/coruja prefetch-model

echo "==> assembling $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/coruja "$APP/Contents/MacOS/coruja"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "==> bundling whisper model (so the app never has to download it)"
MODEL_CACHE="$HOME/Documents/huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_turbo"
if [ ! -d "$MODEL_CACHE" ]; then
    echo "error: $MODEL_CACHE not found after prefetch-model" >&2
    exit 1
fi
mkdir -p "$APP/Contents/Resources/whisperkit-model"
cp -R "$MODEL_CACHE"/. "$APP/Contents/Resources/whisperkit-model/"

echo "==> ad-hoc codesign"
codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP"

echo "==> zipping"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Packaging/Info.plist)
ZIP=".build/coruja-${VERSION}-macos.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "done: $APP"
echo "done: $ZIP"
