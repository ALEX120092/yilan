#!/bin/zsh
# Builds 一览.app next to this script.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/一览.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/VolumeMixer "$APP/Contents/MacOS/VolumeMixer"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

echo "Built $PWD/$APP"
