#!/bin/zsh
set -euo pipefail

# Produce a distributable, notarized MacPilot.app + zip.
# Set MACPILOT_BRIDGE=1 for the one-time release that keeps the old app identity.
# Requires:
#   MACPILOT_DEVELOPER_ID          "Developer ID Application: Your Name (TEAMID)"
# Notarization credentials - pick one:
#   MACPILOT_NOTARY_PROFILE        keychain profile name created via
#                                  `xcrun notarytool store-credentials "PROFILE" \
#                                     --apple-id ID --team-id TEAM --password APPSPECIFIC`
#   OR the three plaintext variables below:
#   MACPILOT_APPLE_ID              Apple ID
#   MACPILOT_APPLE_PASSWORD        app-specific password
#   MACPILOT_TEAM_ID                Team ID

ROOT="${0:A:h:h}"
cd "$ROOT"

ARCHS=(${=MACPILOT_ARCHS:-arm64 x86_64})
if (( ${#ARCHS[@]} == 0 )); then
    echo "ERROR: MACPILOT_ARCHS must contain at least one architecture" >&2
    exit 1
fi
for arch in "${ARCHS[@]}"; do
    if [[ "$arch" != "arm64" && "$arch" != "x86_64" ]]; then
        echo "ERROR: Unsupported architecture: $arch (expected arm64 or x86_64)" >&2
        exit 1
    fi
done

DEVELOPER_ID="${MACPILOT_DEVELOPER_ID:-${OCTOPILOT_DEVELOPER_ID:-}}"
: "${DEVELOPER_ID:?Set MACPILOT_DEVELOPER_ID to your 'Developer ID Application: Name (TEAMID)' identity}"

NOTARY_PROFILE="${MACPILOT_NOTARY_PROFILE:-${OCTOPILOT_NOTARY_PROFILE:-}}"
APPLE_ID="${MACPILOT_APPLE_ID:-${OCTOPILOT_APPLE_ID:-}}"
APPLE_PASSWORD="${MACPILOT_APPLE_PASSWORD:-${OCTOPILOT_APPLE_PASSWORD:-}}"
TEAM_ID="${MACPILOT_TEAM_ID:-${OCTOPILOT_TEAM_ID:-}}"

NOTARY_ARGS=()
if [[ -n "$NOTARY_PROFILE" ]]; then
    NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
else
    : "${APPLE_ID:?Set MACPILOT_APPLE_ID or MACPILOT_NOTARY_PROFILE}"
    : "${APPLE_PASSWORD:?Set MACPILOT_APPLE_PASSWORD or MACPILOT_NOTARY_PROFILE}"
    : "${TEAM_ID:?Set MACPILOT_TEAM_ID or MACPILOT_NOTARY_PROFILE}"
    NOTARY_ARGS=(--apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" --team-id "$TEAM_ID")
fi

VERSION="${MACPILOT_VERSION:-${OCTOPILOT_VERSION:-$("$ROOT/Scripts/version.sh")}}"
BRIDGE_MODE="${MACPILOT_BRIDGE:-${OCTOPILOT_BRIDGE:-0}}"
if [[ "$BRIDGE_MODE" == "1" ]]; then
    APP_BUNDLE_NAME="OctoPilot.app"
    ARCHIVE_PREFIX="OctoPilot"
else
    APP_BUNDLE_NAME="MacPilot.app"
    ARCHIVE_PREFIX="MacPilot"
fi
OUTPUT_DIR="${MACPILOT_OUTPUT_DIR:-$ROOT}"
APP="$OUTPUT_DIR/$APP_BUNDLE_NAME"
ARCHIVE_ARCH_SUFFIX=""
if (( ${#ARCHS[@]} == 1 )); then
    ARCHIVE_ARCH_SUFFIX="-${ARCHS[1]}"
fi
ZIP="$OUTPUT_DIR/$ARCHIVE_PREFIX-$VERSION${ARCHIVE_ARCH_SUFFIX}-macos.zip"

PRESERVE_ARCHIVES=(
    "$ZIP"
    "$OUTPUT_DIR/$ARCHIVE_PREFIX-$VERSION-macos.zip"
    "$OUTPUT_DIR/$ARCHIVE_PREFIX-$VERSION-arm64-macos.zip"
    "$OUTPUT_DIR/$ARCHIVE_PREFIX-$VERSION-x86_64-macos.zip"
)

cleanup_historical_archives() {
    local archive
    local preserved

    while IFS= read -r archive; do
        for preserved in "${PRESERVE_ARCHIVES[@]}"; do
            [[ "${archive:A}" == "${preserved:A}" ]] && continue 2
        done
        rm -f "$archive"
        echo "Removed historical archive: $archive"
    done < <(
        find "$OUTPUT_DIR" -maxdepth 1 -type f \
            \( -name 'MacPilot-*-macos.zip' -o -name 'OctoPilot-*-macos.zip' \) \
            -print
    )
}

echo "==> Building and signing with Developer ID"
MACPILOT_BRIDGE="$BRIDGE_MODE" \
MACPILOT_DEVELOPER_ID="$DEVELOPER_ID" \
MACPILOT_OUTPUT_DIR="$OUTPUT_DIR" \
MACPILOT_VERSION="$VERSION" \
MACPILOT_ARCHS="${ARCHS[*]}" \
./Scripts/build-app.sh

echo "==> Archiving for notarization"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "==> Submitting to Apple notarization service"
xcrun notarytool submit "$ZIP" "${NOTARY_ARGS[@]}" --wait

echo "==> Stapling the notarization ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Re-archiving the stapled app"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "==> Verifying"
codesign --verify --deep --strict "$APP"
spctl --assess --type execute --verbose "$APP"

echo "==> Cleaning historical archives"
cleanup_historical_archives

echo "Done. Distributable artifacts:"
echo "  $APP"
echo "  $ZIP"
