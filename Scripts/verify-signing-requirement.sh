#!/bin/zsh
set -euo pipefail

# 校验一个已签名的 .app（或包含它的 zip）是否带着唯一那一串 designated
# requirement（定义见 Scripts/signing-requirement.sh）。
#
# 这是「另一台电脑 / 另一个 agent 签出来的东西和现网不一致」的最后一道闸：三个入口
# 都会调用它 —— build-app.sh（签名后）、distribute-app.sh（重新打 zip 后）、
# CI 的 dist job（发布前）。任何一处字节不一致都会在这里失败，而不是等到用户点
# 「检查更新…」时才发现装不上。
#
# 用法: verify-signing-requirement.sh <app-or-zip> <bundle-identifier>

ROOT="${0:A:h:h}"
source "$ROOT/Scripts/signing-requirement.sh"

TARGET="${1:?usage: verify-signing-requirement.sh <app-or-zip> <bundle-identifier>}"
BUNDLE_IDENTIFIER="${2:?usage: verify-signing-requirement.sh <app-or-zip> <bundle-identifier>}"

EXPECTED_BODY="$(macpilot_designated_requirement_body "$BUNDLE_IDENTIFIER")"

CLEANUP_DIR=""
cleanup() {
    if [[ -n "$CLEANUP_DIR" ]]; then
        rm -rf "$CLEANUP_DIR"
    fi
}
trap cleanup EXIT

APP=""
case "$TARGET" in
    *.zip)
        CLEANUP_DIR="$(mktemp -d)"
        /usr/bin/ditto -x -k "$TARGET" "$CLEANUP_DIR"
        APP="$(/usr/bin/find "$CLEANUP_DIR" -maxdepth 1 -name '*.app' -print -quit)"
        ;;
    *.app)
        APP="$TARGET"
        ;;
    *)
        echo "ERROR: $TARGET is neither an .app bundle nor a .zip archive" >&2
        exit 1
        ;;
esac

if [[ -z "$APP" || ! -d "$APP" ]]; then
    echo "ERROR: no .app bundle found in $TARGET" >&2
    exit 1
fi

/usr/bin/codesign --verify --deep --strict "$APP"

ACTUAL_BODY="$(/usr/bin/codesign --display -r- "$APP" 2>&1 | /usr/bin/sed -n 's/^designated => //p')"
if [[ "$ACTUAL_BODY" != "$EXPECTED_BODY" ]]; then
    echo "ERROR: $APP carries an unexpected designated requirement." >&2
    echo "  expected: $EXPECTED_BODY" >&2
    echo "  actual:   ${ACTUAL_BODY:-<none>}" >&2
    echo "Do not relax this check and do not let codesign derive the requirement:" >&2
    echo "an already-installed app refuses to update to a package it does not" >&2
    echo "recognise as itself. Route every signing path through" >&2
    echo "Scripts/signing-requirement.sh instead." >&2
    exit 1
fi

DETAILS="$(/usr/bin/codesign --display --verbose=4 "$APP" 2>&1)"
if [[ "$DETAILS" == *"Signature=adhoc"* ]]; then
    echo "WARNING: $APP is ad-hoc signed; the requirement above is embedded, but an" >&2
    echo "         ad-hoc build must never be published (it cannot satisfy its own" >&2
    echo "         requirement, and Gatekeeper/notarization reject it)." >&2
elif [[ "$DETAILS" != *"TeamIdentifier=$MACPILOT_SIGNING_TEAM_ID"* ]]; then
    echo "ERROR: $APP is not signed by team $MACPILOT_SIGNING_TEAM_ID." >&2
    echo "  $(printf '%s\n' "$DETAILS" | /usr/bin/grep -E 'TeamIdentifier|Authority' | /usr/bin/tr '\n' ' ')" >&2
    exit 1
fi

echo "Signing requirement OK: $ACTUAL_BODY"
