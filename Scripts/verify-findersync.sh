#!/bin/zsh
# Read-only FinderSync health check. Does not elect/register plugins or restart Finder.
# Exit 0 means the installed bundle is intact and elected, NOT visual menu acceptance.
set -euo pipefail

application="${1:-/Applications/MacPilot.app}"
extension="$application/Contents/PlugIns/FinderSync.appex"
identifier="com.misswell.macpilot.finder-sync"

if [[ ! -d "$extension" ]]; then
    print -u2 -- "FAIL: bundled Finder extension is missing: $extension"
    exit 1
fi
/usr/bin/codesign --verify --deep --strict "$extension"
inventory="$(/usr/bin/pluginkit -m -v -p com.apple.FinderSync -i "$identifier")"
print -r -- "$inventory"
print -r -- "$inventory" | /usr/bin/awk -F '\t' -v expected="$extension" '
    index($0, "com.misswell.macpilot.finder-sync(") {
        found = 1
        if ($0 !~ /^[[:space:]]*\+/) {
            print "FAIL: Finder extension is not elected for use"
            exit 1
        }
        if ($NF != expected) {
            print "FAIL: elected Finder extension belongs to a different bundle"
            exit 1
        }
        print "PASS: installed Finder extension is signed and elected for use"
    }
    END { if (!found) { print "FAIL: Finder extension is not registered"; exit 1 } }
'
