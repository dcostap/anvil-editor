"""Keep benchmark diagnostics from exhausting the machine."""
import io
import json
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import run_scenarios as scenarios
import run_render_perf_gate as gate


class ScenarioSafetyTests(unittest.TestCase):
    def test_over_budget_run_keeps_timers_without_starting_allocation_runs(self):
        args = SimpleNamespace(project=Path("project"), fixture_cache=Path("cache"),
                               runs=1, renderer="software", attribute=False,
                               allocation=False, heap=False, diagnose=False)
        run = {"metrics": {"work_ms_p95": 100, "work_ms_max": 200, "frames": 10},
               "run_dir": "run", "actions": {}}
        with patch.object(scenarios, "scenario_root", return_value=args.project), \
             patch.object(scenarios, "run_one", return_value=run) as launch, \
             patch.object(scenarios, "read_details", return_value=[]):
            result = scenarios.run_scenario("markdown-gallery-open",
                scenarios.SCENARIOS["markdown-gallery-open"], args,
                Path("anvil.exe"), Path("work"), lambda message: None)
        self.assertEqual(result["verdict"], "over budget")
        self.assertEqual([call.kwargs["run_dir"].name for call in launch.call_args_list],
                         ["run-1", "attribution"])
        self.assertNotIn("allocation", result)

    def test_allocation_option_fails_before_build_or_launch(self):
        with patch.object(sys, "argv", ["scenarios", "--allocation"]), \
             patch.object(gate, "build_anvil", side_effect=AssertionError("unsafe option reached build")) as build, \
             patch.object(gate, "copy_app_tree") as copy:
            error = io.StringIO()
            with redirect_stderr(error), self.assertRaises(SystemExit) as caught:
                scenarios.main()
        self.assertEqual(caught.exception.code, 2)
        self.assertIn("disabled", error.getvalue())
        build.assert_not_called()
        copy.assert_not_called()


@unittest.skipUnless(sys.platform == "win32", "requires Windows Job Objects")
class BenchmarkMemoryTests(unittest.TestCase):
    def test_normal_launch_has_a_default_limit(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            config = root / "launch.json"
            config.write_text(json.dumps({
                "exe": sys.executable, "arguments": ["-c", "pass"],
                "working_directory": str(root), "environment": {},
            }), encoding="utf-8")
            completed = subprocess.run([
                "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
                "-File", str(ROOT / "tools/run_anvil_hidden_desktop.ps1"),
                "-Config", str(config), "-TimeoutSeconds", "8",
            ], capture_output=True, text=True, timeout=20)
            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            result = gate.parse_launcher_output(completed.stdout)
            self.assertGreater(result["memory_limit_bytes"], 0)
            self.assertGreater(result["peak_job_memory_bytes"], 0)
            self.assertEqual(result["termination_reason"], "")

    def test_unsafe_launch_files_are_rejected_before_the_program_runs(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            config = root / "launch.json"
            for override, message in [
                ({"memory_limit_mb": 0}, "cannot be disabled"),
                ({"memory_limit_mb": -1}, "cannot be disabled"),
                ({"environment": {"ANVIL_PERF_BENCHMARK_ALLOCATION": "old.csv"}}, "profiling is disabled"),
                ({"environment": {"ANVIL_PERF_BENCHMARK_ALLOCATION_SITES": "old.csv"}}, "profiling is disabled"),
            ]:
                with self.subTest(override=override):
                    config.write_text(json.dumps({
                        "exe": sys.executable,
                        "arguments": ["-c", "from pathlib import Path; Path('started').touch()"],
                        "working_directory": str(root), "environment": {}, **override,
                    }), encoding="utf-8")
                    completed = subprocess.run([
                        "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
                        "-File", str(ROOT / "tools/run_anvil_hidden_desktop.ps1"),
                        "-Config", str(config), "-TimeoutSeconds", "8",
                    ], capture_output=True, text=True, timeout=20)
                    self.assertNotEqual(completed.returncode, 0)
                    self.assertIn(message, completed.stderr)
                    self.assertFalse((root / "started").exists())

    def test_memory_limit_covers_children_and_terminates_the_tree(self):
        # Even the old runner can allocate at most 128 MiB in this reproduction.
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            script = root / "allocate.py"
            script.write_text('''
import json, os, subprocess, sys, time
from pathlib import Path
if len(sys.argv) > 1:
    blocks = []
    try:
        for i in range(8):
            blocks.append(bytearray(8 * 1024 * 1024))
            time.sleep(0.05)
    except MemoryError:
        pass
    time.sleep(30)
else:
    children = [subprocess.Popen([sys.executable, __file__, "child"]) for _ in range(2)]
    Path("pids.json").write_text(json.dumps([os.getpid()] + [p.pid for p in children]))
    time.sleep(30)
''', encoding="utf-8")
            config = root / "launch.json"
            config.write_text(json.dumps({
                "exe": sys.executable, "arguments": [str(script)],
                "working_directory": str(root), "environment": {},
                "memory_limit_mb": 96,
            }), encoding="utf-8")
            completed = subprocess.run([
                "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
                "-File", str(ROOT / "tools/run_anvil_hidden_desktop.ps1"),
                "-Config", str(config), "-TimeoutSeconds", "8",
            ], capture_output=True, text=True, timeout=25)
            result = gate.parse_launcher_output(completed.stdout)
            self.assertEqual(result["termination_reason"], "memory_limit", completed.stdout + completed.stderr)
            self.assertFalse(result["timed_out"])
            self.assertNotEqual(completed.returncode, 0)
            self.assertTrue(result["process_tree_terminated"])
            self.assertEqual(result["memory_limit_bytes"], 96 * 1024 * 1024)
            # Windows' peak counter can include the allocation that it refused.
            self.assertLess(result["peak_job_memory_bytes"], 128 * 1024 * 1024)
            pids = json.loads((root / "pids.json").read_text())
            probe = subprocess.run([
                "powershell.exe", "-NoProfile", "-Command",
                "@(Get-Process -Id " + ",".join(map(str, pids)) +
                " -ErrorAction SilentlyContinue).Count",
            ], capture_output=True, text=True, timeout=10)
            self.assertEqual(probe.stdout.strip(), "0", probe.stdout + probe.stderr)


if __name__ == "__main__":
    unittest.main()
