#!/bin/zsh
# MacPilot — resident-memory sampler.
#
# Answers one question per run: how much does each MacPilot process really hold?
# Absolute numbers are machine-dependent, so a run is only useful as one half of
# a comparison. Snapshot, perform the interaction, snapshot again, then `--diff`:
# acceptance is the delta, not the total.
#
# Usage:
#   Scripts/measure-memory.sh                       # median of 5 samples
#   Scripts/measure-memory.sh --label cold-idle     # name the snapshot
#   Scripts/measure-memory.sh --samples 9 --interval 2
#   Scripts/measure-memory.sh --only /tmp/build-a   # restrict to one bundle copy
#   Scripts/measure-memory.sh --deep                # add malloc detail (slow)
#   Scripts/measure-memory.sh --diff a.json b.json  # per-role delta
#
# Scope: processes whose executable lives inside a MacPilot.app bundle, plus the
# root-owned power helper. Other users' copies of the app are excluded by UID —
# a second instance on this machine is not this user's cost.
#
# Snapshots land in build/memory/ (gitignored): they carry pids and local paths.

set -uo pipefail

ROOT="${0:A:h:h}"
SAMPLES=5
INTERVAL=1
DEEP=0
LABEL="run"
ONLY=""
DIFF_A=""
DIFF_B=""

while (( $# > 0 )); do
    case "$1" in
        --samples) SAMPLES="$2"; shift 2 ;;
        --interval) INTERVAL="$2"; shift 2 ;;
        --label) LABEL="$2"; shift 2 ;;
        --only) ONLY="$2"; shift 2 ;;
        --deep) DEEP=1; shift ;;
        --diff) DIFF_A="$2"; DIFF_B="$3"; shift 3 ;;
        -h|--help) sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) print -u2 "unknown argument: $1"; exit 2 ;;
    esac
done

if [[ -n "$DIFF_A" ]]; then
    python3 - "$DIFF_A" "$DIFF_B" <<'PY'
import json, sys

def load(path):
    with open(path) as handle:
        data = json.load(handle)
    merged = {}
    for row in data["processes"]:
        entry = merged.setdefault(row["role"], {"footprint": 0, "count": 0, "peak": 0})
        entry["footprint"] += row["median_footprint"] or 0
        entry["peak"] = max(entry["peak"], row["peak_footprint"] or 0)
        entry["count"] += 1
    return data.get("label", "?"), data.get("version", "?"), merged

label_a, version_a, a = load(sys.argv[1])
label_b, version_b, b = load(sys.argv[2])

MB = 1024 * 1024
print(f"\n  memory delta: {label_a} ({version_a}) -> {label_b} ({version_b})\n")
print(f"  {'role':<14}{'before':>9}{'after':>9}{'delta':>9}   procs")
print(f"  {'-'*14:<14}{'-'*9:>9}{'-'*9:>9}{'-'*9:>9}   -----")
for role in sorted(set(a) | set(b)):
    left = a.get(role, {"footprint": 0, "count": 0})
    right = b.get(role, {"footprint": 0, "count": 0})
    delta = (right["footprint"] - left["footprint"]) / MB
    note = "" if abs(delta) < 5 else "   <-- outside sampling noise"
    print(f"  {role:<14}{left['footprint']/MB:>8.1f}M{right['footprint']/MB:>8.1f}M"
          f"{delta:>+9.1f}M   {left['count']}->{right['count']}{note}")
ta = sum(v["footprint"] for v in a.values()) / MB
tb = sum(v["footprint"] for v in b.values()) / MB
print(f"\n  {'TOTAL':<14}{ta:>8.1f}M{tb:>8.1f}M{tb - ta:>+9.1f}M")
print("  totals exclude processes the sampler could not read (see 'n/a' above)\n")
PY
    exit $?
fi

SELF_UID="$(id -u)"

