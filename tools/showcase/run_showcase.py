#!/usr/bin/env python3
"""Take README screenshots of a busy Anvil on fake Projects.

The real app runs on a private desktop with its own user folder. Fake Projects come from
tools/showcase/projects. Fake commands in tools/showcase/bin act like Pi, npm, cargo and Gradle,
so the Project Sidebar shows agent status without any real agent or model call.

    python tools/showcase/run_showcase.py --no-build
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import struct
import sys
import tempfile
import time
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
from run_render_perf_gate import ROOT, build_anvil, copy_app_tree, invoke_hidden, native_path  # noqa: E402

LOADED = ["orbit-api", "raytracer", "mobile-app", "dotfiles"]  # The first one is the Selected Project.
# Dormant Projects and the days since their last activity. The Sidebar groups them by age.
DORMANT = {"blog": 1, "advent-of-code": 3, "infra": 9, "notes": 40}
WINDOW = (1720, 1040)


def write_png(bmp: Path, png: Path) -> None:
    """Converts the shell's top-down 32-bit BGRA capture to an opaque PNG."""
    data = bmp.read_bytes()
    offset, width, height = struct.unpack_from("<I", data, 10)[0], *struct.unpack_from("<ii", data, 18)
    height = abs(height)
    rows = []
    for y in range(height):
        row = data[offset + y * width * 4: offset + (y + 1) * width * 4]
        rgb = bytearray(width * 3)
        rgb[0::3], rgb[1::3], rgb[2::3] = row[2::4], row[1::4], row[0::4]
        rows.append(b"\0" + bytes(rgb))

    def chunk(kind: bytes, body: bytes) -> bytes:
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))

    png.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
                    + chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b""))


def shell_state(projects: Path) -> str:
    """The shell's saved Window: the loaded Projects, the Sidebar, and each Project's last activity."""
    def entry(name: str) -> str:
        path = native_path(projects / name)
        return f"{len(path.encode('utf-8'))} {path}"
    now = int(time.time())
    lines = ["anvil-shell-windows 7", "sequence 1", "sidebar 300",
             f"window 1 40 40 {WINDOW[0]} {WINDOW[1]} 0 0 {entry(LOADED[0])}"]
    lines += [f"loaded 1 {entry(name)}" for name in LOADED[1:]]
    lines += [f"project {now - 60 * index} {entry(name)}" for index, name in enumerate(LOADED)]
    lines += [f"project {now - days * 86400} {entry(name)}" for name, days in DORMANT.items()]
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--no-build", action="store_true")
    parser.add_argument("--out", type=Path, default=ROOT / "docs" / "screenshots")
    parser.add_argument("--keep", action="store_true", help="keep the temporary work folder")
    args = parser.parse_args()
    if not args.no_build:
        build_anvil()

    # Projects report long paths. A TEMP with an 8.3 short name would not match them.
    work = Path(tempfile.mkdtemp(prefix="anvil-showcase-")).resolve()
    ok = False
    try:
        exe = copy_app_tree(work / "app")
        shutil.copy2(HERE / "showcase.lua", work / "app/share/anvil/plugins/showcase.lua")
        projects = work / "Projects"
        shutil.copytree(HERE / "projects", projects)
        (work / "driver").mkdir()
        user = work / "user"
        user.mkdir()
        recents = ",".join(json.dumps(str(projects / name).replace("\\", "/")) for name in [*LOADED, *DORMANT])
        (user / "appstate.lua").write_text("return {recents={" + recents + "}}", encoding="utf-8")
        (user / "shell-windows.state").write_text(shell_state(projects), encoding="utf-8", newline="\n")
        namespace = "anvil-showcase-" + work.name.rsplit("-", 1)[-1]
        (user / "init.lua").write_text(
            "local open = shmem.open\n"
            f'shmem.open = function(name, capacity) return open(name == "anvil-ipc" and "{namespace}" or name, capacity) end\n'
            'local config = require "core.config"\n'
            "config.plugins.ipc.single_instance = false\n"
            'config.plugins.terminal.shell = "powershell.exe -NoLogo -NoProfile"\n'
            "config.plugins.terminal.prepare_session = false\n", encoding="utf-8")
        capture_dir = work / "capture"
        capture_dir.mkdir()
        config = {
            "exe": native_path(exe), "working_directory": native_path(work / "driver"),
            "arguments": ["--direct", native_path(work / "driver")],
            "environment": {
                "ANVIL_USERDIR": native_path(user), "USERPROFILE": native_path(user), "HOME": native_path(user),
                "ANVIL_SHOWCASE_ROOT": native_path(work).replace("\\", "/"),
                "PATH": native_path(HERE / "bin") + os.pathsep + os.environ.get("PATH", ""),
                "ANVIL_TEST_DISABLE_PLUGINS": "autorestart,autoreload,autosave_fast,autosaveonfocuslost",
                "ANVIL_RENDERER": "d3d11",
                "ANVIL_SURFACE_FAULT_PROBE": "1",
                "ANVIL_SURFACE_LOG": native_path(work / "surface.log"),
                "ANVIL_SHELL_CAPTURE_DIR": native_path(capture_dir),
                # A run from an Anvil Terminal must not make these launches Terminal requests.
                "ANVIL_TERMINAL_ID": "", "ANVIL_TERMINAL_PROJECT": "",
            }, "startup_timeout_seconds": 0, "stable_ui_scheduling": False,
        }
        config_path = work / "launch.json"
        config_path.write_text(json.dumps(config), encoding="utf-8")
        launcher = invoke_hidden(config_path, 240)
        result = work / "result.txt"
        text = result.read_text(encoding="utf-8") if result.exists() else "missing result"
        for error in work.glob("error-*.txt"):
            text += f"\n{error.stem}: {error.read_text(encoding='utf-8')}"
        capture = capture_dir / "capture-1.bmp"
        ok = text == "ok" and capture.exists()
        if ok:
            args.out.mkdir(parents=True, exist_ok=True)
            write_png(capture, args.out / "workspace.png")
            print(f"Screenshot written: {args.out / 'workspace.png'}")
        else:
            print(f"Showcase failed: exit={launcher.get('exit_code')} {text}")
        return 0 if ok else 1
    finally:
        if args.keep or not ok:
            print(f"work folder: {work}")
        else:
            shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
