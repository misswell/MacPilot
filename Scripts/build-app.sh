#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="$BIN_DIR/MacPilot"
UPDATER_BIN="$BIN_DIR/MacPilotUpdater"
APP="$ROOT/MacPilot.app"
VERSION="${MACPILOT_VERSION:-${OCTOPILOT_VERSION:-$("$ROOT/Scripts/version.sh")}}"
BUILD_NUMBER="${MACPILOT_BUILD_NUMBER:-${OCTOPILOT_BUILD_NUMBER:-$(git rev-list --count HEAD)}}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacPilot"
cp "$UPDATER_BIN" "$APP/Contents/MacOS/MacPilotUpdater"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
ENTITLEMENTS="$ROOT/Resources/MacPilot.entitlements"
DEVELOPER_ID="${MACPILOT_DEVELOPER_ID:-${OCTOPILOT_DEVELOPER_ID:-}}"
if [[ -n "$DEVELOPER_ID" ]]; then
    codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" --sign "$DEVELOPER_ID" "$APP"
    echo "Signed with Developer ID: $DEVELOPER_ID"
else
    codesign --force --deep --sign - "$APP"
    echo "Signed ad-hoc (not distributable)"
fi
echo "Built $APP (version $VERSION, build $BUILD_NUMBER)"
