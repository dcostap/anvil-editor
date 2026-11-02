"""Scoring of UI-thread blocking calls and the fake Everything server for Path Search scenarios."""
from __future__ import annotations

import csv
import dataclasses
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import fake_everything  # noqa: E402
import perf_diagnostics  # noqa: E402
import run_scenarios as scenarios  # noqa: E402


def calls(total: int, *callers: tuple[str, int, str]) -> dict:
    return {"total": total, "callers": [
        {"name": name, "calls": count, "at": stack.split(" < ")[0], "stack": stack}
        for name, count, stack in callers]}


def run(blocking: dict | None) -> dict:
    result = {"metrics": {"work_ms_p95": 1, "work_ms_max": 1}, "actions": {}}
    if blocking is not None:
        result["blocking_calls"] = blocking
    return result


class BlockingCallScoreTests(unittest.TestCase):
    def test_a_budgeted_scenario_fails_on_the_median_run_count(self):
        scenario = scenarios.SCENARIOS["fuzzy-files-navigate-filetree-large"]
        self.assertEqual(scenario.blocking_call_budget, 0)
        stack = "plugins/fuzzy_searcher/init.lua:10 < core/init.lua:20"
        noisy = run(calls(2, ("io.open", 2, stack)))
        result = scenarios.score(scenario, [run(calls(0)), noisy, run(calls(0))])
        self.assertEqual(result["findings"], [], "one noisy run must not fail alone")
        result = scenarios.score(scenario, [noisy, noisy, run(calls(0))])
        finding = result["findings"][0]
        self.assertEqual((finding["metric"], finding["value"], finding["budget"], finding["unit"]),
                         ("UI-thread blocking calls", 2, 0, "calls"))
        self.assertEqual(scenarios.finding_text(finding),
                         "UI-thread blocking calls 2.00 calls > 0.00 calls")

    def test_a_scenario_without_a_budget_reports_call_sites_of_every_run(self):
        scenario = dataclasses.replace(scenarios.SCENARIOS["fuzzy-files-navigate-filetree-large"],
                                       blocking_call_budget=None)
        read = ("system.get_file_info", 1, "core/a.lua:1")
        write = ("file.write", 5, "core/session_log.lua:9 < core/init.lua:2")
        result = scenarios.score(scenario, [run(calls(6, read, write)), run(calls(1, read))])
        self.assertEqual(result["findings"], [])
        blocking = result["blocking_calls"]
        self.assertEqual(blocking["total"], 3.5)
        self.assertIsNone(blocking["budget"])
        self.assertEqual([(site["name"], site["calls"], site["runs"]) for site in blocking["callers"]],
                         [("file.write", 5, 1), ("system.get_file_info", 2, 2)])
        report = scenarios.markdown({"run_id": "r", "renderer": "software", "runs": 2, "slow_io_ms": 50,
                                     "scenarios": {"s": dict(result, verdict="passed", scene="x",
                                                             cadence="uncapped", frame_budget_ms=4,
                                                             frame_spike_ms=16.7)}})
        self.assertIn("Each UI-thread file call waited 50 ms first.", report)
        self.assertIn("UI-thread blocking calls in the measured frames: 3.5 in the median run (report only).",
                      report)
        self.assertIn("| file.write | 5 | 1 | core/session_log.lua:9 < core/init.lua:2 |", report)

    def test_a_run_without_a_recording_reports_no_count(self):
        result = scenarios.score(scenarios.SCENARIOS["fuzzy-files-navigate-filetree-large"], [run(None)])
        self.assertIsNone(result["blocking_calls"])
        self.assertEqual(result["findings"], [])