discover() {
    ps -axo pid=,uid=,rss=,comm= | awk -v uid="$SELF_UID" -v only="$ONLY" '
        {
            path = $4
            if (only != "" && index(path, only) == 0) next
            if (path ~ /MacPilot\.app\/Contents\/MacOS\/MacPilot$/) role = "main"
            else if (path ~ /FinderSync\.appex\/Contents\/MacOS\//) role = "finder-sync"
            else if (path ~ /MacPilotPowerHelper$/) role = "power-helper"
            else if (path ~ /MacPilotDockHelper$/) role = "dock-helper"
            else next
            if (role == "power-helper") { if ($2 != 0) next } else if ($2 != uid) next
            print role "|" $1 "|" $2 "|" $3
        }'
}

# role|pid|uid|rss_kb|phys_footprint_bytes|peak_bytes, one line per process.
# phys_footprint is the kernel's own accounting and is what jetsam and the
# Activity Monitor use; RSS alone hides pure-CPU-mapped pages and lies about
# wired memory. An unreadable process reports empty fields, never a zero.
sample_all() {
    local role pid owner rss report fp peak
    while IFS='|' read -r role pid owner rss; do
        report="$(footprint -p "$pid" --format bytes --noCategories 2>/dev/null)"
        fp="$(print -r -- "$report" | awk '/^[[:space:]]*phys_footprint:/{print $2; exit}')"
        peak="$(print -r -- "$report" | awk '/phys_footprint_peak:/{print $2; exit}')"
        print "$role|$pid|$owner|$rss|$fp|$peak"
    done <<< "$(discover)"
}

RAW="$(mktemp -t macpilot-memory)"
trap 'rm -f "$RAW"' EXIT

for (( i = 1; i <= SAMPLES; i++ )); do
    sample_all >> "$RAW"
    (( i < SAMPLES )) && sleep "$INTERVAL"
done

if [[ ! -s "$RAW" ]]; then
    print -u2 "  no MacPilot processes found for uid $SELF_UID — is the app running?"
    exit 1
fi

OUT="$ROOT/build/memory/${LABEL}-$(date +%Y%m%d-%H%M%S).json"
mkdir -p "$ROOT/build/memory"

python3 - "$RAW" "$OUT" "$LABEL" "$SAMPLES" "$DEEP" "$(git -C "$ROOT" describe --tags 2>/dev/null || echo unknown)" <<'PY'
import json, subprocess, sys
from statistics import median

raw_path, out_path, label, samples, deep, version = sys.argv[1:7]
MB = 1024 * 1024


def to_mib(value):
    return float(value.rstrip("KMGkmg")) * {"K": 1024, "M": MB, "G": 1024 * MB}.get(value[-1], 1)


def as_int(value):
    try:
        return int(value)
    except ValueError:
        return None


rows, order = {}, []
for line in open(raw_path):
    parts = line.strip().split("|")
    if len(parts) != 6:
        continue
    key = (parts[0], parts[1])
    if key not in rows:
        rows[key] = {"uid": parts[2], "rss": [], "fp": [], "peak": []}
        order.append(key)
    rows[key]["rss"].append(int(parts[3]))
    rows[key]["fp"].append(as_int(parts[4]))
    rows[key]["peak"].append(as_int(parts[5]))

procs = []
for role, pid in order:
    data = rows[(role, pid)]
    readable = [value for value in data["fp"] if value is not None]
    peaks = [value for value in data["peak"] if value is not None]
    procs.append({
        "role": role,
        "pid": int(pid),
        "uid": int(data["uid"]),
        "median_rss_kb": int(median(data["rss"])),
        "median_footprint": int(median(readable)) if readable else None,
        "peak_footprint": max(peaks) if peaks else None,
        "samples": readable,
    })

with open(out_path, "w") as handle:
    json.dump({"label": label, "version": version, "samples": int(samples),
               "processes": procs}, handle, indent=2)

print(f"\n  MacPilot resident memory — {label} ({version}), median of {samples} samples\n")
print(f"  {'role':<14}{'pid':>7}{'uid':>6}{'footprint':>11}{'peak':>9}{'rss':>9}")
print(f"  {'-'*14:<14}{'-'*7:>7}{'-'*6:>6}{'-'*11:>11}{'-'*9:>9}{'-'*9:>9}")
total = sum(p["median_footprint"] or 0 for p in procs)
for proc in procs:
    footprint = f"{proc['median_footprint']/MB:.1f}M" if proc["median_footprint"] else "n/a"
    peak = f"{proc['peak_footprint']/MB:.1f}M" if proc["peak_footprint"] else "n/a"
    print(f"  {proc['role']:<14}{proc['pid']:>7}{proc['uid']:>6}"
          f"{footprint:>11}{peak:>9}{proc['median_rss_kb']/1024:>8.1f}M")
print(f"  {'TOTAL':<14}{'':>7}{'':>6}{total/MB:>10.1f}M")

if int(deep):
    print("\n  malloc zones (allocated / free — a widening gap is fragmentation):")
    for proc in procs:
        out = subprocess.run(["vmmap", "--summary", str(proc["pid"])],
                             capture_output=True, text=True).stdout
        alloc = free = 0.0
        zones = 0
        for line in out.splitlines():
            cols = line.split()
            if len(cols) > 3 and "Malloc" in cols[0] and cols[1][-1] in "KMG":
                zones += 1
                alloc += to_mib(cols[1])
                free += to_mib(cols[3])
        if zones:
            print(f"    {proc['role']:<13} pid {proc['pid']:<7} {alloc/MB:>7.1f}M / {free/MB:6.1f}M free")
        else:
            print(f"    {proc['role']:<13} pid {proc['pid']:<7} unavailable (vmmap needs task-for-pid rights)")

print(f"\n  snapshot: {out_path}\n")
PY
