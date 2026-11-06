#!/bin/bash
# run-regressions.sh — execute the regression plan produced by regression-plan.py.
#
# Usage:
#   bash Scripts/run-regressions.sh                      # working tree vs HEAD
#   bash Scripts/run-regressions.sh --base origin/main   # PR-style range
#   bash Scripts/run-regressions.sh --plan plan.json     # reuse a prepared plan
#   bash Scripts/run-regressions.sh --validate-only      # only check the index
#
# Guarantees:
#   * Index validation failure fails the run (exit 2).
#   * Planning errors (e.g. deleted test files) fail the run (exit 3).
#   * Every swift-test command must list at least one test beforehand
#     (`swift test list`) and report executed tests in its output; a command
#     that matches nothing is an index error, not a pass.
#   * Any test failure fails the run (exit 4).

set -uo pipefail

# zsh users must still be able to run `zsh Scripts/run-regressions.sh`:
# mapfile/BASH_SOURCE below are bash-only, so re-exec under bash.
if [[ -z "${BASH_VERSION:-}" ]]; then
  exec bash "$0" "$@"
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
PLAN_FILE=""
MODE="local"
BASE=""
HEAD=""
FORCE_FULL=0
VALIDATE_ONLY=0
LOG_DIR="$REPO_ROOT/.regression-logs"

usage() {
  grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -16
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan) PLAN_FILE="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --head) HEAD="$2"; shift 2 ;;
    --force-full) FORCE_FULL=1; shift ;;
    --validate-only) VALIDATE_ONLY=1; shift ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done

cd "$REPO_ROOT"

# A bare --base/--head means "compare these refs", not "inspect the working
# tree"; local mode ignores refs, so promote the mode instead of silently
# selecting tests from the wrong diff.
if [[ -n "$BASE$HEAD" && "$MODE" == "local" ]]; then
  MODE="range"
fi

echo "== [1/4] Validating regression index =="
GUARD_BASE="${BASE:-HEAD}"
GUARD_HEAD="${HEAD:-WORKTREE}"
if ! python3 Scripts/regression-index-guard.py --base "$GUARD_BASE" --head "$GUARD_HEAD"; then
  echo "FAIL: regression index weakens its base coverage." >&2
  exit 2
fi
if ! python3 Scripts/regression-plan.py --validate; then
  echo "FAIL: REGRESSION_INDEX.json is invalid (references missing suites or malformed rules)." >&2
  exit 2
fi
echo "Index OK."
if [[ $VALIDATE_ONLY -eq 1 ]]; then
  exit 0
fi

if [[ -z "$PLAN_FILE" ]]; then
  PLAN_FILE="$LOG_DIR/plan.json"
  mkdir -p "$LOG_DIR"
  PLAN_ARGS=(--mode "$MODE" --out "$PLAN_FILE")
  [[ -n "$BASE" ]] && PLAN_ARGS+=(--base "$BASE")
  [[ -n "$HEAD" ]] && PLAN_ARGS+=(--head "$HEAD")
  [[ $FORCE_FULL -eq 1 ]] && PLAN_ARGS+=(--force-full)
  echo "== [2/4] Building regression plan (${MODE}) =="
  if ! python3 Scripts/regression-plan.py "${PLAN_ARGS[@]}"; then
    echo "FAIL: regression plan has errors (see above)." >&2
    exit 3
  fi
else
  echo "== [2/4] Using prepared plan: $PLAN_FILE"
fi

# bash 3.2 (macOS /bin/bash) has no mapfile — read line by line.
COMMANDS=()
while IFS= read -r entry; do
  [[ -n "$entry" ]] && COMMANDS+=("$entry")
done < <(python3 - "$PLAN_FILE" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
for c in plan.get("test_commands", []):
    print(json.dumps(c))
PY
)

echo "== [3/4] Running ${#COMMANDS[@]} test command(s) =="
mkdir -p "$LOG_DIR"

# Pre-flight test inventory. `swift test list --filter` is NOT reliable here
# (it ignores the filter on several toolchains and lists everything), so the
# full inventory is produced once and each filter is matched against it.
TEST_INVENTORY="$LOG_DIR/test-inventory.txt"
if ! swift test list >"$TEST_INVENTORY" 2>&1; then
  echo "FAIL: 'swift test list' could not enumerate tests." >&2
  exit 3
fi
INVENTORY_COUNT=$(grep -c . "$TEST_INVENTORY" || true)
echo "test inventory: $INVENTORY_COUNT test(s)"

# Waiver list comes from the plan (i.e. from REGRESSION_INDEX.json), never from
# this script — one source of truth.
KNOWN_FLAKEY=()
while IFS= read -r flake; do
  [[ -n "$flake" ]] && KNOWN_FLAKEY+=("$flake")
done < <(python3 - "$PLAN_FILE" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
for entry in plan.get("known_flaky_tests", []):
    print(entry)
PY
)
WAIVED_TOTAL=0