class BlockingCallFileTests(unittest.TestCase):
    def test_reads_call_sites_and_per_action_counts(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.assertIsNone(perf_diagnostics.read_blocking_calls(root / "missing.csv"))
            path = root / "blocking-calls.csv"
            with path.open("w", newline="", encoding="utf-8") as stream:
                writer = csv.writer(stream)
                writer.writerow(["name", "calls", "at", "stack"])
                writer.writerow(["io.open", "3", "core/a.lua:1", "core/a.lua:1 < core/b.lua:2"])
                writer.writerow(["file.read", "2", "core/a.lua:3", "core/a.lua:3"])
            self.assertEqual(perf_diagnostics.read_blocking_calls(path)["total"], 5)

            actions = root / "actions.csv"
            fields = ["id", "name", "start_ms", "dispatch_ms", "ready_ms", "latency_ms", "visible_ms",
                      "redraws", "result", "blocking_calls"]
            for value, valid in (("4", True), ("", True), ("-1", False)):
                with self.subTest(value=value):
                    with actions.open("w", newline="", encoding="utf-8") as stream:
                        writer = csv.writer(stream)
                        writer.writerow(fields)
                        writer.writerow([1, "next", 0, 1, 2, 3, "", 1, "ok", value])
                    if not valid:
                        with self.assertRaises(ValueError):
                            perf_diagnostics.read_actions(actions, 1)
                        continue
                    summary = perf_diagnostics.read_actions(actions, 1)["summary"]["next"]
                    if value:
                        self.assertEqual(summary["blocking_calls_max"], 4)
                    else:
                        self.assertNotIn("blocking_calls_max", summary)

    def test_scenario_runs_record_calls_and_serve_everything_for_path_search(self):
        captured = {}

        def fake_run_case(**kwargs):
            captured.update(kwargs["extra_environment"])
            port = kwargs["extra_environment"]["EVERYTHING_PORT"]
            with urlopen(f"http://127.0.0.1:{port}/?json=1&search=file:%20main&count=5") as response:
                captured["answer"] = json.load(response)
            return {"run_dir": str(kwargs["run_dir"])}

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "src").mkdir()
            (root / "src" / "main.lua").write_text("x")
            scenario = scenarios.SCENARIOS["fuzzy-paths-navigate-filetree-large"]
            with patch.object(scenarios.gate, "run_case", side_effect=fake_run_case), \
                 patch.object(scenarios, "scenario_targets", return_value=[]):
                scenarios.run_one("fuzzy-paths-navigate-filetree-large", scenario, exe=root / "anvil.exe",
                                  work=root, root=root, run_dir=root / "run-1", renderer="software",
                                  mode="metrics", details=False, slow_io_ms=50)
        self.assertTrue(captured["ANVIL_PERF_BENCHMARK_BLOCKING_CALLS"].endswith("blocking-calls.csv"))
        self.assertEqual(captured["ANVIL_PERF_BENCHMARK_SLOW_IO_MS"], "50")
        self.assertEqual(captured["EVERYTHING_HOST"], "127.0.0.1")
        self.assertEqual([item["name"] for item in captured["answer"]["results"]], ["main.lua"])


class FakeEverythingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for path in ("Render/render_1.lua", "Render/notes.md", "src/render_2.lua", "src/main.lua",
                     ".git/render_ignored"):
            (self.root / path).parent.mkdir(parents=True, exist_ok=True)
            (self.root / path).write_text("text")
        self.items = fake_everything.scan(self.root)

    def names(self, **params):
        answer = fake_everything.search(self.items, {key: str(value) for key, value in params.items()})
        return answer["totalResults"], [item["name"] for item in answer["results"]]

    def test_answers_the_queries_that_path_search_sends(self):
        self.assertEqual(self.names(search="file: render"),
                         (3, ["notes.md", "render_1.lua", "render_2.lua"]))
        self.assertEqual(self.names(search="folder: render"), (1, ["Render"]))
        self.assertEqual(self.names(search="file: Render", case=1), (2, ["notes.md", "render_1.lua"]))
        scope = self.root / "src"
        self.assertEqual(self.names(search=f'ancestor:"{scope}" file: lua'), (2, ["main.lua", "render_2.lua"]))
        self.assertEqual(self.names(search="file: render", count=1, offset=1), (3, ["render_1.lua"]))

    def test_describes_items_as_everything_does(self):
        item = fake_everything.search(self.items, {"search": "file: main"})["results"][0]
        self.assertEqual(item["type"], "file")
        self.assertEqual(Path(item["path"]), self.root / "src")
        self.assertEqual(item["size"], "4")
        self.assertGreater(int(item["date_modified"]), 116444736000000000)


if __name__ == "__main__":
    unittest.main()
