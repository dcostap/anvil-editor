"""Check fixture isolation and the performance verdict through public runner seams."""
import csv
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))
import perf_fixtures as fixtures
import run_render_perf_gate as gate
import run_scenarios as scenarios


class CompletionScenarioTests(unittest.TestCase):
    def test_cached_library_keeps_its_sources_and_restores_the_edited_file(self):
        with tempfile.TemporaryDirectory() as temp:
            spec = fixtures.CompletionSpec("completion-test", files=2, symbols_per_file=3)
            root = fixtures.materialize(spec, Path(temp))
            main = root / "main.odin"
            original = main.read_bytes()
            library = {path.name: path.read_bytes() for path in (root / "library").glob("*.odin")}
            declarations = [line for data in library.values() for line in data.decode().splitlines()
                            if ":: proc" in line]
            self.assertEqual(len(declarations), 8)
            self.assertEqual(len(set(declarations)), 8)
            main.write_text("autosaved edit", encoding="utf-8")
            self.assertEqual(fixtures.materialize(spec, Path(temp)), root)
            self.assertEqual(main.read_bytes(), original)
            self.assertEqual({path.name: path.read_bytes() for path in (root / "library").glob("*.odin")},
                             library)

    def test_fast_drawing_cannot_hide_a_slow_input_burst(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "metrics.csv"
            with path.open("w", newline="", encoding="utf-8") as stream:
                writer = csv.DictWriter(stream, fieldnames=["frame_ms", "total_ms", "sleep_actual_ms", "action_ms"])
                writer.writeheader()
                writer.writerow(dict(frame_ms=3, total_ms=6, sleep_actual_ms=2, action_ms=1700))
            verdict = scenarios.score(scenarios.SCENARIOS["autocomplete-project-burst"],
                                      [{"metrics": gate.summarize_metrics(path)}])
            self.assertTrue(any(finding["metric"] == "frame work_ms max" and finding["value"] == 1704
                                for finding in verdict["findings"]))


class ScenarioScoringTests(unittest.TestCase):
    def run_with_stall(self, frame=2, action=2):
        return {"metrics": {"work_ms_p95": 2, "work_ms_max": frame}, "actions": {
            "navigate": {"latency_ms_p50": 2, "latency_ms_p95": 2,
                         "latency_ms_max": action, "redraws_p50": 1}}}

    def test_one_slow_frame_cannot_disappear_between_fast_runs(self):
        result = scenarios.score(scenarios.SCENARIOS["markdown-gallery-caret"], [
            self.run_with_stall(), self.run_with_stall(frame=36), self.run_with_stall()])
        self.assertEqual(result["frame"]["work_ms_p95"], 2)
        self.assertTrue(any(item["metric"] == "frame work_ms max" and item["value"] == 36
                            for item in result["findings"]))

    def test_one_slow_response_cannot_hide_below_the_action_percentile(self):
        result = scenarios.score(scenarios.SCENARIOS["autocomplete-navigation-latency"], [
            self.run_with_stall(), self.run_with_stall(action=120), self.run_with_stall()])
        self.assertIsNone(result["frame"], "response mode must still exclude presentation waits")
        self.assertEqual(result["actions"]["navigate"]["latency_ms_p95"], 2)
        self.assertTrue(any(item["metric"] == "navigate latency max" and item["value"] == 120
                            for item in result["findings"]))


if __name__ == "__main__":
    unittest.main()
