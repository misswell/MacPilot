#!/usr/bin/env python3
"""Unit tests for the signed release validation gate; all gh calls are mocked."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/require-release-checks.py"
SHA = "a" * 40
RUNS = {
    "build.yml": {"databaseId": 1, "headSha": SHA, "headBranch": "main", "event": "push", "status": "completed", "conclusion": "success"},
    "regression-gate.yml": {"databaseId": 2, "headSha": SHA, "headBranch": "main", "event": "push", "status": "completed", "conclusion": "success"},
    "pilotnest.yml": {"databaseId": 3, "headSha": SHA, "headBranch": "main", "event": "push", "status": "completed", "conclusion": "success"},
}
JOBS = [
    {"name": "Regression Gate (macos-15)", "status": "completed", "conclusion": "success"},
    {"name": "Regression Gate (macos-26)", "status": "completed", "conclusion": "success"},
]
MOCK_GH = r'''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
scenario = os.environ["SCENARIO"]
if args[:2] == ["run", "list"]:
    workflow = args[args.index("--workflow") + 1]
    data = json.load(open(os.environ["GATE_DATA"], encoding="utf-8"))
    record = data.get(workflow)
    runs = [record] if record else []
    if scenario == "missing": runs = []
    if scenario == "old_sha" and runs: runs = [{**runs[0], "headSha": "b" * 40}]
    if scenario == "dispatch" and workflow == "build.yml" and runs:
        runs = [{**runs[0], "event": "workflow_dispatch"}]
    if scenario == "failed" and workflow == "build.yml" and runs:
        runs = [{**runs[0], "conclusion": "failure"}]
    if scenario == "regression_failed" and workflow == "regression-gate.yml" and runs:
        runs = [{**runs[0], "conclusion": "failure"}]
    if scenario == "cancelled" and workflow == "pilotnest.yml" and runs:
        runs = [{**runs[0], "conclusion": "cancelled"}]
    if "--jq" in args:
        runs = [run for run in runs if run.get("headBranch") == "main"]
        print(json.dumps(runs[0] if runs else None)); raise SystemExit(0)
    print(json.dumps(runs or [])); raise SystemExit(0)
if args[:2] == ["run", "view"]:
    jobs = json.load(open(os.environ["GATE_DATA"], encoding="utf-8"))["jobs"]
    if scenario == "mac26_missing": jobs = jobs[:1]
    if scenario == "mac26_failed": jobs = [jobs[0], {**jobs[1], "conclusion": "failure"}]
    print(json.dumps({"jobs": jobs})); raise SystemExit(0)
raise SystemExit("unexpected gh invocation: " + repr(args))
'''

class ReleaseGateTests(unittest.TestCase):
    def run_gate(self, scenario: str, data: dict) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            gh = root / "gh"
            gh.write_text(MOCK_GH, encoding="utf-8")
            gh.chmod(0o755)
            data_path = root / "gate.json"
            data_path.write_text(json.dumps(data), encoding="utf-8")
            env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}", SCENARIO=scenario, GATE_DATA=str(data_path))
            return subprocess.run(
                ["python3", str(SCRIPT), "--repo", "misswell/MacPilot", "--sha", SHA,
                 "--timeout", "0", "--poll-interval", "0"],
                cwd=ROOT, env=env, text=True, capture_output=True, check=False,
            )

    def run_legacy_build_only_gate(self, scenario: str, data: dict) -> subprocess.CompletedProcess[str]:
        legacy = subprocess.run(
            ["git", "show", "origin/main:.github/workflows/release-common.yml"],
            cwd=ROOT, text=True, capture_output=True, check=True,
        ).stdout
        start = legacy.index("      - name: Require successful main-branch validation")
        run_start = legacy.index("        run: |\n", start) + len("        run: |\n")
        end = legacy.index("\n  dist:\n", run_start)
        script = "\n".join(line[10:] for line in legacy[run_start:end].splitlines())
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            gh = root / "gh"
            gh.write_text(MOCK_GH, encoding="utf-8")
            gh.chmod(0o755)
            data_path = root / "gate.json"
            data_path.write_text(json.dumps(data), encoding="utf-8")
            env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}", SCENARIO=scenario,
                       GATE_DATA=str(data_path), GITHUB_REPOSITORY="misswell/MacPilot", GITHUB_SHA=SHA)
            return subprocess.run(
                ["bash", "-euo", "pipefail", "-c", script], cwd=ROOT, env=env,
                text=True, capture_output=True, check=False,
            )

    def test_all_same_sha_checks_and_both_regression_macos_jobs_pass(self) -> None:
        self.assertEqual(self.run_gate("success", {**RUNS, "jobs": JOBS}).returncode, 0)

    def test_failed_build_blocks_release(self) -> None:
        result = self.run_gate("failed", {**RUNS, "jobs": JOBS})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("build.yml", result.stderr)

    def test_legacy_build_only_gate_passes_while_regression_failure_blocks_new_gate(self) -> None:
        failure = {**RUNS, "regression-gate.yml": {**RUNS["regression-gate.yml"], "conclusion": "failure"},
                   "jobs": JOBS}
        legacy = self.run_legacy_build_only_gate("regression_failed", failure)
        self.assertEqual(legacy.returncode, 0, legacy.stderr)
        current = self.run_gate("regression_failed", failure)
        self.assertNotEqual(current.returncode, 0)
        self.assertIn("regression-gate.yml", current.stderr)

    def test_missing_or_untriggered_workflow_blocks_on_timeout(self) -> None:
        result = self.run_gate("missing", {**RUNS, "jobs": JOBS})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no run found", result.stderr)

    def test_run_for_an_old_sha_is_not_accepted(self) -> None:
        result = self.run_gate("old_sha", {**RUNS, "jobs": JOBS})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(SHA, result.stderr)

    def test_successful_signed_manual_run_cannot_replace_main_push_build(self) -> None:
        result = self.run_gate("dispatch", {**RUNS, "jobs": JOBS})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no run found", result.stderr)

    def test_cancelled_pilotnest_run_blocks_release(self) -> None:
        result = self.run_gate("cancelled", {**RUNS, "jobs": JOBS})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cancelled", result.stderr)

    def test_missing_or_failed_macos_26_regression_job_blocks_release(self) -> None:
        for scenario in ("mac26_missing", "mac26_failed"):
            with self.subTest(scenario=scenario):
                result = self.run_gate(scenario, {**RUNS, "jobs": JOBS})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("macos-26", result.stderr)

if __name__ == "__main__":
    unittest.main()
