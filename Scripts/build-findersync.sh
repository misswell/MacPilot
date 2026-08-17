#!/bin/zsh
set -euo pipefail

# Build the MacPilot FinderSync extension (appex) for embedding into MacPilot.app.
#
# Mirrors RClick's FinderSyncExt (GPLv3, https://github.com/wflixu/RClick).
# Uses plain swiftc so the SwiftPM-based MacPilot repo stays untouched.
#
# Output:  $PRODUCT/FinderSync.appex   (a complete .appex bundle)

ROOT="${0:A:h:h}"
cd "$ROOT"

SRC_DIR="$ROOT/FinderSync/Sources"
RES_DIR="$ROOT/FinderSync/Resources"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
ARCH="${MACPILOT_EXT_ARCH:-$(uname -m)}"
PRODUCT="${MACPILOT_EXT_PRODUCT_DIR:-$ROOT/build/FinderSync}"
EXT_BUNDLE_ID="com.misswell.macpilot.finder-sync"
EXT_NAME="MacPilotFinderSync"
FW_PATHS=(
    "-F" "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks"
    "-F" "$SDK/System/Library/Frameworks"
)

echo "==> Compiling FinderSync extension (arch=$ARCH, min=$DEPLOYMENT_TARGET)"
rm -rf "$PRODUCT"
mkdir -p "$PRODUCT/Contents/MacOS" "$PRODUCT/Contents/Resources"

# Keep the small shared utility source: Constants.swift uses it while building
# the extension even though the extension does not call it directly.
EXT_EXCLUDED=()
EXT_SOURCES=()
for src in "$SRC_DIR"/*.swift; do
    base="$(basename "$src")"
    if [[ " ${EXT_EXCLUDED[*]} " == *" $base "* ]]; then
        continue
    fi
    EXT_SOURCES+=("$src")
done

# Compile all sources in one invocation so cross-file types resolve.
OBJ_DIR="$ROOT/build/FinderSyncObjects"
rm -rf "$OBJ_DIR"
mkdir -p "$OBJ_DIR"
xcrun swiftc \
    -swift-version 6 \
    -target "$ARCH-apple-macosx$DEPLOYMENT_TARGET" \
    -sdk "$SDK" \
    "${FW_PATHS[@]}" \
    -emit-object \
    -module-name "$EXT_NAME" \
    -output-file-map <(python3 - "$OBJ_DIR" "$SRC_DIR" <<'PYEOF'
import glob, json, os, sys
obj_dir, src_dir = sys.argv[1], sys.argv[2]
excluded = set()
sources = sorted(
    s for s in glob.glob(os.path.join(src_dir, '*.swift'))
    if os.path.basename(s) not in excluded
)
def out(s, ext):
    base = os.path.splitext(os.path.basename(s))[0]
    return {'object': os.path.join(obj_dir, base + ext), 'swiftmodule': os.path.join(obj_dir, base + '.swiftmodule')}
print(json.dumps({s: {k: v for k, v in out(s, '.o').items()} for s in sources}))
PYEOF
) \
    "${EXT_SOURCES[@]}"

# Link with the extension entry point (same as Xcode's appex product type).
xcrun swiftc \
    -target "$ARCH-apple-macosx$DEPLOYMENT_TARGET" \
    -sdk "$SDK" \
    "${FW_PATHS[@]}" \
    -Xlinker -rpath -Xlinker /usr/lib/swift \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -o "$PRODUCT/Contents/MacOS/$EXT_NAME" \
    "$OBJ_DIR"/*.o

cp "$RES_DIR/Info.plist" "$PRODUCT/Contents/Info.plist"
if [[ -d "$RES_DIR/zh-Hans.lproj" ]]; then
    cp -R "$RES_DIR/zh-Hans.lproj" "$PRODUCT/Contents/Resources/"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $EXT_BUNDLE_ID" "$PRODUCT/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $EXT_NAME" "$PRODUCT/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${MACPILOT_VERSION:-1.0.0}" "$PRODUCT/Contents/Info.plist" 2>/dev/null || true

echo "==> FinderSync extension built: $PRODUCT"
echo "    (embed at MacPilot.app/Contents/PlugIns/FinderSync.appex)"
