from __future__ import annotations

import csv
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
GATE_PATH = ROOT / "tools" / "run_render_perf_gate.py"
LAUNCHER_PATH = ROOT / "tools" / "run_anvil_hidden_desktop.ps1"


def load_gate():
    spec = importlib.util.spec_from_file_location("run_render_perf_gate", GATE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader
    spec.loader.exec_module(module)
    return module


gate = load_gate()


class MetricsSummaryTests(unittest.TestCase):
    def test_reports_stutter_budgets_consecutive_misses_and_progression(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "metrics.csv"
            completions = [5, 15, 35, 75, 195, 205, 215, 225]
            frame_times = [120, 40, 20, 10, 10, 10, 10, 10]
            with path.open("w", newline="", encoding="utf-8") as stream:
                writer = csv.DictWriter(stream, fieldnames=["completion_ms", "frame_ms"])
                writer.writeheader()
                for completion, frame_ms in zip(completions, frame_times):
                    writer.writerow({"completion_ms": completion, "frame_ms": frame_ms})

            summary = gate.summarize_metrics(path)

            self.assertEqual(summary["interval_over_16_67_count"], 3)
            self.assertEqual(summary["interval_over_33_33_count"], 2)
            self.assertEqual(summary["interval_over_100_count"], 1)
            self.assertEqual(summary["interval_longest_over_16_67_run"], 3)
            self.assertEqual(summary["frame_ms_max"], 120)
            self.assertGreater(summary["frame_ms_first_quarter_avg"], 0)
            self.assertLess(summary["frame_ms_last_quarter_avg"], summary["frame_ms_first_quarter_avg"])
            self.assertLess(summary["frame_ms_progression_slope"], 0)

    def test_zero_baseline_stutter_budget_can_regress(self):
        current = {"scenarios": {"case": {
            "status": "passed",
            "active_fps": 60,
            "active_fps_runs": [60, 60, 60],
            "metrics": {},
            "paced": {
                "active_fps": 60,
                "metrics": {
                    "interval_ms_p95": 16.7,
                    "interval_ms_max": 40,
                    "interval_over_33_33_fraction": 0.02,
                },
            },
        }}}
        baseline = {"scenarios": {"case": {
            "active_fps": 60,
            "active_fps_runs": [60, 60, 60],
            "metrics": {},
            "paced": {
                "active_fps": 60,
                "metrics": {
                    "interval_ms_p95": 16.7,
                    "interval_ms_max": 16.7,
                    "interval_over_33_33_fraction": 0,
                },
            },
        }}}

        findings = gate.compare_performance(current, baseline)
        stutter = next(
            item for item in findings
            if item["metric"] == "paced_interval_over_33_33_fraction"
        )
        self.assertEqual(stutter["status"], "regression")


class StateValidationTests(unittest.TestCase):
    def test_states_consistent_requires_exact_observable_state(self):
        state = {
            "doc_lines": 2,
            "wrapped_rows": 701,
            "text_revision": 2,
            "selection_line": 1,
            "selection_col": 8735,
            "scroll_x": 0.0,
            "scroll_y": 1729.1378133333,
        }

        self.assertTrue(gate.states_consistent([state, dict(state)]))

        mismatches = {
            "scroll_y": 1717.336,
            "selection_col": 8734,
            "doc_lines": 3,
            "wrapped_rows": 700,
        }
        for field, value in mismatches.items():
            with self.subTest(field=field):
                changed = dict(state)
                changed[field] = value
                self.assertFalse(gate.states_consistent([state, changed]))


class SpecimenTests(unittest.TestCase):
    def test_external_specimen_is_copied_and_described_without_source_path(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "private name.md"
            source.write_bytes(("short\n" + "é" * 100 + "\n").encode("utf-8"))

            copied, metadata = gate.copy_external_specimen(source, root / "isolated")

            self.assertNotEqual(copied, source)
            self.assertEqual(copied.read_bytes(), source.read_bytes())
            self.assertEqual(copied.name, "specimen.md")
            self.assertEqual(metadata["bytes"], len(source.read_bytes()))
            self.assertEqual(metadata["lines"], 2)
            self.assertEqual(metadata["max_line_bytes"], 200)
            self.assertEqual(metadata["sha256"], gate.sha256(source))
            self.assertNotIn(str(source), json.dumps(metadata))


class LauncherOutputTests(unittest.TestCase):
    def test_parses_structured_launcher_result_after_diagnostic_output(self):
        output = "diagnostic line\n" + json.dumps({
            "pid": 123,
            "exit_code": 124,
            "timed_out": True,
            "termination_reason": "heartbeat_stall",
            "last_phase": "setup",
        })
        result = gate.parse_launcher_output(output)
        self.assertEqual(result["pid"], 123)
        self.assertEqual(result["termination_reason"], "heartbeat_stall")

    def test_timeout_is_a_categorical_case_failure(self):
        failure = gate.classify_case_failure({
            "exit_code": 124,
            "timed_out": True,
            "termination_reason": "wall_timeout",
            "last_phase": "measure",
        }, {"phase": "measure"})
        self.assertEqual(failure["status"], "timeout")
        self.assertEqual(failure["failure_kind"], "wall_timeout")
        self.assertEqual(failure["last_phase"], "measure")
        self.assertEqual(failure["performance_penalty"], "infinite")

    def test_lifecycle_and_resource_progression_are_summarized(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            lifecycle = root / "lifecycle.csv"
            lifecycle.write_text(
                "milestone,elapsed_ms\nplugin_loaded,0.0\nfixture_opened,25.5\n"
                "scenario_ready,80.0\nfirst_ready_frame,90.0\n",
                encoding="utf-8",
            )
            resources = root / "resources.csv"
            resources.write_text(
                "elapsed_ms,working_set_bytes,private_bytes,phase\n"
                "0,100,200,setup\n250,150,260,warmup\n500,140,300,measure\n",
                encoding="utf-8",
            )

            milestones = gate.read_lifecycle(lifecycle)
            summary = gate.summarize_resource_samples(resources)

            self.assertEqual(milestones["fixture_opened_ms"], 25.5)
            self.assertEqual(milestones["first_ready_frame_ms"], 90.0)
            self.assertEqual(summary["working_set_peak_bytes"], 150)
            self.assertEqual(summary["private_bytes_growth"], 100)
            self.assertEqual(summary["private_bytes_progression_slope"], 50)


@unittest.skipUnless(sys.platform == "win32", "hidden desktop launcher is Windows-only")
class HiddenDesktopIntegrationTests(unittest.TestCase):
    def test_timeout_terminates_spawned_descendants(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            child_pid_path = root / "child.pid"
            heartbeat_path = root / "heartbeat.txt"
            dump_path = root / "timeout.dmp"
            script_path = root / "parent.ps1"
            escaped_child_pid_path = str(child_pid_path).replace("'", "''")
            script_path.write_text(
                "$child = Start-Process powershell.exe -ArgumentList @("
                "'-NoProfile','-Command','Start-Sleep -Seconds 60') -PassThru\n"
                f"Set-Content -LiteralPath '{escaped_child_pid_path}' -Value $child.Id\n"
                "Start-Sleep -Seconds 60\n",
                encoding="utf-8",
            )
            config_path = root / "launch.json"
            config_path.write_text(json.dumps({
                "exe": str(Path("C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe")),
                "working_directory": str(root),
                "arguments": ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(script_path)],
                "environment": {},
                "heartbeat_path": str(heartbeat_path),
                "startup_timeout_seconds": 10,
                "heartbeat_timeout_seconds": 10,
                "timeout_dump_path": str(dump_path),
            }), encoding="utf-8")

            completed = subprocess.run([
                "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
                "-File", str(LAUNCHER_PATH), "-Config", str(config_path),
                "-TimeoutSeconds", "2",
            ], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20)

            self.assertEqual(completed.returncode, 124, completed.stdout)
            launcher_result = gate.parse_launcher_output(completed.stdout)
            self.assertTrue(launcher_result["dump_written"], completed.stdout)
            self.assertTrue(dump_path.exists(), completed.stdout)
            self.assertGreater(dump_path.stat().st_size, 0)
            deadline = time.time() + 5
            while not child_pid_path.exists() and time.time() < deadline:
                time.sleep(0.05)
            self.assertTrue(child_pid_path.exists(), completed.stdout)
            child_pid = int(child_pid_path.read_text(encoding="utf-8").strip())
            try:
                probe = subprocess.run(
                    ["powershell.exe", "-NoProfile", "-Command", f"Get-Process -Id {child_pid} -ErrorAction SilentlyContinue"],
                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5,
                )
                self.assertNotEqual(probe.returncode, 0, f"descendant {child_pid} survived timeout")
            finally:
                subprocess.run(
                    ["taskkill.exe", "/PID", str(child_pid), "/T", "/F"],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                )


if __name__ == "__main__":
    unittest.main()