FAILURES=()
IDX=0
for entry in "${COMMANDS[@]}"; do
  IDX=$((IDX + 1))
  CMD="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["command"])' "$entry")"
  KIND="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("kind","raw"))' "$entry")"
  VERIFY_FILTER="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("verify_filter",""))' "$entry")"
  if [[ "$KIND" == "swift-test" && "$CMD" != *"--no-parallel"* ]]; then
    CMD="$CMD --no-parallel"
  fi
  LOG="$LOG_DIR/$(printf '%02d' $IDX)-$(echo "$CMD" | tr '/ |' '_--' | cut -c1-80).log"

  echo "----------------------------------------------------------------"
  echo "\$ $CMD"
  echo "   log: $LOG"

  if [[ "$KIND" == "swift-test" ]]; then
    # Pre-flight: the filter must resolve to at least one test in the inventory.
    # A filter that matches nothing means the index references suites that do
    # not exist (or the plan was hand-edited wrongly). Package-path commands
    # get their own inventory.
    INVENTORY="$TEST_INVENTORY"
    if [[ "$CMD" == *"--package-path "* ]]; then
      PKG_PATH="$(python3 - "$CMD" <<'PY'
import re, sys
m = re.search(r"--package-path (\S+)", sys.argv[1])
print(m.group(1) if m else "")
PY
)"
      PKG_INVENTORY="$LOG_DIR/test-inventory-$(echo "$PKG_PATH" | tr '/' '_').txt"
      if ! swift test list --package-path "$PKG_PATH" >"$PKG_INVENTORY" 2>&1; then
        echo "FAIL: 'swift test list --package-path $PKG_PATH' failed." >&2
        FAILURES+=("$CMD [package test listing failed]")
        continue
      fi
      INVENTORY="$PKG_INVENTORY"
    fi
    LISTED=$(grep -cE "$VERIFY_FILTER" "$INVENTORY" || true)
    if [[ "$LISTED" -eq 0 ]]; then
      echo "FAIL: filter matches no tests: $VERIFY_FILTER (index references missing suites)" >&2
      FAILURES+=("$CMD [no tests matched]")
      continue
    fi
    echo "   pre-flight: $LISTED test(s) listed"
  fi

  CRASH_MARKER="$LOG_DIR/.test-start-$$-$IDX"
  touch "$CRASH_MARKER"
  bash -c "$CMD" >"$LOG" 2>&1
  CMD_FAILED=$?
  echo "   command exit code: $CMD_FAILED"

  if [[ "$KIND" == "swift-test" ]]; then
    # Post-flight: prove tests actually executed, not just a zero exit code.
    EXECUTED=$(grep -cE '✔|✘|passed|failed|Test run with|Test Suite' "$LOG" || true)
    if [[ "$EXECUTED" -eq 0 ]]; then
      echo "FAIL: no executed-test evidence in output — refusing to count this as a pass." >&2
      rm -f "$CRASH_MARKER"
      FAILURES+=("$CMD [no execution evidence]")
      continue
    fi
    echo "   evidence: $EXECUTED result line(s)"
  fi

  if [[ $CMD_FAILED -eq 0 ]]; then
    echo "   PASS"
    rm -f "$CRASH_MARKER"
    continue
  fi

  echo "   failure context (last 50 lines of $LOG):"
  tail -n 50 "$LOG" | sed 's/^/   | /'

  if [[ "$KIND" == "swift-test" ]]; then
    python3 - "$LOG_DIR" "$CRASH_MARKER" "$CMD_FAILED" "$LOG" <<'PY'
import json, re, shutil, sys
from pathlib import Path
import time

log_dir = Path(sys.argv[1])
marker = Path(sys.argv[2])
exit_code = int(sys.argv[3])
test_log = Path(sys.argv[4])
started = marker.stat().st_mtime
destination = log_dir / "crash-diagnostics"
destination.mkdir(exist_ok=True)
candidate_roots = [
    Path.home() / "Library/Logs/DiagnosticReports",
    Path("/Library/Logs/DiagnosticReports"),
]
log_output = test_log.read_text(errors="replace") if test_log.is_file() else ""
wait_for_report = exit_code >= 128 or "Test run with" not in log_output
copied = []
for attempt in range(11 if wait_for_report else 1):
    for root in candidate_roots:
        if not root.is_dir():
            continue
        try:
            reports = sorted(
                (p for p in root.iterdir() if p.is_file() and p.suffix.lower() in {".ips", ".crash"}
                 and p.stat().st_mtime >= started),
                key=lambda p: p.stat().st_mtime,
                reverse=True,
            )
        except OSError:
            continue
        for report in reports:
            if len(copied) >= 10:
                break
            try:
                content = report.read_text(errors="replace")[:3_000_000]
            except OSError:
                continue
            process_field = re.search(
                r'"(?:procName|app_name)"\s*:\s*"([^"]+)"|^Process:\s*([^,\n]+)',
                content,
                re.I | re.M,
            )
            process_name = next((value for value in process_field.groups() if value), "") if process_field else ""
            relevant = re.search(r"swift|xctest|macpilot|testhost", report.name + "\n" + process_name, re.I)
            if not relevant:
                continue
            target = destination / report.name
            try:
                shutil.copy2(report, target)
            except OSError:
                continue
            copied.append((target, content))
        if len(copied) >= 10:
            break
    if copied or attempt == 10 or not wait_for_report:
        break
    time.sleep(1)

