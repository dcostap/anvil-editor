"""Check the public runner result at the external launcher boundary."""
import json
import contextlib
import io
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))
import run_surface_latency_probe as probe


class LatencyAcceptance(unittest.TestCase):
    def test_saved_reference_uses_its_matching_runtime_data(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            exe = root / "app/bin/anvil.exe"
            exe.parent.mkdir(parents=True)
            exe.write_bytes(b"candidate")
            reference = root / "reference.exe"
            reference.write_bytes(b"reference")
            data = root / "reference-data"
            (data / "core").mkdir(parents=True)
            (data / "core/sidebar_app.lua").write_text("reference frontend")

            def launch(config_path, timeout):
                self.assertEqual(exe.read_bytes(), b"reference")
                self.assertEqual((exe.parent.parent / "share/anvil/core/sidebar_app.lua").read_text(), "reference frontend")
                config = json.loads(config_path.read_text())
                Path(config["environment"]["ANVIL_INPUT_LATENCY_FILE"]).write_text(
                    "done=1\nrequested=120\ncompleted=120\nsamples_ms=" + ",".join(["7"] * 120))
                return {"exit_code": 0, "timed_out": False}

            with patch.object(probe, "copy_app_tree", return_value=exe), \
                 patch.object(probe, "invoke_hidden", side_effect=launch), \
                 patch.object(probe, "read_console_state", return_value={"locked": False, "display_state": "on"}), \
                 patch.object(sys, "argv", ["probe", "--no-build", "--reference-exe", str(reference),
                     "--reference-data", str(data), "--mode", "shell", "--renderer", "d3d11", "--runs", "1"]):
                self.assertEqual(probe.main(), 0)

    def test_partial_successful_process_fails_the_case(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            exe = root / "anvil.exe"

            def launch(config_path, timeout):
                config = json.loads(config_path.read_text())
                Path(config["environment"]["ANVIL_INPUT_LATENCY_FILE"]).write_text(
                    "done=1\nrequested=120\ncompleted=23\nsamples_ms=" + ",".join(["1"] * 23))
                return {"exit_code": 0, "timed_out": False}

            with patch.object(probe, "copy_app_tree", return_value=exe), \
                 patch.object(probe, "invoke_hidden", side_effect=launch), \
                 patch.object(probe, "read_console_state", return_value={"locked": False, "display_state": "on"}), \
                 patch.object(sys, "argv", ["probe", "--no-build", "--mode", "shell", "--renderer", "d3d11", "--runs", "1"]):
                self.assertEqual(probe.main(), 1, "23/120 inputs passed the public CLI")

    def run_complete_case(self, before, after):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = root / "result.json"

            def launch(config_path, timeout):
                config = json.loads(config_path.read_text())
                Path(config["environment"]["ANVIL_INPUT_LATENCY_FILE"]).write_text(
                    "done=1\nrequested=120\ncompleted=120\nsamples_ms=" + ",".join(["7"] * 120))
                return {"exit_code": 0, "timed_out": False}

            output = io.StringIO()
            with patch.object(probe, "copy_app_tree", return_value=root / "anvil.exe"), \
                 patch.object(probe, "invoke_hidden", side_effect=launch), \
                 patch.object(probe, "read_console_state", side_effect=[before, after]), \
                 patch.object(sys, "argv", ["probe", "--no-build", "--mode", "shell", "--renderer", "d3d11", "--runs", "1", "--json", str(result)]), \
                 contextlib.redirect_stdout(output):
                status = probe.main()
            return status, json.loads(result.read_text()), output.getvalue()

    def test_locked_or_display_off_boundaries_do_not_enter_baseline(self):
        normal = {"locked": False, "display_state": "on"}
        for bad in ({"locked": True, "display_state": "on"},
                    {"locked": False, "display_state": "off"}):
            for before, after in ((bad, normal), (normal, bad)):
                with self.subTest(before=before, after=after):
                    status, result, output = self.run_complete_case(before, after)
                    self.assertEqual(status, 2, "Invalid environment passed the public CLI")
                    case = result["cases"][0]
                    self.assertTrue(case["ok"], "Environment state changed native completion status")
                    self.assertTrue(case["environment_invalid"])
                    self.assertFalse(case["baseline_eligible"])
                    self.assertEqual(case["console_before"], before)
                    self.assertEqual(case["console_after"], after)
                    self.assertEqual(case["samples_ms"], [7.0] * 120, "Invalid samples were discarded")
                    summary = result["summary"]["shell-d3d11"]
                    self.assertEqual(summary["samples"], 0)
                    self.assertEqual(summary["eligible_runs"], 0)
                    self.assertEqual(summary["environment_invalid_runs"], 1)
                    self.assertIn("environment-invalid", output)

    def test_unlocked_display_on_case_enters_baseline(self):
        normal = {"locked": False, "display_state": "on"}
        status, result, _ = self.run_complete_case(normal, normal)
        self.assertEqual(status, 0)
        self.assertTrue(result["cases"][0]["baseline_eligible"])
        self.assertEqual(result["summary"]["shell-d3d11"]["samples"], 120)

    def test_unknown_console_state_cannot_establish_baseline(self):
        status, result, _ = self.run_complete_case(
            {"locked": None, "display_state": "unavailable"}, {"locked": False, "display_state": "on"})
        self.assertEqual(status, 2)
        self.assertTrue(result["cases"][0]["environment_invalid"])
        self.assertEqual(result["summary"]["shell-d3d11"]["samples"], 0)


if __name__ == "__main__":
    unittest.main()
