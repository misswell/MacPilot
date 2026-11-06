import importlib.util
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("regression_index_guard", ROOT / "Scripts/regression-index-guard.py")
guard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(guard)
PLAN_SPEC = importlib.util.spec_from_file_location("regression_plan", ROOT / "Scripts/regression-plan.py")
planner = importlib.util.module_from_spec(PLAN_SPEC)
PLAN_SPEC.loader.exec_module(planner)


def fixture():
    return {
        "known_flaky_tests": ["OldTests.flaky"],
        "full_suite": {
            "baseline_extra_filters": ["BaselineTests"],
            "package_suites": [{"package_path": "Packages/P", "filter": "CoreTests"}],
            "extra_commands": ["python3 Scripts/check.py"],
        },
        "modules": [{"id": "m", "name": "Module", "rules": [{
            "id": "r", "module": "m", "title": "Rule", "status": "confirmed-recurring", "risk_level": "high", "affected_paths": ["Sources/A.swift"],
            "test_filters": ["ATests"], "manual_checks": ["check A"], "invariants": ["keep A"],
            "evidence_commits": ["abc"], "extra_test_commands": ["python3 Scripts/a.py"],
        }]}],
    }


class RegressionIndexGuardTests(unittest.TestCase):
    def test_additive_coverage_is_allowed(self):
        old, new = fixture(), fixture()
        new["modules"][0]["rules"][0]["test_filters"].append("NewTests")
        new["modules"][0]["rules"][0]["affected_paths"].append("Sources/B.swift")
        new["full_suite"]["baseline_extra_filters"].append("MoreBaseline")
        self.assertEqual([], guard.check_weakenings(old, new))

    def test_rule_and_module_removal_are_rejected(self):
        old, new = fixture(), fixture()
        new["modules"][0]["rules"].clear()
        self.assertTrue(any("removed rule" in e for e in guard.check_weakenings(old, new)))
        new["modules"].clear()
        self.assertTrue(any("removed module" in e for e in guard.check_weakenings(old, new)))

    def test_rule_coverage_shrink_and_status_downgrade_are_rejected(self):
        for field in ("affected_paths", "test_filters", "manual_checks", "invariants", "extra_test_commands"):
            old, new = fixture(), fixture()
            new["modules"][0]["rules"][0][field].clear()
            self.assertTrue(any(field in e for e in guard.check_weakenings(old, new)), field)
        old, new = fixture(), fixture()
        new["modules"][0]["rules"][0]["status"] = "confirmed-potential"
        self.assertTrue(any("downgraded" in e for e in guard.check_weakenings(old, new)))

    def test_full_suite_coverage_shrink_and_waiver_addition_are_rejected(self):
        for field in ("baseline_extra_filters", "package_suites", "extra_commands"):
            old, new = fixture(), fixture()
            new["full_suite"][field].clear()
            self.assertTrue(any(field in e for e in guard.check_weakenings(old, new)), field)
        old, new = fixture(), fixture()
        new["known_flaky_tests"].append("NewTests.waived")
        self.assertTrue(any("known_flaky_tests" in e for e in guard.check_weakenings(old, new)))

    def test_base_index_is_loaded_from_git_ref(self):
        base = guard.git_file("HEAD", "docs/engineering/REGRESSION_INDEX.json")
        self.assertIsInstance(base, dict)
        self.assertTrue(base["modules"])

    def test_forced_full_selects_every_rule_and_baseline_suite(self):
        index = fixture()
        index["modules"][0]["rules"][0]["manual_checks"] = ["manual"]
        index["modules"][0]["rules"][0]["extra_test_commands"] = ["python3 Scripts/rule.py"]
        plan = {"unmatched_source_files": [], "test_commands": [], "matched_rules": [], "manual_checks": []}
        actual = planner.force_full_plan(plan, index, "index changed", {"ChangedSuiteTests"})
        self.assertEqual("full", actual["escalation"])
        self.assertIn("ATests", actual["test_commands"][0]["verify_filter"])
        self.assertIn("BaselineTests", actual["test_commands"][0]["verify_filter"])
        self.assertIn("ChangedSuiteTests", actual["test_commands"][0]["verify_filter"])
        self.assertTrue(any("--package-path Packages/P" in c["command"] for c in actual["test_commands"]))
        self.assertTrue(any(c["command"] == "python3 Scripts/check.py" for c in actual["test_commands"]))
        self.assertTrue(any(c["command"] == "python3 Scripts/rule.py" for c in actual["test_commands"]))

    def test_index_path_is_code_and_cli_index_change_escalates(self):
        index_path = "docs/engineering/REGRESSION_INDEX.json"
        entries = [("M", "", index_path)]
        self.assertEqual("code", planner.classify(index_path))
        self.assertTrue(planner.regression_index_changed(entries, index_path))
        with tempfile.TemporaryDirectory() as temp:
            repo = Path(temp)
            (repo / "Scripts").mkdir()
            shutil.copy(ROOT / "Scripts/regression-plan.py", repo / "Scripts/regression-plan.py")
            (repo / "docs/engineering").mkdir(parents=True)
            (repo / "Tests").mkdir()
            (repo / "Tests/DummyTests.swift").write_text("struct DummyTests {}\n")
            index = fixture()
            index["modules"][0]["rules"][0]["affected_paths"] = [index_path]
            (repo / index_path).write_text(json.dumps(index))

            def git(*args):
                return subprocess.run(["git", *args], cwd=repo, check=True, capture_output=True, text=True).stdout.strip()

            git("init", "-q")
            git("config", "user.email", "guard-test@example.invalid")
            git("config", "user.name", "Guard Test")
            git("add", ".")
            git("commit", "-qm", "base")
            base = git("rev-parse", "HEAD")
            index["modules"][0]["rules"][0]["test_filters"].append("DummyTests")
            (repo / index_path).write_text(json.dumps(index))
            git("add", index_path)
            git("commit", "-qm", "expand regression coverage")
            result = subprocess.run(
                ["python3", "Scripts/regression-plan.py", "--mode", "range", "--base", base, "--head", "HEAD", "--format", "json"],
                cwd=repo, check=True, capture_output=True, text=True,
            )
            plan = json.loads(result.stdout)
            self.assertEqual("full", plan["escalation"])
            self.assertIn("(regression index changed; forced full safe suite)", plan["unmatched_source_files"])
            self.assertIn("DummyTests", plan["test_commands"][0]["verify_filter"])

    def test_python_only_test_change_runs_python_command_without_fake_swift_filter(self):
        with tempfile.TemporaryDirectory() as temp:
            repo = Path(temp)
            (repo / "Scripts").mkdir()
            shutil.copy(ROOT / "Scripts/regression-plan.py", repo / "Scripts/regression-plan.py")
            (repo / "docs/engineering").mkdir(parents=True)
            (repo / "Tests/Python").mkdir(parents=True)
            (repo / "Tests/DummyTests.swift").write_text("struct DummyTests {}\n")
            index = fixture()
            index["full_suite"]["extra_commands"].append("python3 Tests/Python/FakeTests.py")
            (repo / "docs/engineering/REGRESSION_INDEX.json").write_text(json.dumps(index))

            def git(*args):
                return subprocess.run(["git", *args], cwd=repo, check=True, capture_output=True, text=True).stdout.strip()

            git("init", "-q")
            git("config", "user.email", "guard-test@example.invalid")
            git("config", "user.name", "Guard Test")
            git("add", ".")
            git("commit", "-qm", "base")
            py_test = repo / "Tests/Python/FakeTests.py"
            py_test.write_text("class FakeRegressionTests: pass\n")
            result = subprocess.run(
                ["python3", "Scripts/regression-plan.py", "--mode", "local", "--format", "json"],
                cwd=repo, check=True, capture_output=True, text=True,
            )
            plan = json.loads(result.stdout)
            self.assertEqual("full", plan["escalation"])
            swift_filter = plan["test_commands"][0]["verify_filter"]
            self.assertNotIn("FakeRegressionTests", swift_filter)
            self.assertTrue(any(c.get("command") == "python3 Tests/Python/FakeTests.py" for c in plan["test_commands"]))

    def test_added_window_filter_is_selected(self):
        index = json.loads((ROOT / "docs/engineering/REGRESSION_INDEX.json").read_text())
        win = next(r for m in index["modules"] for r in m["rules"] if r["id"] == "win-001-main-window-opener")
        self.assertIn("WindowSwitcherFirstPressTests", win["test_filters"])
        self.assertEqual([], guard.check_weakenings(guard.git_file("HEAD", "docs/engineering/REGRESSION_INDEX.json"), index))


if __name__ == "__main__":
    unittest.main()
