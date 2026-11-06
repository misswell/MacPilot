#!/usr/bin/env python3
"""MacPilot regression plan selector.

Reads docs/engineering/REGRESSION_INDEX.json (the single source of truth shared
by agents, local runs and CI), inspects the git diff for this change, and emits
the set of historical regression tests that must run.

Modes:
  --mode local   working tree (staged + unstaged + untracked) vs HEAD
  --mode pr      --base <ref> vs --head <ref> (defaults: origin/main vs HEAD)
  --mode range   explicit --base/--head pair
  --validate     verify the index itself (referenced suites must exist) and exit

Design rules enforced here:
  * A source change that matches no rule escalates to the full safe suite
    instead of silently skipping tests.
  * Any change to the regression index forces the full safe suite.
  * Deleting a test file is always a hard error.
  * Test selection is driven only by the JSON index; CI must not keep a
    second list.

Exit codes: 0 ok, 1 planning error, 2 index validation error.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_INDEX = os.path.join(REPO_ROOT, "docs/engineering/REGRESSION_INDEX.json")

REQUIRED_RULE_KEYS = (
    "id",
    "module",
    "title",
    "status",
    "risk_level",
    "affected_paths",
    "invariants",
    "test_filters",
    "manual_checks",
    "evidence_commits",
)

# Declarations that can carry @Test methods (or extend a suite).
DECL_RE = re.compile(
    r"^[ \t]*(?:@\w+(?:\([^)]*\))?[ \t]*\n[ \t]*)*"
    r"(?:public |internal |private |fileprivate |open |final )*"
    r"(?:struct|class|actor|extension)[ \t]+([A-Za-z_][A-Za-z0-9_]*)",
    re.MULTILINE,
)

CODE_SUFFIXES = (".swift",)
SCRIPT_SUFFIXES = (".sh", ".py", ".zsh", ".swift")
NON_CODE_PREFIXES = ("docs/", "marketing/", "website/", ".github/PULL_REQUEST_TEMPLATE")


def run_git(args: list[str]) -> str:
    try:
        out = subprocess.run(
            ["git", "-C", REPO_ROOT] + args,
            capture_output=True,
            text=True,
            check=True,
        )
        return out.stdout
    except subprocess.CalledProcessError as exc:
        raise RuntimeError(f"git {' '.join(args)} failed: {exc.stderr.strip()}") from exc


def load_index(path: str) -> dict:
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def iter_rules(index: dict):
    for module in index.get("modules", []):
        for rule in module.get("rules", []):
            yield module, rule


def collect_declared_suites() -> set[str]:
    """Type names declared in test targets (Tests/ and any Packages/*/Tests/)."""
    names: set[str] = set()
    for root, _dirs, files in os.walk(os.path.join(REPO_ROOT, "Tests")):
        for name in files:
            if name.endswith(".swift"):
                _add_decls(os.path.join(root, name), names)
    for root, _dirs, files in os.walk(os.path.join(REPO_ROOT, "Packages")):
        if os.sep + "Tests" + os.sep not in root:
            continue
        for name in files:
            if name.endswith(".swift"):
                _add_decls(os.path.join(root, name), names)
    return names


def _add_decls(path: str, names: set[str]) -> None:
    try:
        with open(path, encoding="utf-8") as handle:
            content = handle.read()
    except OSError:
        return
    names.update(m[1] for m in DECL_RE.finditer(content))


def file_text_at(ref: str, path: str) -> str:
    try:
        return run_git(["show", f"{ref}:{path}"])
    except RuntimeError:
        return ""


def declared_suites_in_content(content: str) -> set[str]:
    """Only names that look like suites; helper types (Harness, Stub*) are noise."""
    return {
        name
        for name in (m[1] for m in DECL_RE.finditer(content))
        if name.endswith(("Tests", "Test"))
    }


# ---------------------------------------------------------------------------
# Validation


def validate_index(index: dict, index_path: str) -> list[str]:
    errors: list[str] = []
    rules = list(iter_rules(index))
    if not rules:
        errors.append("index contains no rules")
    seen_ids: set[str] = set()
    declared = collect_declared_suites()

    for _module, rule in rules:
        rid = rule.get("id", "<missing id>")
        for key in REQUIRED_RULE_KEYS:
            if key not in rule:
                errors.append(f"{rid}: missing required key '{key}'")
        if rid in seen_ids:
            errors.append(f"{rid}: duplicate rule id")
        seen_ids.add(rid)
        for status_value in (rule.get("status"),):
            if status_value not in ("confirmed-recurring", "confirmed-potential", "unverified"):
                errors.append(f"{rid}: invalid status '{status_value}'")
        if rule.get("risk_level") not in ("critical", "high", "medium", "low"):
            errors.append(f"{rid}: invalid risk_level '{rule.get('risk_level')}'")
        for fragment in rule.get("test_filters", []):
            if not any(re.search(fragment, name) for name in declared):
                errors.append(
                    f"{rid}: test filter '{fragment}' matches no declared suite in Tests/ "
                    "(fix the index, do not invent suites)"
                )
        for command in rule.get("extra_test_commands", []):
            if not command.startswith(("swift test", "python3 ", "zsh Scripts/", "./Scripts/")):
                errors.append(f"{rid}: unsafe/unknown extra_test_command '{command}'")
        for pattern in rule.get("affected_paths", []):
            if pattern.startswith("/") or ".." in pattern:
                errors.append(f"{rid}: affected_paths must be repo-relative: '{pattern}'")

    full = index.get("full_suite", {})
    for fragment in full.get("baseline_extra_filters", []):
        if not any(re.search(fragment, name) for name in declared):
            errors.append(f"full_suite: filter '{fragment}' matches no declared suite")
    for suite in full.get("package_suites", []):
        if not os.path.isdir(os.path.join(REPO_ROOT, suite["package_path"])):
            errors.append(f"full_suite: package path does not exist: {suite['package_path']}")
        if not suite.get("filter"):
            errors.append("full_suite: package suite without filter")
    for command in full.get("extra_commands", []):
        if not command.startswith(("swift test", "python3 ", "zsh Scripts/", "./Scripts/")):
            errors.append(f"full_suite: unsafe extra_command '{command}'")

    # The flake waiver list must not rot: every entry has to name a real suite
    # and a method, otherwise a stale entry would silently waive a future failure.
    for entry in index.get("known_flaky_tests", []):
        if not isinstance(entry, str) or "." not in entry:
            errors.append(f"known_flaky_tests: malformed entry '{entry}' (want Suite.method)")
            continue
        suite = entry.split(".", 1)[0]
        if not any(re.search(re.escape(suite), name) for name in declared):
            errors.append(
                f"known_flaky_tests: '{entry}' names suite '{suite}' which is not declared in Tests/"
            )

    if errors:
        print(f"INDEX VALIDATION FAILED ({len(errors)} error(s)) for {index_path}", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
    return errors


# ---------------------------------------------------------------------------
# Changed files


def parse_status_z(raw: str) -> list[tuple[str, str, str]]:
    """git status --porcelain -z -> (status, old, new).

    Porcelain -z records are `XY PATH` in one field; renames follow with the
    ORIGINAL path as a separate field, i.e. `R  NEW\0OLD\0`.
    """
    entries: list[tuple[str, str, str]] = []
    fields = raw.split("\0")
    i = 0
    while i < len(fields):
        status = fields[i]
        if not status:
            i += 1
            continue
        code = status[:2].strip() or "?"
        rest = status[3:] if len(status) > 2 else ""
        if code.startswith(("R", "C")):
            old, new = fields[i + 1], rest
            i += 2
        else:
            old, new = "", rest
            i += 1
        entries.append((code, old, new))
    return entries


def parse_diff_name_status_z(raw: str) -> list[tuple[str, str, str]]:
    """git diff --name-status -z -> (status, old, new).

    Unlike porcelain, each field holds ONE value: `STATUS\\0PATH\\0`,
    renames as `R100\\0OLD\\0NEW\\0`.
    """
    entries: list[tuple[str, str, str]] = []
    fields = [f for f in raw.split("\0") if f]
    i = 0
    while i < len(fields):
        code = fields[i].strip()
        if i + 1 >= len(fields):
            break
        if code.startswith(("R", "C")):
            if i + 2 >= len(fields):
                break
            old, new = fields[i + 1], fields[i + 2]
            i += 3
        else:
            old, new = "", fields[i + 1]
            i += 2
        entries.append((code, old, new))
    return entries


def changed_entries(mode: str, base: str | None, head: str | None) -> list[tuple[str, str, str]]:
    if mode == "local":
        raw = run_git(["status", "--porcelain", "-z", "--untracked-files=all"])
        return parse_status_z(raw)
    base_ref = base or "origin/main"
    head_ref = head or "HEAD"
    run_git(["rev-parse", "--verify", base_ref])
    run_git(["rev-parse", "--verify", head_ref])
    raw = run_git(["diff", "--name-status", "-z", f"{base_ref}...{head_ref}"])
    entries = parse_diff_name_status_z(raw)
    if not entries:
        raw = run_git(["diff", "--name-status", "-z", f"{base_ref}..{head_ref}"])
        entries = parse_diff_name_status_z(raw)
    return entries


def classify(path: str) -> str:
    """'test' | 'code' | 'docs' | 'other'."""
    if path == "docs/engineering/REGRESSION_INDEX.json":
        return "code"
    if path.startswith("Tests/") or "/Tests/" in path:
        return "test" if path.endswith(".swift") else "code"
    if path.startswith(NON_CODE_PREFIXES) or path.endswith(".md"):
        return "docs"
    if path == "Package.swift" or path.endswith("/Package.swift"):
        return "code"
    if path.startswith("Scripts/") and path.endswith(SCRIPT_SUFFIXES):
        return "code"
    if path.startswith(".github/workflows/") and path.endswith((".yml", ".yaml")):
        return "code"
    if path.startswith("Resources/"):
        return "code"
    if path.startswith(("Sources/", "iOS/", "Packages/")) and path.endswith(CODE_SUFFIXES):
        return "code"
    if path == "project.yml" or path.endswith("/project.yml"):
        return "code"
    return "other"


def regression_index_changed(entries: list[tuple[str, str, str]], index_path: str) -> bool:
    return any(index_path in (old, new) for _status, old, new in entries)


def path_matches(path: str, patterns: list[str]) -> bool:
    for pattern in patterns:
        if pattern.endswith("/**"):
            prefix = pattern[:-3]
            if path == prefix or path.startswith(prefix + "/"):
                return True
        elif "*" in pattern or "?" in pattern:
            if fnmatch.fnmatch(path, pattern):
                return True
            # globstar in the middle: Sources/**/Foo.swift
            if "**" in pattern:
                parts = pattern.split("**")
                if _globstar_match(path, parts):
                    return True
        elif path == pattern:
            return True
    return False


def _globstar_match(path: str, parts: list[str]) -> bool:
    if len(parts) < 2:
        return False
    if not path.startswith(parts[0]):
        return False
    path = path[len(parts[0]):]
    rest = parts[1:]
    for i, part in enumerate(rest):
        if not part:
            continue
        idx = path.find(part)
        if idx < 0:
            return False
        if i == len(rest) - 1:
            return path.endswith(part)
        path = path[idx + len(part):]
    return True


# ---------------------------------------------------------------------------
# Planning


def build_plan(index: dict, entries: list[tuple[str, str, str]]) -> dict:
    warnings: list[str] = []
    errors: list[str] = []
    changed: list[dict] = []
    matched_rules: list[dict] = []
    unmatched_code: list[str] = []
    test_file_suites: set[str] = set()
    deleted_test_files: list[str] = []

    for code, old, new in entries:
        primary = new or old
        kind = classify(primary)
        changed.append({"status": code, "path": primary, "renamed_from": old or None, "kind": kind})
        if kind == "test" and code in ("D",):
            deleted_test_files.append(primary)
            suites = declared_suites_in_content(file_text_at("HEAD", primary))
            if not suites:
                suites = {os.path.splitext(os.path.basename(primary))[0]}
            warnings.append(
                f"test file deleted: {primary} (suites lost: {', '.join(sorted(suites))})"
            )
            continue
        if kind == "test":
            local = os.path.join(REPO_ROOT, primary)
            if os.path.exists(local):
                with open(local, encoding="utf-8") as handle:
                    content = handle.read()
            else:
                # Range mode against a historical head: the file may only exist
                # in git, not in the working tree.
                content = file_text_at("HEAD", primary)
            test_file_suites.update(declared_suites_in_content(content))
            continue
        if kind != "code":
            continue
        hits = [
            (module, rule)
            for module, rule in iter_rules(index)
            if path_matches(primary, rule.get("affected_paths", []))
            or (old and path_matches(old, rule.get("affected_paths", [])))
        ]
        if not hits:
            unmatched_code.append(primary)
        for module, rule in hits:
            if not any(r["id"] == rule["id"] for r in matched_rules):
                matched_rules.append(
                    {
                        "id": rule["id"],
                        "module": module["id"],
                        "title": rule["title"],
                        "status": rule["status"],
                        "risk_level": rule["risk_level"],
                        "test_filters": rule.get("test_filters", []),
                        "extra_test_commands": rule.get("extra_test_commands", []),
                        "manual_checks": rule.get("manual_checks", []),
                    }
                )

    if deleted_test_files:
        errors.append(
            "test files were deleted: "
            + ", ".join(deleted_test_files)
            + " — test deletion is not allowed by the regression planner"
        )

    code_changed = bool(unmatched_code or matched_rules)
    escalation = "none"
    filters: set[str] = set()
    commands: list[dict] = []
    manual_checks: list[str] = []

    if code_changed or test_file_suites:
        for rule in matched_rules:
            filters.update(rule["test_filters"])
            manual_checks.extend(rule["manual_checks"])
        filters.update(test_file_suites)
        escalation = "module"
        if unmatched_code:
            escalation = "full"
            full = index.get("full_suite", {})
            for _m, rule in iter_rules(index):
                filters.update(rule.get("test_filters", []))
            filters.update(full.get("baseline_extra_filters", []))
            manual_checks = sorted(set(manual_checks))
            for suite in full.get("package_suites", []):
                commands.append(
                    {
                        "kind": "swift-test",
                        "command": f"swift test --package-path {suite['package_path']} --filter '{suite['filter']}'",
                        "verify_filter": suite["filter"],
                    }
                )
            for command in full.get("extra_commands", []):
                commands.append({"kind": "raw", "command": command})
        if escalation == "module":
            for rule in matched_rules:
                for command in rule["extra_test_commands"]:
                    commands.append({"kind": "raw", "command": command})
            if any(r["module"] == "ble-presence" for r in matched_rules):
                commands.append(
                    {
                        "kind": "swift-test",
                        "command": "swift test --package-path Packages/MacPilotRemoteProtocol --filter 'ProximityGATT|ReversePresence'",
                        "verify_filter": "ProximityGATT|ReversePresence",
                    }
                )

        pattern = "|".join(sorted(f for f in filters if f))
        if pattern:
            commands.insert(
                0,
                {
                    "kind": "swift-test",
                    "command": f"swift test --filter '{pattern}'",
                    "verify_filter": pattern,
                },
            )

    return {
        "index": os.path.relpath(DEFAULT_INDEX, REPO_ROOT),
        "escalation": escalation,
        "known_flaky_tests": index.get("known_flaky_tests", []),
        "changed_files": changed,
        "matched_rules": [
            {k: r[k] for k in ("id", "module", "title", "status", "risk_level")} for r in matched_rules
        ],
        "unmatched_source_files": unmatched_code,
        "test_file_suites": sorted(test_file_suites),
        "test_commands": commands,
        "manual_checks": sorted(set(manual_checks)),
        "warnings": warnings,
        "errors": errors,
    }


def force_full_plan(plan: dict, index: dict, reason: str, extra_filters: set[str] | None = None) -> dict:
    """Expand a plan to every safe baseline and historical rule suite."""
    full = index.get("full_suite", {})
    filters = {f for f in full.get("baseline_extra_filters", []) if f}
    filters.update(extra_filters or set())
    rules = list(iter_rules(index))
    for _module, rule in rules:
        filters.update(f for f in rule.get("test_filters", []) if f)
    pattern = "|".join(sorted(filters))
    plan["escalation"] = "full"
    if reason not in plan["unmatched_source_files"]:
        plan["unmatched_source_files"].append(reason)
    commands = [{"kind": "swift-test", "command": f"swift test --filter '{pattern}'", "verify_filter": pattern}]
    for suite in full.get("package_suites", []):
        commands.append({"kind": "swift-test", "command": f"swift test --package-path {suite['package_path']} --filter '{suite['filter']}'", "verify_filter": suite["filter"]})
    raw_commands = list(dict.fromkeys(
        [command for _module, rule in rules for command in rule.get("extra_test_commands", [])]
        + list(full.get("extra_commands", []))
    ))
    commands.extend({"kind": "raw", "command": command} for command in raw_commands)
    plan["test_commands"] = commands
    plan["matched_rules"] = [{k: r[k] for k in ("id", "module", "title", "status", "risk_level")} for _m, r in rules]
    plan["manual_checks"] = sorted({check for _m, rule in rules for check in rule.get("manual_checks", [])})
    return plan


def print_report(plan: dict, base: str, head: str, mode: str) -> None:
    print("=" * 72)
    print("MacPilot regression plan")
    print(f"mode={mode} base={base or '-'} head={head or '-'} escalation={plan['escalation']}")
    print("=" * 72)
    code_files = [c for c in plan["changed_files"] if c["kind"] in ("code", "test")]
    docs_files = [c for c in plan["changed_files"] if c["kind"] == "docs"]
    other_files = [c for c in plan["changed_files"] if c["kind"] == "other"]
    if code_files:
        print("\nChanged code/test files:")
        for entry in code_files:
            note = f" (renamed from {entry['renamed_from']})" if entry["renamed_from"] else ""
            print(f"  [{entry['status']}] {entry['path']}{note}")
    if docs_files or other_files:
        print(f"\nIgnored (non-code): {len(docs_files) + len(other_files)} file(s)")
    if plan["matched_rules"]:
        print("\nMatched historical regression rules:")
        for rule in plan["matched_rules"]:
            print(f"  - {rule['id']} [{rule['risk_level']}/{rule['status']}] {rule['title']}")
    else:
        print("\nMatched historical regression rules: none")
    if plan["unmatched_source_files"]:
        print("\nUNMATCHED source files (no rule covers them) -> full suite escalation:")
        for path in plan["unmatched_source_files"]:
            print(f"  ? {path}")
    if plan["test_file_suites"]:
        print("\nSuites declared in changed test files (always run):")
        print("  " + ", ".join(plan["test_file_suites"]))
    print(f"\nEscalation: {plan['escalation']}")
    print("\nTest commands:")
    if plan["test_commands"]:
        for command in plan["test_commands"]:
            print(f"  $ {command['command']}")
    else:
        print("  (none — no code changes detected)")
    if plan["manual_checks"]:
        print("\nManual checks that automation cannot replace (stay pending until executed):")
        for check in plan["manual_checks"]:
            print(f"  * {check}")
    for warning in plan["warnings"]:
        print(f"\nWARNING: {warning}")
    for error in plan["errors"]:
        print(f"\nERROR: {error}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("local", "pr", "range"), default="local")
    parser.add_argument("--base", help="base ref (pr/range mode)")
    parser.add_argument("--head", help="head ref (pr/range mode)")
    parser.add_argument("--index", default=DEFAULT_INDEX)
    parser.add_argument("--out", help="write the JSON plan to this file")
    parser.add_argument("--format", choices=("text", "json"), default="text")
    parser.add_argument("--validate", action="store_true", help="validate the index and exit")
    parser.add_argument(
        "--force-full",
        action="store_true",
        help="force full-suite escalation regardless of the diff (main merges, scheduled runs)",
    )
    args = parser.parse_args()

    try:
        index = load_index(args.index)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"ERROR: cannot load index {args.index}: {exc}", file=sys.stderr)
        return 2

    if args.validate:
        return 2 if validate_index(index, args.index) else 0

    try:
        entries = changed_entries(args.mode, args.base, args.head)
    except RuntimeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    index_path = os.path.relpath(args.index, REPO_ROOT)
    index_changed = regression_index_changed(entries, index_path)
    plan = build_plan(index, entries)
    base = args.base or ("HEAD" if args.mode == "local" else "origin/main")
    head = args.head or "HEAD"

    if args.force_full or index_changed:
        reason = "(regression index changed; forced full safe suite)" if index_changed else "(forced by --force-full)"
        plan = force_full_plan(plan, index, reason, set(plan.get("test_file_suites", [])))

    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            json.dump(plan, handle, ensure_ascii=False, indent=2)
    if args.format == "json":
        json.dump(plan, sys.stdout, ensure_ascii=False, indent=2)
        print()
    else:
        print_report(plan, base, head, args.mode)

    return 1 if plan["errors"] else 0


if __name__ == "__main__":
    sys.exit(main())
