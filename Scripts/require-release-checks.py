#!/usr/bin/env python3
"""Wait for successful, same-commit main validation before publishing a tag."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from typing import Any

REQUIRED_RUNS = ("build.yml", "regression-gate.yml", "pilotnest.yml")
REQUIRED_REGRESSION_JOBS = ("Regression Gate (macos-15)", "Regression Gate (macos-26)")


class GateError(RuntimeError):
    pass


def gh_json(args: list[str]) -> Any:
    result = subprocess.run(["gh", *args], text=True, capture_output=True)
    if result.returncode:
        raise GateError(result.stderr.strip() or f"gh {' '.join(args)} failed")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise GateError(f"gh returned invalid JSON: {exc}") from exc


def matching_run(repo: str, workflow: str, sha: str) -> dict[str, Any] | None:
    runs = gh_json([
        "run", "list", "--repo", repo, "--workflow", workflow, "--event", "push", "--commit", sha,
        "--json", "databaseId,headSha,headBranch,event,status,conclusion", "--limit", "50",
    ])
    return next((
        run for run in runs
        if run.get("headSha") == sha and run.get("headBranch") == "main" and run.get("event") == "push"
    ), None)


def verify_regression_jobs(repo: str, run_id: int) -> None:
    details = gh_json(["run", "view", str(run_id), "--repo", repo, "--json", "jobs"])
    jobs = {job.get("name"): job for job in details.get("jobs", [])}
    for name in REQUIRED_REGRESSION_JOBS:
        job = jobs.get(name)
        if not job:
            raise GateError(f"Regression Gate run {run_id} has no required job {name}")
        if job.get("status") != "completed" or job.get("conclusion") != "success":
            raise GateError(
                f"Regression Gate job {name} ended as "
                f"{job.get('status')}/{job.get('conclusion') or 'no conclusion'}"
            )


def wait_for_checks(repo: str, sha: str, *, timeout: float, interval: float) -> None:
    deadline = time.monotonic() + timeout
    for workflow in REQUIRED_RUNS:
        while True:
            run = matching_run(repo, workflow, sha)
            if run is not None:
                status, conclusion = run.get("status"), run.get("conclusion")
                if status == "completed":
                    if conclusion != "success":
                        raise GateError(f"{workflow} for {sha} concluded {conclusion or 'unknown'}")
                    if workflow == "regression-gate.yml":
                        verify_regression_jobs(repo, int(run["databaseId"]))
                    print(f"{workflow} passed for {sha}")
                    break
            if time.monotonic() >= deadline:
                detail = "no run found" if run is None else f"run is {run.get('status')}"
                raise GateError(f"timed out waiting for {workflow} at {sha}: {detail}")
            time.sleep(interval)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--timeout", type=float, default=1_800)
    parser.add_argument("--poll-interval", type=float, default=10)
    args = parser.parse_args()
    if args.timeout < 0 or args.poll_interval < 0:
        parser.error("timeout and poll interval must be nonnegative")
    try:
        wait_for_checks(args.repo, args.sha, timeout=args.timeout, interval=args.poll_interval)
    except (GateError, KeyError, ValueError) as exc:
        print(f"RELEASE BLOCKED: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
