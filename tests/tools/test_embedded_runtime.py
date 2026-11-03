"""Check the files shipped by the Windows runtime generator."""

from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib


ROOT = Path(__file__).resolve().parents[2]


class EmbeddedRuntimeTests(unittest.TestCase):
    def test_packages_runtime_assets_without_build_inputs_or_unused_helpers(self):
        with tempfile.TemporaryDirectory(prefix="anvil-runtime-test-") as directory:
            root = Path(directory)
            sources = {
                "data/core/start.lua": b"unconfigured start",
                "data/core/init.lua": b"core",
                "data/plugins/fuzzy_searcher/rg.exe": b"ripgrep",
                "data/plugins/fuzzy_searcher/fd.exe": b"unused helper",
                "data/fonts/CaskaydiaCoveNerdFontMono-Regular.ttf": b"regular font",
                "data/fonts/CaskaydiaCoveNerdFontMono-SemiLight.ttf": b"selectable font",
                "resources/icons/logo.png": b"Linux icon",
                "resources/icons/logo-source.png": b"source artwork",
                "resources/icons/icon.icns": b"macOS icon",
                "resources/icons/icon.ico": b"Windows resource input",
                "resources/icons/icon.inl": b"C source input",
                "resources/icons/icon.rc": b"resource script input",
                "resources/icons/agents/pi.svg": b"agent icon",
                "resources/icons/file_types/seti.ttf": b"file icons",
                "resources/icons/file_types/LICENSE.txt": b"icon license",
                "subprojects/luajit/src/jit/bc.lua": b"JIT module",
                "subprojects/plugins/plugins/language_sample.lua": b"language",
                "LICENSE": b"editor license",
                "licenses/licenses.md": b"dependency licenses",
                "licenses/tree-sitter.md": b"parser licenses",
                "licenses/conpty.md": b"ConPTY license",
                "build/start.lua": b"configured start",
                "build/vmdef.lua": b"configured VM",
                "build/conpty.dll": b"ConPTY library",
                "build/OpenConsole.exe": b"ConPTY host",
            }
            for name, content in sources.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(content)

            archive = root / "runtime.bin"
            result = subprocess.run([
                sys.executable, str(ROOT / "scripts/generate-embedded-runtime.py"),
                "--source-root", str(root),
                "--start-file", str(root / "build/start.lua"),
                "--vmdef-file", str(root / "build/vmdef.lua"),
                "--conpty-dll", str(root / "build/conpty.dll"),
                "--conpty-host", str(root / "build/OpenConsole.exe"),
                "--extra-languages",
                "--output", str(archive),
                "--resource-script", str(root / "runtime.rc"),
            ], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

            data = archive.read_bytes()
            magic, _, count = struct.unpack_from("<8s16sI", data)
            self.assertEqual(magic, b"ANVRT001")
            offset = 28
            entries = {}
            for _ in range(count):
                name_size, raw_size, compressed_size, crc = struct.unpack_from("<HQQI", data, offset)
                offset += 22
                name = data[offset:offset + name_size].decode("utf-8")
                offset += name_size
                content = zlib.decompress(data[offset:offset + compressed_size])
                offset += compressed_size
                self.assertEqual(len(content), raw_size)
                self.assertEqual(zlib.crc32(content), crc)
                entries[name] = content
            self.assertEqual(offset, len(data))
            self.assertEqual(entries, {
                "core/start.lua": b"configured start",
                "core/init.lua": b"core",
                "plugins/fuzzy_searcher/rg.exe": b"ripgrep",
                "plugins/language_sample.lua": b"language",
                "fonts/CaskaydiaCoveNerdFontMono-Regular.ttf": b"regular font",
                "fonts/CaskaydiaCoveNerdFontMono-SemiLight.ttf": b"selectable font",
                "icons/agents/pi.svg": b"agent icon",
                "icons/file_types/seti.ttf": b"file icons",
                "icons/file_types/LICENSE.txt": b"icon license",
                "jit/bc.lua": b"JIT module",
                "jit/vmdef.lua": b"configured VM",
                "conpty/conpty.dll": b"ConPTY library",
                "conpty/OpenConsole.exe": b"ConPTY host",
                "doc/LICENSE": b"editor license",
                "doc/licenses.md": b"dependency licenses",
                "doc/tree-sitter.md": b"parser licenses",
                "doc/conpty.md": b"ConPTY license",
            })


if __name__ == "__main__":
    unittest.main()