summary = []
for path, content in copied:
    process = "unknown"
    exception = "unknown"
    frames = []
    try:
        report = json.loads(content)
    except json.JSONDecodeError:
        report = None
    if isinstance(report, dict):
        process = str(report.get("procName") or report.get("app_name") or process)
        exception_info = report.get("exception")
        if isinstance(exception_info, dict):
            exception = str(exception_info.get("type") or exception_info.get("signal") or exception)
        threads = report.get("threads", [])
        faulting = report.get("faultingThread")
        if isinstance(faulting, int) and faulting < len(threads):
            frames = threads[faulting].get("frames", [])
        if not frames and threads:
            frames = threads[0].get("frames", [])
        frames = [str(f.get("symbol") or f.get("imageOffset") or f.get("imageIndex")) for f in frames[:12]]
    else:
        match = re.search(r"^Process:\s*(.+)$", content, re.M)
        if match:
            process = match.group(1).strip()
        match = re.search(r"^Exception Type:\s*(.+)$", content, re.M)
        if match:
            exception = match.group(1).strip()
        match = re.search(r"^Crashed Thread:\s*(.+)$", content, re.M)
        if match:
            frames = content[match.end():].splitlines()[:14]
    summary.extend([f"{path.name}: process={process}; exception={exception}", *[f"  {frame}" for frame in frames]])

summary_path = destination / "summary.log"
summary_path.write_text("\n".join(summary) + ("\n" if summary else "No matching Swift/XCTest/MacPilot crash reports found after bounded scan.\n"))
print(f"   crash diagnostics: {len(copied)} related report(s); waited up to {10 if wait_for_report and not copied else 0}s; {summary_path}")
PY
  fi
  rm -f "$CRASH_MARKER"

  # A swift-test failure is only waivable when EVERY failing test is listed in
  # the index's known_flaky_tests AND passes when re-run alone. Anything else —
  # including an unlisted test that "always flakes" — stays a hard gate failure.
  UNWAIVED=""
  if [[ "$KIND" == "swift-test" ]]; then
    FAILED_METHODS="$(grep -oE '^✘ Test [A-Za-z0-9_]+\(\)' "$LOG" | sed 's/^✘ Test //; s/()$//' | sort -u)"
  fi
  if [[ "$KIND" == "swift-test" && -n "$FAILED_METHODS" ]]; then
    while IFS= read -r method; do
      [[ -z "$method" ]] && continue
      MATCHING_ID=""
      if [[ ${#KNOWN_FLAKEY[@]} -gt 0 ]]; then
        MATCHING_ID="$(printf '%s\n' "${KNOWN_FLAKEY[@]}" | grep -E "\.${method}\$" | head -1 || true)"
      fi
      if [[ -z "$MATCHING_ID" ]]; then
        UNWAIVED="$UNWAIVED $method(not documented)"
        continue
      fi
      RETRY_LOG="$LOG_DIR/waiver-retry-$(echo "$MATCHING_ID" | tr './' '__').log"
      if swift test --no-parallel --filter "$MATCHING_ID" >"$RETRY_LOG" 2>&1; then
        echo "   WAIVED: $MATCHING_ID (documented timing-class flake; passes in isolation — $RETRY_LOG)"
        WAIVED_TOTAL=$((WAIVED_TOTAL + 1))
      else
        UNWAIVED="$UNWAIVED $MATCHING_ID(fails alone too)"
      fi
    done <<< "$FAILED_METHODS"
  fi

  if [[ -z "$UNWAIVED" && "$KIND" == "swift-test" && -n "$FAILED_METHODS" ]]; then
    echo "   PASS (all failures waived after isolation re-run)"
  else
    echo "   FAIL (see log)$UNWAIVED"
    FAILURES+=("$CMD")
  fi
done

echo "== [4/4] Summary =="
echo "waived (documented flakes that pass when re-run alone): $WAIVED_TOTAL"
python3 - "$PLAN_FILE" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
print(f"escalation: {plan.get('escalation', 'unknown')}")
print(f"matched rules: {', '.join(r['id'] for r in plan.get('matched_rules', [])) or 'none'}")
for p in plan.get("unmatched_source_files", []):
    print(f"  ? unmatched source file: {p}")
for c in plan.get("manual_checks", []):
    print(f"  * manual check pending (mock tests cannot replace this): {c}")
PY

if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo "REGRESSION GATE FAILED:" >&2
  for f in "${FAILURES[@]}"; do echo "  - $f" >&2; done
  exit 4
fi
echo "REGRESSION GATE PASSED"
