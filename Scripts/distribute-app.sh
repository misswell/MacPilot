#!/bin/zsh
set -euo pipefail

# Produce a distributable, notarized MacPilot.app + zip.
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
APP="$ROOT/MacPilot.app"
ZIP="$ROOT/MacPilot-$VERSION-macos.zip"

echo "==> Building and signing with Developer ID"
MACPILOT_DEVELOPER_ID="$DEVELOPER_ID" ./Scripts/build-app.sh

echo "==> Archiving for notarization"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "==> Submitting to Apple notarization service"
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

echo "Done. Distributable artifacts:"
echo "  $APP"
echo "  $ZIP"
chmod +x "$ZIP" 2>/dev/null || true
