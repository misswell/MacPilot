#!/bin/zsh
set -euo pipefail

# Build the MacPilot FinderSync extension (appex) for embedding into MacPilot.app.
#
# Uses plain swiftc so the SwiftPM-based MacPilot repo stays untouched.
#
# Supports one or more architectures: set MACPILOT_EXT_ARCHS to a space-separated
# list (default: the host architecture). Multi-arch builds are lipo'd into a
# universal executable so the extension works on both Apple Silicon and Intel.
#
# Output:  $PRODUCT/FinderSync.appex   (a complete .appex bundle)

ROOT="${0:A:h:h}"
cd "$ROOT"

SRC_DIR="$ROOT/FinderSync/Sources"
RES_DIR="$ROOT/FinderSync/Resources"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
ARCHS=(${=MACPILOT_EXT_ARCHS:-$(uname -m)})
PRODUCT="${MACPILOT_EXT_PRODUCT_DIR:-$ROOT/build/FinderSync}"
EXT_BUNDLE_ID="com.misswell.macpilot.finder-sync"
EXT_NAME="MacPilotFinderSync"
FW_PATHS=(
    "-F" "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks"
    "-F" "$SDK/System/Library/Frameworks"
)

echo "==> Building FinderSync extension (archs=${ARCHS[*]}, min=$DEPLOYMENT_TARGET)"
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

PER_ARCH_EXES=()
for ARCH in "${ARCHS[@]}"; do
    echo "==> Compiling FinderSync extension (arch=$ARCH)"
    # Compile all sources in one invocation so cross-file types resolve.
    OBJ_DIR="$ROOT/build/FinderSyncObjects/$ARCH"
    rm -rf "$OBJ_DIR"
    mkdir -p "$OBJ_DIR"
    # Materialize the output-file map to a real file (avoids /dev/fd process
    # substitution which is not always readable by the compiler).
    OUTPUT_FILE_MAP="$OBJ_DIR/filemap.json"
    python3 - "$OBJ_DIR" "$SRC_DIR" > "$OUTPUT_FILE_MAP" <<'PYEOF'
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
    xcrun swiftc \
        -swift-version 6 \
        -target "$ARCH-apple-macosx$DEPLOYMENT_TARGET" \
        -sdk "$SDK" \
        "${FW_PATHS[@]}" \
        -emit-object \
        -module-name "$EXT_NAME" \
        -output-file-map "$OUTPUT_FILE_MAP" \
        "${EXT_SOURCES[@]}"

    # Link with the extension entry point (same as Xcode's appex product type).
    EXE="$ROOT/build/FinderSyncBinaries/$ARCH/$EXT_NAME"
    mkdir -p "$(dirname "$EXE")"
    xcrun swiftc \
        -target "$ARCH-apple-macosx$DEPLOYMENT_TARGET" \
        -sdk "$SDK" \
        "${FW_PATHS[@]}" \
        -Xlinker -rpath -Xlinker /usr/lib/swift \
        -Xlinker -e -Xlinker _NSExtensionMain \
        -o "$EXE" \
        "$OBJ_DIR"/*.o
    PER_ARCH_EXES+=("$EXE")
done

if (( ${#PER_ARCH_EXES[@]} > 1 )); then
    echo "==> Combining universal FinderSync executable (${ARCHS[*]})"
    xcrun lipo -create "${PER_ARCH_EXES[@]}" -output "$PRODUCT/Contents/MacOS/$EXT_NAME"
else
    cp "${PER_ARCH_EXES[1]}" "$PRODUCT/Contents/MacOS/$EXT_NAME"
fi

cp "$RES_DIR/Info.plist" "$PRODUCT/Contents/Info.plist"
if [[ -d "$RES_DIR/zh-Hans.lproj" ]]; then
    cp -R "$RES_DIR/zh-Hans.lproj" "$PRODUCT/Contents/Resources/"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $EXT_BUNDLE_ID" "$PRODUCT/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $EXT_NAME" "$PRODUCT/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${MACPILOT_VERSION:-1.0.0}" "$PRODUCT/Contents/Info.plist" 2>/dev/null || true

echo "==> FinderSync extension built: $PRODUCT"
echo "    (embed at MacPilot.app/Contents/PlugIns/FinderSync.appex)"
