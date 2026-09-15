from __future__ import annotations

import csv
import json
from pathlib import Path
import tempfile
import unittest

from tools import perf_diagnostics as diagnostics
from tools import perf_workloads as workloads
from tools import run_render_perf_gate as gate


class DiagnosticReportTests(unittest.TestCase):
    def write_csv(self, path, rows):
        with path.open("w", newline="", encoding="utf-8") as stream:
            writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
            writer.writeheader()
            writer.writerows(rows)

    def test_ranks_exclusive_cost_and_keeps_sampled_cost_out_of_scores(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.write_csv(root / "profile_draw_scopes.csv", [
                dict(frame=1, path="draw", calls=1, inclusive_ms=30, exclusive_ms=2,
                     scope_heap_delta_kb=100, scope_heap_drop_calls=0, scope_imbalance=0),
                dict(frame=1, path="draw/text", calls=4, inclusive_ms=28, exclusive_ms=28,
                     scope_heap_delta_kb=80, scope_heap_drop_calls=0, scope_imbalance=0),
            ])
            self.write_csv(root / "stacks.csv", [
                dict(phase="measure", action="query", vmstate="C", stack="main\nsearch <file>", samples=3),
                dict(phase="setup", action="open", vmstate="I", stack="main\nopen", samples=2),
            ])
            report = diagnostics.build_profile(root)
            self.assertEqual(report["hotspots"][0]["path"], "draw/text")
            self.assertEqual(report["hotspots"][0]["exclusive_ms"], 28)
            self.assertEqual(report["captured_frames"], 1)
            self.assertNotIn("active_fps", report)
            speedscope = json.loads((root / "profile.speedscope.json").read_text())
            self.assertEqual(sum(speedscope["profiles"][0]["weights"]), 30)
            self.assertTrue(any("setup" in profile["name"] for profile in speedscope["profiles"]))
            html = (root / "profile.html").read_text()
            self.assertIn("search &lt;file&gt;", html)
            self.assertNotIn("search <file>", html)
            self.assertIn("Native call stacks are not captured", html)

    def test_reports_absolute_action_and_frame_flags_without_a_baseline(self):
        findings = diagnostics.red_flags({
            "metrics": {"frame_ms_p95": 45, "frame_ms_max": 120},
            "actions": {"query": {"latency_ms_p95": 300, "latency_ms_max": 400}},
        }, frame_budget_ms=16.67, action_budget_ms=100)
        self.assertTrue(any(item["metric"] == "frame_ms_p95" for item in findings))
        self.assertTrue(any(item.get("action") == "query" for item in findings))
        self.assertTrue(all(item["evidence"] == "measured" for item in findings))

    def test_keeps_setup_and_interactive_scope_costs_separate(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.write_csv(root / "profile_draw_scopes.csv", [
                dict(frame=1, phase="setup", action="open", path="draw", calls=1,
                     inclusive_ms=80, exclusive_ms=80),
                dict(frame=2, phase="measure", action="query", path="draw", calls=1,
                     inclusive_ms=5, exclusive_ms=5),
            ])
            profile = diagnostics.build_profile(root)
            self.assertEqual(len(profile["hotspots"]), 2)
            measured = next(row for row in profile["hotspots"] if row["phase"] == "measure")
            self.assertEqual(measured["exclusive_ms_per_captured_frame"], 5)

    def test_rejects_missing_or_invalid_action_evidence(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "actions.csv"
            with self.assertRaises((ValueError, FileNotFoundError)):
                diagnostics.read_actions(path, expected=1)
            self.write_csv(path, [dict(id=1, name="query", start_ms=0, dispatch_ms=1,
                                       ready_ms=2, latency_ms=-3, redraws=1, result="ok")])
            with self.assertRaises(ValueError):
                diagnostics.read_actions(path, expected=1)

    def test_aligns_actions_and_file_open_stages_with_lifecycle_time(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "result.txt").write_text("clock_origin_seconds=100\nmeasurement_origin_seconds=101\n")
            self.write_csv(root / "actions.csv", [dict(name="open", start_ms=50, dispatch_ms=2,
                                                       latency_ms=20, result="huge.lua", redraws=1)])
            self.write_csv(root / "profile_file_opens.csv", [dict(open_id=1, event="stage", time=101.08,
                duration_ms=30, depth=1, path="huge.lua", source="core.open_file", detail="load")])
            diagnostics.write_timeline(root)
            events = json.loads((root / "timeline.json").read_text())["traceEvents"]
            action = next(event for event in events if event["name"] == "open")
            self.assertAlmostEqual(action["ts"], 1050000)
            stage = next(event for event in events if event["name"] == "load")
            self.assertAlmostEqual(stage["ts"], 1050000)
            self.assertEqual(stage["dur"], 30000)

    def test_detects_slow_actions_even_when_frame_costs_do_not_change(self):
        before = dict(status="passed", active_fps=100, metrics={},
                      actions={"query": {"latency_ms_p95": 10}})
        after = dict(before, actions={"query": {"latency_ms_p95": 80}})
        findings = gate.compare_performance({"scenarios": {"search": after}},
                                            {"scenarios": {"search": before}})
        self.assertTrue(any(item["status"] == "regression" and "query" in item["metric"]
                            for item in findings))

    def test_a_failed_diagnostic_is_not_hidden_by_noisy_scores(self):
        report = dict(suite="stress", run_dir="private", passed=False, inconclusive=True,
                      scenarios={"search": dict(status="failed", failures=[dict(failure_kind="timeout")])})
        self.assertIn("Result: **FAIL**", gate.markdown_report(report))

    def test_repeated_runs_keep_the_worst_stall_in_the_report(self):
        result = gate.summarize_runs([
            dict(frame_ms_p50=4, frame_ms_max=8),
            dict(frame_ms_p50=6, frame_ms_max=200),
            dict(frame_ms_p50=8, frame_ms_max=9),
        ])
        self.assertEqual(result["frame_ms_p50"], 6)
        self.assertEqual(result["frame_ms_max"], 200)

    def test_reports_background_time_and_text_measurement_work(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "metrics.csv"
            self.write_csv(path, [dict(frame_ms=4, run_threads_ms=2, text_width_calls=10),
                                  dict(frame_ms=8, run_threads_ms=6, text_width_calls=30)])
            summary = gate.summarize_metrics(path)
            self.assertEqual(summary["run_threads_ms_avg"], 4)
            self.assertEqual(summary["text_width_calls_avg"], 20)


class WorkloadFixtureTests(unittest.TestCase):
    def test_diff_fixture_is_repeatable_with_real_changes_on_both_sides(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            settings = dict(kind="diff", lines=120, change_every=8)
            first = workloads.generate(root / "first", settings)
            second = workloads.generate(root / "second", settings)
            self.assertEqual(first, second)
            left = (root / "first" / "left.lua").read_text()
            right = (root / "first" / "right.lua").read_text()
            self.assertNotEqual(left, right)
            self.assertIn("removed_", left)
            self.assertIn("inserted_", right)
            self.assertIn("sha256", first["files"][0])


if __name__ == "__main__":
    unittest.main()
