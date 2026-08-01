from __future__ import annotations

import csv
import importlib.util
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
ANALYZER_PATH = ROOT / "tools" / "analyze_idle_perf.py"


def load_analyzer():
    spec = importlib.util.spec_from_file_location("analyze_idle_perf", ANALYZER_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader
    spec.loader.exec_module(module)
    return module


analyzer = load_analyzer()


FIELDS = [
    "time", "did_redraw", "window_has_focus", "pending_events", "total_ms",
    "sleep_actual_ms", "core_step_ms", "update_ms", "core_root_panel_update_ms",
    "rootpanel_update_ms",
]


def write_capture(path: Path, rows: list[dict[str, object]]) -> None:
    with path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=FIELDS)
        writer.writeheader()
        for row in rows:
            writer.writerow({field: row.get(field, 0) for field in FIELDS})


class IdlePerformanceSummaryTests(unittest.TestCase):
    def test_passes_a_focused_quiescent_capture(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "frames.csv"
            rows = []
            for index in range(31):
                rows.append({
                    "time": index / 10,
                    "window_has_focus": 1,
                    "total_ms": 100,
                    "sleep_actual_ms": 96,
                })
            rows[0]["did_redraw"] = 1
            rows[0]["core_step_ms"] = 4
            rows[0]["core_root_panel_update_ms"] = 1
            write_capture(path, rows)

            summary = analyzer.summarize_idle_frames(path)
            failures = analyzer.evaluate_idle_summary(summary)

            self.assertEqual(failures, [])
            self.assertLess(summary["iterations_per_second"], 120)
            self.assertEqual(summary["idle_ui_update_iterations"], 0)

    def test_rejects_the_busy_idle_pattern_from_the_regression(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "frames.csv"
            rows = []
            for index in range(451):
                rows.append({
                    "time": index / 450,
                    "window_has_focus": 1,
                    "total_ms": 1000 / 450,
                    "sleep_actual_ms": 0.9,
                    "core_step_ms": 1.0,
                    "core_root_panel_update_ms": 0.95,
                })
            write_capture(path, rows)

            summary = analyzer.summarize_idle_frames(path)
            failures = analyzer.evaluate_idle_summary(summary)

            self.assertTrue(any("iterations_per_second" in failure for failure in failures))
            self.assertTrue(any("idle_ui_update_fraction" in failure for failure in failures))
            self.assertTrue(any("awake_fraction" in failure for failure in failures))

    def test_rejects_an_unfocused_capture_as_invalid_evidence(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "frames.csv"
            write_capture(path, [
                {"time": 0, "total_ms": 100, "sleep_actual_ms": 100},
                {"time": 1, "total_ms": 100, "sleep_actual_ms": 100},
            ])

            summary = analyzer.summarize_idle_frames(path)
            failures = analyzer.evaluate_idle_summary(summary)

            self.assertTrue(any("focused_fraction" in failure for failure in failures))


if __name__ == "__main__":
    unittest.main()
