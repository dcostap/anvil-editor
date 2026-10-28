"""Check the build job limit at the Meson process boundary."""

from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class BuildJobsTests(unittest.TestCase):
    def compile(self, jobs=None, status=0):
        env = os.environ.copy()
        env.pop("ANVIL_BUILD_JOBS", None)
        if jobs is not None:
            env["ANVIL_BUILD_JOBS"] = jobs
        env["FAKE_MESON_STATUS"] = str(status)
        bash = shutil.which("bash")
        self.assertIsNotNone(bash, "Bash is required for build script tests")
        with tempfile.TemporaryDirectory(prefix="anvil-build-jobs-") as temporary:
            meson = Path(temporary) / "meson"
            meson.write_text('#!/bin/bash\nprintf "%s\\n" "$@"\nexit "$FAKE_MESON_STATUS"\n')
            meson.chmod(0o755)
            return subprocess.run(
                [bash, "-c", 'export PATH="$(cd "$1" && pwd):$PATH"; shift; bash "$@"',
                 "build-test", Path(temporary).as_posix(),
                 (ROOT / "scripts/compile.sh").as_posix(),
                 "-C", "build with spaces", "sample-target"],
                env=env, text=True, capture_output=True, timeout=30,
            )

    def test_default_build_has_a_finite_job_limit(self):
        result = self.compile()
        self.assertEqual(result.returncode, 0, result.stderr)
        args = result.stdout.splitlines()
        self.assertIn("-j", args)
        self.assertGreater(int(args[args.index("-j") + 1]), 0)

    def test_override_and_build_arguments_reach_meson(self):
        result = self.compile(jobs="3")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [
            "compile", "-j", "3", "-C", "build with spaces", "sample-target",
        ])

    def test_invalid_limits_stop_before_meson(self):
        for jobs in ("0", "-1", "many", "2 3"):
            with self.subTest(jobs=jobs):
                result = self.compile(jobs=jobs)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertIn("ANVIL_BUILD_JOBS", result.stderr)

    def test_compile_failure_reaches_the_caller(self):
        self.assertEqual(self.compile(status=7).returncode, 7)


if __name__ == "__main__":
    unittest.main()
