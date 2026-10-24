"""Exercise response-latency measurement through the private benchmark launcher."""
from pathlib import Path
import os
import shutil
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import run_render_perf_gate as gate
import run_scenarios as scenarios


class ResponseBudgetTests(unittest.TestCase):
    def test_response_budget_is_separate_from_present_wait_and_render_cost(self):
        scenario = scenarios.SCENARIOS["autocomplete-navigation-latency"]
        run = {"metrics": {"work_ms_p95": 250, "work_ms_max": 250}, "actions": {
            "next": {"latency_ms_p50": 1, "latency_ms_p95": 1, "latency_ms_max": 1, "redraws_p50": 1},
        }}
        result = scenarios.score(scenario, [run])
        self.assertIsNone(result["frame"])
        self.assertEqual(result["findings"], [])
        run["actions"]["next"]["latency_ms_p95"] = scenario.action_budget_ms * 2
        result = scenarios.score(scenario, [run])
        self.assertEqual([item["metric"] for item in result["findings"]], ["next latency p95"])


@unittest.skipUnless(os.name == "nt", "requires the private Windows desktop launcher")
class ResponseLatencyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="anvil-response-tests-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.root = Path(cls.temp.name)
        cls.exe = gate.copy_app_tree(cls.root / "app")
        shutil.copy2(ROOT / "tests/fixtures/perf_response_probe.lua",
                     cls.root / "app/share/anvil/scenes/response_probe.lua")
        cls.project = cls.root / "project"
        cls.project.mkdir()

    def run_probe(self, cadence="normal", **settings):
        work = self.root / self._testMethodName
        user = work / "user"
        user.mkdir(parents=True)
        return gate.run_case(
            exe=self.exe, work=work, user=user, fixture=self.project, tab_dir=self.project,
            scenario="response-probe", renderer="software", mode="metrics",
            settings=dict(kind="scene", scene="response_probe", actions=3,
                          root=str(self.project), cadence=cadence,
                          window_width=800, window_height=600, **settings),
            run_dir=work / "run", frames=100, warmup_frames=2, screenshot=False,
            total_timeout_seconds=90, startup_timeout_seconds=60,
            heartbeat_timeout_seconds=30, action_timeout_seconds=3)

    def test_missing_redraw_fails_instead_of_getting_one_from_the_harness(self):
        with self.assertRaises(gate.BenchmarkCaseError) as caught:
            self.run_probe(request_redraw=False)
        self.assertIn("benchmark action timed out", caught.exception.details["error"])

    def test_pending_result_does_not_get_repeated_redraws_from_the_harness(self):
        with self.assertRaises(gate.BenchmarkCaseError) as caught:
            self.run_probe(request_redraw=True, late_result=True)
        self.assertIn("benchmark action timed out", caught.exception.details["error"])

    def test_requested_redraws_complete_without_bypassing_the_frame_deadline(self):
        result = self.run_probe(request_redraw=True)
        self.assertEqual(result["action_count"], 3)
        self.assertEqual(result["state"]["scene_early_draws"], "0")

    def test_frame_work_mode_still_supplies_redraws(self):
        result = self.run_probe(cadence="uncapped", request_redraw=False)
        self.assertEqual(result["action_count"], 3)


if __name__ == "__main__":
    unittest.main()
