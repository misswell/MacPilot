#!/bin/zsh
set -euo pipefail

# Build the MacPilot FinderSync extension (appex) for embedding into MacPilot.app.
#
# The extension executable is the SwiftPM target `MacPilotFinderSync`, which
# links `MacPilotRightClickKit` — the single source of truth shared with the
# main app. SwiftPM produces the binary (its Package.swift linkerSettings wire
# up the `_NSExtensionMain` entry point); this script only assembles the
# .appex bundle around it.
#
# Supports one or more architectures: set MACPILOT_EXT_ARCHS to a space-separated
# list (default: the host architecture). Multi-arch builds are lipo'd into a
# universal executable so the extension works on both Apple Silicon and Intel.
#
# Output:  $PRODUCT/FinderSync.appex   (a complete .appex bundle)

ROOT="${0:A:h:h}"
cd "$ROOT"

RES_DIR="$ROOT/FinderSync/Resources"
ARCHS=(${=MACPILOT_EXT_ARCHS:-$(uname -m)})
PRODUCT="${MACPILOT_EXT_PRODUCT_DIR:-$ROOT/build/FinderSync}"
EXT_BUNDLE_ID="com.misswell.macpilot.finder-sync"
EXT_NAME="MacPilotFinderSync"

echo "==> Building FinderSync extension (archs=${ARCHS[*]})"
rm -rf "$PRODUCT"
mkdir -p "$PRODUCT/Contents/MacOS" "$PRODUCT/Contents/Resources"

PER_ARCH_EXES=()
for ARCH in "${ARCHS[@]}"; do
    echo "==> Building FinderSync executable (arch=$ARCH)"
    swift build -c release --product "$EXT_NAME" --arch "$ARCH"
    BIN_DIR="$(swift build -c release --product "$EXT_NAME" --arch "$ARCH" --show-bin-path)"
    EXE="$ROOT/build/FinderSyncBinaries/$ARCH/$EXT_NAME"
    mkdir -p "$(dirname "$EXE")"
    cp "$BIN_DIR/$EXT_NAME" "$EXE"
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
