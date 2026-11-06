#!/usr/bin/env python3
"""Reject weakening the historical regression index relative to a base ref."""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

INDEX = "docs/engineering/REGRESSION_INDEX.json"
STATUS_RANK = {"unverified": 0, "confirmed-potential": 1, "confirmed-recurring": 2}


def git_file(ref: str, path: str) -> dict | None:
    result = subprocess.run(["git", "show", f"{ref}:{path}"], text=True, capture_output=True)
    if result.returncode:
        return None
    return json.loads(result.stdout)


def as_rules(index: dict) -> tuple[dict[str, dict], dict[str, str]]:
    rules: dict[str, dict] = {}
    modules: dict[str, str] = {}
    for module in index.get("modules", []):
        mid = module.get("id", "")
        modules[mid] = module.get("name", "")
        for rule in module.get("rules", []):
            rules[rule.get("id", "")] = rule
    return rules, modules


def check_weakenings(base: dict, head: dict) -> list[str]:
    errors: list[str] = []
    old_rules, old_modules = as_rules(base)
    new_rules, new_modules = as_rules(head)
    for mid in sorted(old_modules.keys() - new_modules.keys()):
        errors.append(f"removed module: {mid}")
    for rid in sorted(old_rules.keys() - new_rules.keys()):
        errors.append(f"removed rule: {rid}")
    list_fields = ("affected_paths", "test_filters", "manual_checks", "invariants", "evidence_commits", "extra_test_commands")
    for rid in sorted(old_rules.keys() & new_rules.keys()):
        before, after = old_rules[rid], new_rules[rid]
        for field in list_fields:
            old_values = before.get(field, [])
            new_values = after.get(field, [])
            missing = [value for value in old_values if value not in new_values]
            if missing:
                errors.append(f"{rid}: removed {field} coverage: {missing!r}")
        old_status = STATUS_RANK.get(before.get("status"), -1)
        new_status = STATUS_RANK.get(after.get("status"), -1)
        if new_status < old_status:
            errors.append(f"{rid}: status downgraded from {before.get('status')} to {after.get('status')}")
    old_full, new_full = base.get("full_suite", {}), head.get("full_suite", {})
    for field in ("baseline_extra_filters", "package_suites", "extra_commands"):
        missing = [value for value in old_full.get(field, []) if value not in new_full.get(field, [])]
        if missing:
            errors.append(f"full_suite: removed {field} coverage: {missing!r}")
    added_waivers = sorted(set(head.get("known_flaky_tests", [])) - set(base.get("known_flaky_tests", [])))
    if added_waivers:
        errors.append(f"added known_flaky_tests waiver(s): {added_waivers!r}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", default="WORKTREE", help="git ref or WORKTREE")
    parser.add_argument("--index", default=INDEX)
    args = parser.parse_args()
    try:
        base = git_file(args.base, args.index)
        head = json.loads(Path(args.index).read_text()) if args.head == "WORKTREE" else git_file(args.head, args.index)
        if base is None:
            raise ValueError(f"base {args.base} has no {args.index} (bootstrap is allowed only for initial introduction)")
        if head is None:
            raise ValueError(f"head {args.head} has no {args.index}")
        errors = check_weakenings(base, head)
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        print(f"REGRESSION INDEX GUARD ERROR: {exc}", file=sys.stderr)
        return 2
    if errors:
        print("REGRESSION INDEX WEAKENING REJECTED", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1
    print(f"Regression index preserves or expands base coverage ({args.base} → {args.head}).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
