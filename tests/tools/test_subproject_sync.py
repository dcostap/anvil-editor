"""Check dependency refresh through real, local Meson builds."""

from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class SubprojectSyncTests(unittest.TestCase):
    def run_command(self, *args, cwd=None):
        result = subprocess.run([str(arg) for arg in args], cwd=cwd or self.app,
                                text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=90)
        self.assertEqual(result.returncode, 0, result.stdout)
        return result.stdout

    def meson(self, *args):
        return self.run_command(sys.executable, "-m", "mesonbuild.mesonmain", *args)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="anvil-wrap-test-")
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.upstream = root / "upstream"
        self.app = root / "app"
        self.upstream.mkdir()
        self.app.mkdir()
        self.run_command("git", "init", cwd=self.upstream)
        self.run_command("git", "config", "user.name", "Test", cwd=self.upstream)
        self.run_command("git", "config", "user.email", "test@example.invalid", cwd=self.upstream)
        (self.upstream / "value.c").write_text("int value(void) { return 1; }\n")
        (self.upstream / "notes.txt").write_text("upstream\n")
        (self.upstream / ".gitignore").write_text("cache/\n")
        self.run_command("git", "add", ".", cwd=self.upstream)
        self.run_command("git", "commit", "-m", "Initial source", cwd=self.upstream)
        self.revision = self.run_command("git", "rev-parse", "HEAD", cwd=self.upstream).strip()
        scripts = self.app / "scripts"
        scripts.mkdir()
        shutil.copy(ROOT / "scripts/sync-git-subprojects.py", scripts)
        shutil.copytree(ROOT / "scripts/sync-subprojects", scripts / "sync-subprojects")
        self.packages = self.app / "subprojects/packagefiles"
        overlay = self.packages / "sample"
        overlay.mkdir(parents=True)
        self.overlay = overlay / "meson.build"
        self.overlay.write_text("project('sample', 'c')\n"
                                "lib = static_library('sample', 'value.c')\n"
                                "sample_dep = declare_dependency(link_with: lib)\n")
        (self.app / "meson.build").write_text(
            "project('sync-test', 'c')\n"
            "subdir('scripts/sync-subprojects')\n"
            "dep = subproject('sample').get_variable('sample_dep')\n"
            "executable('answer', 'main.c', dependencies: dep)\n")
        (self.app / "main.c").write_text(
            '#include <stdio.h>\nint value(void);\n'
            'int main(void) { printf("%d\\n", value()); return 0; }\n')
        self.wrap = self.app / "subprojects/sample.wrap"
        self.write_wrap()
        self.meson("setup", "build")
        self.meson("compile", "-C", "build")
        self.checkout = self.app / "subprojects/sample"

    def write_wrap(self, patches=""):
        self.wrap.write_text(f"[wrap-git]\nurl = {self.upstream.as_posix()}\n"
                             f"revision = {self.revision}\npatch_directory = sample\n"
                             + (f"diff_files = {patches}\n" if patches else ""))

    def patch(self, value):
        (self.packages / "value.patch").write_text(
            "diff --git a/value.c b/value.c\n--- a/value.c\n+++ b/value.c\n"
            f"@@ -1 +1 @@\n-int value(void) {{ return 1; }}\n"
            f"+int value(void) {{ return {value}; }}\n")

    def assert_answer(self, value):
        executable = self.app / "build" / ("answer.exe" if os.name == "nt" else "answer")
        self.assertEqual(self.run_command(executable).strip(), str(value))

    def test_clone_build_then_pull_new_and_changed_patch(self):
        self.assert_answer(1)
        self.patch(2)
        self.write_wrap("value.patch")
        self.meson("compile", "-C", "build")
        self.assert_answer(2)
        # The wrap stays unchanged. Patch contents must trigger regeneration.
        self.patch(3)
        self.meson("compile", "-C", "build")
        self.assert_answer(3)
        # No refresh or network request for an unchanged build.
        self.assertNotIn("Refreshing sample", self.meson("setup", "--reconfigure", "build"))
        self.assert_answer(3)

    def test_refresh_existing_checkout_without_sync_state(self):
        shutil.rmtree(self.app / "subprojects/.anvil-wrap-state")
        self.patch(2)
        self.write_wrap("value.patch")
        self.meson("compile", "-C", "build")
        self.assert_answer(2)

    def test_revision_change_rebuilds_library(self):
        (self.upstream / "value.c").write_text("int value(void) { return 7; }\n")
        self.run_command("git", "commit", "-am", "Change value", cwd=self.upstream)
        self.revision = self.run_command("git", "rev-parse", "HEAD", cwd=self.upstream).strip()
        self.write_wrap()
        self.meson("compile", "-C", "build")
        self.assert_answer(7)

    def test_overlay_change_rebuilds_library(self):
        self.overlay.write_text(self.overlay.read_text().replace(
            "'value.c')", "'value.c', c_args: ['-Dvalue=changed_value'])"))
        (self.app / "main.c").write_text((self.app / "main.c").read_text().replace("value", "changed_value"))
        self.meson("compile", "-C", "build")
        self.assert_answer(1)

    def test_local_edits_go_to_git_stash_and_build_caches_stay(self):
        (self.checkout / "notes.txt").write_text("my local edit\n")
        cache = self.checkout / "cache/objects.bin"
        cache.parent.mkdir()
        cache.write_text("expensive build output\n")
        self.patch(2)
        self.write_wrap("value.patch")
        self.meson("compile", "-C", "build")
        self.assert_answer(2)
        saved = self.run_command("git", "show", "refs/stash:notes.txt", cwd=self.checkout)
        self.assertEqual(saved, "my local edit\n")
        self.assertTrue(cache.is_file())

    def test_patch_change_rebuilds_and_relinks_custom_library(self):
        # Like Ghostty, this library uses its own build command, not Meson's compiler target.
        (self.overlay.parent / "build.py").write_text(
            "import subprocess, sys\n"
            "source, output = sys.argv[1:]\n"
            "subprocess.run(['cc', '-c', source, '-o', output + '.o'], check=True)\n"
            "subprocess.run(['ar', 'rcs', output, output + '.o'], check=True)\n")
        self.overlay.write_text(
            "project('sample', 'c')\n"
            "python = import('python').find_installation()\n"
            "data = configuration_data()\n"
            "data.set_quoted('INPUTS', import('fs').read('../.anvil-wrap-state/sample'))\n"
            "stamp = configure_file(output: 'inputs.h', configuration: data)\n"
            "lib = custom_target('sample', output: 'sample.a',\n"
            "  command: [python, files('build.py'),\n"
            "    meson.current_source_dir() / 'value.c', '@OUTPUT@'], depend_files: stamp)\n"
            "sample_dep = declare_dependency(link_with: lib)\n")
        self.meson("compile", "-C", "build")
        self.assert_answer(1)
        self.patch(9)
        self.write_wrap("value.patch")
        self.meson("compile", "-C", "build")
        self.assert_answer(9)
        self.patch(10)
        self.meson("compile", "-C", "build")
        self.assert_answer(10)


if __name__ == "__main__":
    unittest.main()
