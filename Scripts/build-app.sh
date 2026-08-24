#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

# Architectures to build for. Default is a universal binary (arm64 + x86_64) so
# the packaged app runs on both Apple Silicon and Intel Macs. Override with
# MACPILOT_ARCHS (e.g. "arm64" for a single-arch local build).
ARCHS=(${=MACPILOT_ARCHS:-arm64 x86_64})
ARCH_ARGS=()
for arch in "${ARCHS[@]}"; do
    ARCH_ARGS+=(--arch "$arch")
done

# Keep local packaging under the same strict Swift concurrency diagnostics as
# the signed CI release. This prevents a warning on one toolchain from becoming
# a late compile failure after the commit has already been tagged.
SWIFT_BUILD_ARGS=(-c release -Xswiftc -warnings-as-errors "${ARCH_ARGS[@]}")
swift build "${SWIFT_BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)"

# Build the FinderSync right-click extension (derived from RClick, GPLv3).
# Build it for the same architectures as the app so the context menu keeps
# working on every supported CPU.
MACPILOT_EXT_ARCHS="${ARCHS[*]}" "$ROOT/Scripts/build-findersync.sh"
REXT_PRODUCT="$ROOT/build/FinderSync"
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
if [[ -d "$ROOT/Resources/zh-Hans.lproj" ]]; then
    cp -R "$ROOT/Resources/zh-Hans.lproj" "$APP/Contents/Resources/"
fi
mkdir -p "$APP/Contents/PlugIns"
cp -R "$REXT_PRODUCT" "$APP/Contents/PlugIns/FinderSync.appex"
REXT_APPEX="$APP/Contents/PlugIns/FinderSync.appex"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName MacPilot" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName MacPilot" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_EXECUTABLE_NAME" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_IDENTIFIER" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$REXT_APPEX/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$REXT_APPEX/Contents/Info.plist"
ENTITLEMENTS="$ROOT/Resources/MacPilot.entitlements"
DEVELOPER_ID="${MACPILOT_DEVELOPER_ID:-${OCTOPILOT_DEVELOPER_ID:-}}"
EXPECTED_DEVELOPER_ID="Developer ID Application: Guofeng Liu (U8U443D7ZL)"
SIGNING_IDENTITY="$DEVELOPER_ID"
if [[ -n "$DEVELOPER_ID" ]]; then
    if [[ "$DEVELOPER_ID" != "$EXPECTED_DEVELOPER_ID" ]]; then
        echo "ERROR: Refusing signing identity that differs from production: $DEVELOPER_ID" >&2
        echo "Expected: $EXPECTED_DEVELOPER_ID" >&2
        exit 1
    fi
    echo "Using Developer ID identity: $DEVELOPER_ID"
else
    INSTALLED_DEVELOPER_ID="$(codesign -dv --verbose=4 "/Applications/$APP_BUNDLE_NAME" 2>&1 \
        | sed -n 's/^Authority=\(Developer ID Application:.*\)$/\1/p' \
        | head -1 || true)"
    LOCAL_DEVELOPER_IDS="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' \
        | sort -u)"
    if [[ -n "$INSTALLED_DEVELOPER_ID" ]] && grep -Fqx "$INSTALLED_DEVELOPER_ID" <<< "$LOCAL_DEVELOPER_IDS"; then
        LOCAL_DEVELOPER_ID="$INSTALLED_DEVELOPER_ID"
    elif grep -Fqx "$EXPECTED_DEVELOPER_ID" <<< "$LOCAL_DEVELOPER_IDS"; then
        LOCAL_DEVELOPER_ID="$EXPECTED_DEVELOPER_ID"
    else
        LOCAL_DEVELOPER_ID=""
    fi
    LOCAL_DEVELOPMENT_ID="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
        | head -1)"
    if [[ -n "$LOCAL_DEVELOPER_ID" ]]; then
        if [[ "$LOCAL_DEVELOPER_ID" != "$EXPECTED_DEVELOPER_ID" ]]; then
            echo "ERROR: Installed app uses an unexpected Developer ID: $LOCAL_DEVELOPER_ID" >&2
            echo "Expected: $EXPECTED_DEVELOPER_ID" >&2
            exit 1
        fi
        SIGNING_IDENTITY="$LOCAL_DEVELOPER_ID"
        echo "Using production-matched Developer ID identity: $LOCAL_DEVELOPER_ID"
    elif [[ "${MACPILOT_ALLOW_UNSTABLE_SIGNING:-0}" == "1" && -n "$LOCAL_DEVELOPMENT_ID" ]]; then
        SIGNING_IDENTITY="$LOCAL_DEVELOPMENT_ID"
        echo "WARNING: Developer ID identity unavailable; using local development identity: $LOCAL_DEVELOPMENT_ID"
        echo "macOS may treat this build as a different app for privacy permissions."
    elif [[ "${MACPILOT_ALLOW_UNSTABLE_SIGNING:-0}" == "1" ]]; then
        SIGNING_IDENTITY="-"
        echo "WARNING: Signed ad-hoc because no stable signing identity was found."
        echo "Screen Recording and Accessibility permissions may need to be granted again after every rebuild."
    else
        echo "ERROR: A Developer ID Application identity is required so development and production share privacy permissions." >&2
        echo "Set MACPILOT_DEVELOPER_ID, or explicitly set MACPILOT_ALLOW_UNSTABLE_SIGNING=1 to permit a TCC-unstable fallback." >&2
        exit 1
    fi
fi

if [[ -n "$SIGNING_IDENTITY" ]]; then
    # TCC stores the designated requirement when Screen Recording or
    # Accessibility is granted. Keep the bundle identifier and Apple signing
    # anchor stable across local and release builds.
    SHARED_REQUIREMENT="designated => identifier \"$BUNDLE_IDENTIFIER\" and anchor apple generic"

    # Sign nested code independently. Passing the main app's custom
    # requirement through --deep would incorrectly give MacPilotUpdater the
    # MacPilot bundle identifier and invalidate the nested signature.
    REXT_ENTITLEMENTS="$ROOT/FinderSync/Resources/FinderSync.entitlements"
    if [[ "$SIGNING_IDENTITY" == "-" ]]; then
        codesign --force --entitlements "$REXT_ENTITLEMENTS" \
            --sign - "$REXT_APPEX"
        codesign --force --sign - "$APP/Contents/MacOS/$UPDATER_EXECUTABLE_NAME"
        codesign --force --sign - \
            "$APP/Contents/Resources/libMacPilotOcclusionPatch.dylib"
        codesign --force --entitlements "$ENTITLEMENTS" \
            --sign - "$APP"
    else
        codesign --force --options runtime --entitlements "$REXT_ENTITLEMENTS" \
            --sign "$SIGNING_IDENTITY" "$REXT_APPEX"
        codesign --force --options runtime --sign "$SIGNING_IDENTITY" \
            "$APP/Contents/MacOS/$UPDATER_EXECUTABLE_NAME"
        codesign --force --options runtime --sign "$SIGNING_IDENTITY" \
            "$APP/Contents/Resources/libMacPilotOcclusionPatch.dylib"
        codesign --force --options runtime --entitlements "$ENTITLEMENTS" \
            --requirements "=$SHARED_REQUIREMENT" --sign "$SIGNING_IDENTITY" "$APP"
    fi
    echo "Shared designated requirement: $SHARED_REQUIREMENT"
fi
echo "Built $APP (version $VERSION, build $BUILD_NUMBER, bundle id $BUNDLE_IDENTIFIER)"
