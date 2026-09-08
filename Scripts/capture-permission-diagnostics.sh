#!/bin/zsh
set -euo pipefail

# Capture live TCC evidence even when `log show` cannot open the log store.
# No permission resets, app restarts, protected-container reads, or secrets.
duration="${1:-60}"
if [[ "$duration" != <-> ]] || (( duration < 1 || duration > 600 )); then
    echo "Usage: zsh Scripts/capture-permission-diagnostics.sh [seconds: 1-600]" >&2
    exit 2
fi
capture_dir="$(mktemp -d /tmp/macpilot-permissions.XXXXXX)"
echo "Capturing permission events for $duration seconds: $capture_dir"
for bundle in /Applications/MacPilot.app /Applications/MacPilot.app/Contents/PlugIns/FinderSync.appex; do
    if [[ -d "$bundle" ]]; then
        name="${bundle:t}"
        codesign -d --verbose=4 "$bundle" > "$capture_dir/$name-signature.txt" 2>&1 || true
        codesign -d --entitlements :- "$bundle" > "$capture_dir/$name-entitlements.txt" 2>&1 || true
        /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$bundle/Contents/Info.plist" \
            > "$capture_dir/$name-version.txt"
    fi
done
pgrep -fl '^/Applications/MacPilot.app/Contents/' > "$capture_dir/processes.txt" || true
/usr/bin/log stream --style compact --level info --timeout "$duration" \
    --predicate 'eventMessage CONTAINS[c] "macpilot" OR eventMessage CONTAINS "SystemPolicyAppData" OR subsystem == "com.misswell.macpilot"' \
    > "$capture_dir/system.log" 2>&1
echo "Capture complete: $capture_dir/system.log"
