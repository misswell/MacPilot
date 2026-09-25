#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"
# 唯一的 designated requirement 定义（含团队 ID）。所有签名路径都必须用它，
# 绝不让 codesign 自行推导——详见 Scripts/signing-requirement.sh 顶部说明。
source "$ROOT/Scripts/signing-requirement.sh"

# Architectures to build for. Default is a universal binary (arm64 + x86_64) so
# the packaged app runs on both Apple Silicon and Intel Macs. Override with
# MACPILOT_ARCHS (e.g. "arm64" for a single-arch local build).
ARCHS=(${=MACPILOT_ARCHS:-arm64 x86_64})
if (( ${#ARCHS[@]} == 0 )); then
    echo "ERROR: MACPILOT_ARCHS must contain at least one architecture" >&2
    exit 1
fi
ARCH_ARGS=()
PATCH_ARCH_ARGS=()
for arch in "${ARCHS[@]}"; do
    if [[ "$arch" != "arm64" && "$arch" != "x86_64" ]]; then
        echo "ERROR: Unsupported architecture: $arch (expected arm64 or x86_64)" >&2
        exit 1
    fi
    ARCH_ARGS+=(--arch "$arch")
    PATCH_ARCH_ARGS+=(-arch "$arch")
done

# Keep local packaging under the same strict Swift concurrency diagnostics as
# the signed CI release. This prevents a warning on one toolchain from becoming
# a late compile failure after the commit has already been tagged.
SWIFT_BUILD_ARGS=(-c release -Xswiftc -warnings-as-errors "${ARCH_ARGS[@]}")
BIN_DIR="$(swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)"
swift build "${SWIFT_BUILD_ARGS[@]}"

# Build the FinderSync right-click extension.
# Build it for the same architectures as the app so the context menu keeps
# working on every supported CPU.
MACPILOT_EXT_ARCHS="${ARCHS[*]}" "$ROOT/Scripts/build-findersync.sh"
REXT_PRODUCT="$ROOT/build/FinderSync"
BIN="$BIN_DIR/MacPilot"
UPDATER_BIN="$BIN_DIR/MacPilotUpdater"
HELPER_BIN="$BIN_DIR/MacPilotPowerHelper"
# Dock Groups 的 Helper 可执行文件。MacPilot 会把它拷贝进
# ~/Library/Application Support/MacPilot/DockGroups/<Group>.app 后复用。
DOCK_HELPER_BIN="$BIN_DIR/MacPilotDockHelper"
OCCLUSION_PATCH_BIN="$BIN_DIR/libMacPilotOcclusionPatch.dylib"
# Bind the plain `clang` invocation to the SDK SwiftPM already uses. Without
# this, clang resolves `MacOSX.sdk` to the Command Line Tools copy, which can
# contain a `.tbd` newer than this Xcode's linker understands
# ("tapi error: malformed file ... unknown architecture arm64e.x1-macos") and
# fails the whole packaging step after the Swift build has already succeeded.
OCCLUSION_SDKROOT="$(xcrun -sdk macosx --show-sdk-path)"
xcrun clang -dynamiclib -O2 "${PATCH_ARCH_ARGS[@]}" \
    -mmacosx-version-min=14.0 -isysroot "$OCCLUSION_SDKROOT" -framework AppKit \
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
cp "$HELPER_BIN" "$APP/Contents/MacOS/MacPilotPowerHelper"
# Dock Groups helper: 与主程序同目录，DockHelperBundleBuilder 按这个相对路径查找。
cp "$DOCK_HELPER_BIN" "$APP/Contents/MacOS/MacPilotDockHelper"
chmod 755 "$APP/Contents/MacOS/MacPilotDockHelper"
cp "$OCCLUSION_PATCH_BIN" "$APP/Contents/Resources/libMacPilotOcclusionPatch.dylib"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# SMAppService.daemon(plistName:) requires the LaunchDaemon plist inside the
# bundle at Contents/Library/LaunchDaemons. The helper keeps the same name and
# Mach service in bridge mode so one registration serves both identities.
mkdir -p "$APP/Contents/Library/LaunchDaemons"
cp Resources/com.misswell.macpilot.powerhelper.plist \
    "$APP/Contents/Library/LaunchDaemons/com.misswell.macpilot.powerhelper.plist"
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
# The team is defined once, in Scripts/signing-requirement.sh, and shared with
# the updater's own team check. A build whose requirement can be satisfied by
# another team must never ship; Scripts/verify-signing-requirement.sh asserts
# the team on every signature this script produces.
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
    # Apple Distribution is one of the four sanctioned signing paths (see
    # Scripts/signing-requirement.sh): same team, same embedded requirement, so
    # the result is TCC/update-interchangeable with a release build. It just is
    # not notarized, so it still cannot be published. Preferred over the
    # ad-hoc/Apple Development fallbacks whenever it is available.
    LOCAL_DISTRIBUTION_ID="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Distribution:[^"]*\)".*/\1/p' \
        | sort -u \
        | grep -F "U8U443D7ZL" \
        | head -1 || true)"
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
    elif [[ -n "$LOCAL_DISTRIBUTION_ID" ]]; then
        SIGNING_IDENTITY="$LOCAL_DISTRIBUTION_ID"
        echo "Using production-team Apple Distribution identity: $LOCAL_DISTRIBUTION_ID"
        echo "Same designated requirement, so TCC grants and update recognition carry over."
        echo "Not notarized: this build must never be published as a release asset."
    elif [[ "${MACPILOT_ALLOW_UNSTABLE_SIGNING:-0}" == "1" && -n "$LOCAL_DEVELOPMENT_ID" ]]; then
        SIGNING_IDENTITY="$LOCAL_DEVELOPMENT_ID"
        echo "WARNING: Developer ID identity unavailable; using local development identity: $LOCAL_DEVELOPMENT_ID"
        echo "This build shares the production designated requirement (same team), so TCC"
        echo "grants and in-app updates remain interchangeable with the release build."
        echo "It is still not notarized, so it cannot be published or installed as an update."
    elif [[ "${MACPILOT_ALLOW_UNSTABLE_SIGNING:-0}" == "1" ]]; then
        SIGNING_IDENTITY="-"
        echo "WARNING: Signed ad-hoc because no stable signing identity was found."
        echo "The production requirement is embedded, but an ad-hoc signature cannot satisfy"
        echo "it: TCC grants will not stick and this build must never be published."
    else
        echo "ERROR: No signing identity is available. Set MACPILOT_DEVELOPER_ID to a" >&2
        echo "'Developer ID Application' identity for a distributable build, or set" >&2
        echo "MACPILOT_ALLOW_UNSTABLE_SIGNING=1 to permit a local Apple Development /" >&2
        echo "ad-hoc build (same requirement, but not distributable)." >&2
        exit 1
    fi
fi

if [[ -n "$SIGNING_IDENTITY" ]]; then
    # One requirement, one set of bytes, for every signing path (Developer ID,
    # Apple Distribution, Apple Development, ad-hoc). The team OU is the only
    # pin beyond the bundle identifier and Apple's anchor, and it is the reason a
    # locally built app and a CI release are the same app to macOS: TCC grants
    # carry over and the in-app updater always recognises the other's package.
    # Do not add Developer ID only OID clauses or CN clauses here -- an Apple
    # Development certificate satisfies neither, and splitting the bytes by
    # signing identity is exactly what made updates impossible in the past.
    REQUIREMENT_BODY="$(macpilot_designated_requirement_body "$BUNDLE_IDENTIFIER")"
    REQUIREMENT="designated => $REQUIREMENT_BODY"

    # Sign nested code independently. Passing the main app's custom
    # requirement through --deep would incorrectly give MacPilotUpdater the
    # MacPilot bundle identifier and invalidate the nested signature.
    REXT_ENTITLEMENTS="$ROOT/FinderSync/Resources/FinderSync.entitlements"
    HELPER_ENTITLEMENTS="$ROOT/Resources/MacPilotPowerHelper.entitlements"
    # Dock Groups helper needs its own identifier: MacPilot copies this exact
    # binary into every generated ~/Library/.../DockGroups/<Group>.app, and those
    # copies must not look like the MacPilot app itself.
    DOCK_HELPER_IDENTIFIER="${BUNDLE_IDENTIFIER}.dock-helper"
    if [[ "$SIGNING_IDENTITY" == "-" ]]; then
        codesign --force --entitlements "$HELPER_ENTITLEMENTS" \
            --sign - "$APP/Contents/MacOS/MacPilotPowerHelper"
        codesign --force --entitlements "$REXT_ENTITLEMENTS" \
            --sign - "$REXT_APPEX"
        codesign --force --sign - "$APP/Contents/MacOS/$UPDATER_EXECUTABLE_NAME"
        codesign --force --identifier "$DOCK_HELPER_IDENTIFIER" --sign - \
            "$APP/Contents/MacOS/MacPilotDockHelper"
        codesign --force --sign - \
            "$APP/Contents/Resources/libMacPilotOcclusionPatch.dylib"
        codesign --force --entitlements "$ENTITLEMENTS" \
            --requirements "=$REQUIREMENT" --sign - "$APP"
    else
        codesign --force --options runtime --entitlements "$HELPER_ENTITLEMENTS" \
            --sign "$SIGNING_IDENTITY" "$APP/Contents/MacOS/MacPilotPowerHelper"
        codesign --force --options runtime --entitlements "$REXT_ENTITLEMENTS" \
            --sign "$SIGNING_IDENTITY" "$REXT_APPEX"
        codesign --force --options runtime --sign "$SIGNING_IDENTITY" \
            "$APP/Contents/MacOS/$UPDATER_EXECUTABLE_NAME"
        codesign --force --options runtime --identifier "$DOCK_HELPER_IDENTIFIER" \
            --sign "$SIGNING_IDENTITY" "$APP/Contents/MacOS/MacPilotDockHelper"
        codesign --force --options runtime --sign "$SIGNING_IDENTITY" \
            "$APP/Contents/Resources/libMacPilotOcclusionPatch.dylib"
        codesign --force --options runtime --entitlements "$ENTITLEMENTS" \
            --requirements "=$REQUIREMENT" --sign "$SIGNING_IDENTITY" "$APP"
    fi

    # A build whose designated requirement is not exactly this string cannot be
    # installed by an app signed anywhere else, so stop here instead of shipping
    # an unusable update. The verifier is also the gate in distribute-app.sh and
    # in the release workflow.
    echo "Designated requirement: $REQUIREMENT_BODY"
    "$ROOT/Scripts/verify-signing-requirement.sh" "$APP" "$BUNDLE_IDENTIFIER"
fi
echo "Built $APP (version $VERSION, build $BUILD_NUMBER, bundle id $BUNDLE_IDENTIFIER)"
