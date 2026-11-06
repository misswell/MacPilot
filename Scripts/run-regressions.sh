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
ALLOW_TEST_DELETION=0
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
    --allow-test-deletion) ALLOW_TEST_DELETION=1; shift ;;
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
  [[ $ALLOW_TEST_DELETION -eq 1 ]] && PLAN_ARGS+=(--allow-test-deletion)
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

  bash -c "$CMD" >"$LOG" 2>&1
  CMD_FAILED=$?

  if [[ "$KIND" == "swift-test" ]]; then
    # Post-flight: prove tests actually executed, not just a zero exit code.
    EXECUTED=$(grep -cE '✔|✘|passed|failed|Test run with|Test Suite' "$LOG" || true)
    if [[ "$EXECUTED" -eq 0 ]]; then
      echo "FAIL: no executed-test evidence in output — refusing to count this as a pass." >&2
      FAILURES+=("$CMD [no execution evidence]")
      continue
    fi
    echo "   evidence: $EXECUTED result line(s)"
  fi

  if [[ $CMD_FAILED -eq 0 ]]; then
    echo "   PASS"
    continue
  fi

  echo "   failure context (last 50 lines of $LOG):"
  tail -n 50 "$LOG" | sed 's/^/   | /'

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
