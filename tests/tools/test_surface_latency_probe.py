"""Check the public runner result at the external launcher boundary."""
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))
import run_surface_latency_probe as probe


class LatencyAcceptance(unittest.TestCase):
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
                 patch.object(sys, "argv", ["probe", "--no-build", "--mode", "shell", "--renderer", "d3d11", "--runs", "1"]):
                self.assertEqual(probe.main(), 1, "23/120 inputs passed the public CLI")


if __name__ == "__main__":
    unittest.main()
