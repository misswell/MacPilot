#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="$BIN_DIR/MacPilot"
UPDATER_BIN="$BIN_DIR/MacPilotUpdater"
OCCLUSION_PATCH_BIN="$BIN_DIR/libMacPilotOcclusionPatch.dylib"
xcrun clang -dynamiclib -O2 -arch arm64 -arch x86_64 \
    -mmacosx-version-min=14.0 -framework AppKit \
    -install_name @loader_path/libMacPilotOcclusionPatch.dylib \
    Sources/MacPilotOcclusionPatch/MacPilotOcclusionPatch.m \
    -o "$OCCLUSION_PATCH_BIN"
VERSION="${MACPILOT_VERSION:-${OCTOPILOT_VERSION:-$("$ROOT/Scripts/version.sh")}}"
BUILD_NUMBER="${MACPILOT_BUILD_NUMBER:-${OCTOPILOT_BUILD_NUMBER:-$(git rev-list --count HEAD)}}"

BRIDGE_MODE="${MACPILOT_BRIDGE:-${OCTOPILOT_BRIDGE:-0}}"
if [[ "$BRIDGE_MODE" == "1" ]]; then
    APP_BUNDLE_NAME="OctoPilot.app"
    APP_EXECUTABLE_NAME="OctoPilot"
    UPDATER_EXECUTABLE_NAME="OctoPilotUpdater"
    BUNDLE_IDENTIFIER="com.misswell.octopilot"
else
    APP_BUNDLE_NAME="MacPilot.app"
    APP_EXECUTABLE_NAME="MacPilot"
    UPDATER_EXECUTABLE_NAME="MacPilotUpdater"
    BUNDLE_IDENTIFIER="com.misswell.macpilot"
fi

OUTPUT_DIR="${MACPILOT_OUTPUT_DIR:-$ROOT}"
APP="$OUTPUT_DIR/$APP_BUNDLE_NAME"

mkdir -p "$OUTPUT_DIR"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_EXECUTABLE_NAME"
cp "$UPDATER_BIN" "$APP/Contents/MacOS/$UPDATER_EXECUTABLE_NAME"
cp "$OCCLUSION_PATCH_BIN" "$APP/Contents/Resources/libMacPilotOcclusionPatch.dylib"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName MacPilot" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName MacPilot" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_EXECUTABLE_NAME" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_IDENTIFIER" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
ENTITLEMENTS="$ROOT/Resources/MacPilot.entitlements"
DEVELOPER_ID="${MACPILOT_DEVELOPER_ID:-${OCTOPILOT_DEVELOPER_ID:-}}"
SIGNING_IDENTITY="$DEVELOPER_ID"
if [[ -n "$DEVELOPER_ID" ]]; then
    echo "Using Developer ID identity: $DEVELOPER_ID"
else
    LOCAL_SIGNING_ID="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
        | head -1)"
    if [[ -n "$LOCAL_SIGNING_ID" ]]; then
        SIGNING_IDENTITY="$LOCAL_SIGNING_ID"
        echo "Using local development identity: $LOCAL_SIGNING_ID"
    else
        codesign --force --deep --sign - "$APP"
        echo "WARNING: Signed ad-hoc because no stable signing identity was found."
        echo "Screen Recording and Accessibility permissions may need to be granted again after every rebuild."
    fi
fi

if [[ -n "$SIGNING_IDENTITY" ]]; then
    # TCC stores the designated requirement when Screen Recording or
    # Accessibility is granted.  Development and Developer ID certificates
    # can have different team identifiers on this machine, so do not derive
    # the requirement from whichever certificate happens to be selected.
    # The stable bundle identifier plus Apple's code-signing anchor is the
    # common identity used by both build variants.
    SHARED_REQUIREMENT="designated => identifier \"$BUNDLE_IDENTIFIER\" and anchor apple generic"

    # Sign nested code independently. Passing the main app's custom
    # requirement through --deep would incorrectly give MacPilotUpdater the
    # MacPilot bundle identifier and invalidate the nested signature.
    codesign --force --options runtime --sign "$SIGNING_IDENTITY" \
        "$APP/Contents/MacOS/$UPDATER_EXECUTABLE_NAME"
    codesign --force --options runtime --sign "$SIGNING_IDENTITY" \
        "$APP/Contents/Resources/libMacPilotOcclusionPatch.dylib"
    codesign --force --options runtime --entitlements "$ENTITLEMENTS" \
        --requirements "=$SHARED_REQUIREMENT" --sign "$SIGNING_IDENTITY" "$APP"
    echo "Shared designated requirement: $SHARED_REQUIREMENT"
fi
echo "Built $APP (version $VERSION, build $BUILD_NUMBER, bundle id $BUNDLE_IDENTIFIER)"
