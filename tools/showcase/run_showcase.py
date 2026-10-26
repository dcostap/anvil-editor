#!/usr/bin/env python3
"""Take README screenshots of a busy Anvil on fake Projects.

The real app runs on a private desktop with its own user folder. Fake Projects come from
tools/showcase/projects. The installed Pi runs the scenarios in agents.json against a canned
model server in this script, so it calls no real model. Fake commands in tools/showcase/bin
act like npm, cargo and Gradle.

    python tools/showcase/run_showcase.py --no-build

It writes docs/screenshots/workspace.png, and themes.png with one Markdown note in each Color Theme.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
from run_render_perf_gate import ROOT, build_anvil, copy_app_tree, invoke_hidden, native_path  # noqa: E402

# Each scene: the loaded Projects (the first one is Selected), the Dormant Projects with the days since their last
# activity, the Window size, and whether the Sidebar shows. showcase.lua opens the Panes of each loaded Project.
SCENES = {
    "workspace": (["orbit-api", "raytracer", "mobile-app", "dotfiles"],
                  {"blog": 1, "advent-of-code": 3, "infra": 9, "notes": 40}, (1720, 1040), True),
    "themes": (["notes"], {}, (900, 1000), False),
}
THEMES = ["dark", "dark3", "light2", "light"]  # From the back of the stack to the front.
AGENTS = json.loads((HERE / "agents.json").read_text(encoding="utf-8"))
# The models in the Terminal commands of showcase.lua: ID, name, and dollars per million input and output tokens.
MODELS = {
    "anthropic": [("claude-opus-5-5", "Claude Opus 5.5", 5, 25), ("claude-sonnet-5-5", "Claude Sonnet 5.5", 3, 15)],
    "openai": [("gpt-6.1", "GPT-6.1", 2.5, 15)],
}


class CannedModel(BaseHTTPRequestHandler):
    """An OpenAI Chat Completions endpoint. It streams the next turn of the scenario whose prompt it receives."""
    stop = threading.Event()

    def log_message(self, *args) -> None:
        pass

    def send(self, delta: dict | None = None, finish: str | None = None, usage: dict | None = None) -> None:
        chunk = {"id": "showcase", "object": "chat.completion.chunk", "created": int(time.time()), "model": "showcase",
                 "choices": [] if usage else [{"index": 0, "delta": delta or {}, "finish_reason": finish}]}
        if usage:
            chunk["usage"] = usage
        self.wfile.write(b"data: " + json.dumps(chunk).encode("utf-8") + b"\n\n")
        self.wfile.flush()

    def do_POST(self) -> None:
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        messages = request.get("messages", [])
        prompt = next((m["content"] for m in messages if m.get("role") == "user"), "")
        if isinstance(prompt, list):
            prompt = "".join(part.get("text", "") for part in prompt)
        agent = next((a for a in AGENTS.values() if a["prompt"] == prompt.strip()), None)
        index = sum(1 for m in messages if m.get("role") == "assistant")
        if not agent or index >= len(agent["turns"]):
            self.send_error(400, "no canned turn")
            return
        turn = agent["turns"][index]
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        if "thinking" in turn:
            for word in turn["thinking"].split(" "):
                self.send({"reasoning_content": word + " "})
        if "text" in turn:
            self.send({"role": "assistant", "content": turn["text"]})
        if turn.get("hang"):
            self.stop.wait()
            return
        for number, tool in enumerate(turn.get("tools", [])):
            self.send({"tool_calls": [{"index": number, "id": f"call_{index}_{number}", "type": "function",
                                       "function": {"name": tool["name"], "arguments": json.dumps(tool["args"])}}]})
        self.send(finish="tool_calls" if turn.get("tools") else "stop")
        self.send(usage={"prompt_tokens": 11000 + 3500 * index, "completion_tokens": 600 + 150 * index})
        self.wfile.write(b"data: [DONE]\n\n")


def pi_agent_dir(path: Path, url: str) -> None:
    """A private Pi configuration: the canned models only, and no user extensions, skills or sessions."""
    providers = {
        provider: {"baseUrl": url, "api": "openai-completions", "apiKey": "showcase", "models": [
            {"id": id, "name": name, "reasoning": True, "input": ["text"], "contextWindow": 400000,
             "maxTokens": 64000, "cost": {"input": cost_in, "output": cost_out, "cacheRead": 0, "cacheWrite": 0}}
            for id, name, cost_in, cost_out in models]}
        for provider, models in MODELS.items()}
    path.mkdir(parents=True)
    (path / "models.json").write_text(json.dumps({"providers": providers}, indent=2), encoding="utf-8")
    (path / "settings.json").write_text(json.dumps({"defaultThinkingLevel": "high", "quietStartup": True}), encoding="utf-8")


def git_history(project: Path) -> None:
    """Gives orbit-api a branch and a release tag, for the agent that reads its log."""
    env = {**os.environ, "GIT_AUTHOR_NAME": "Orbit", "GIT_AUTHOR_EMAIL": "dev@orbit.example",
           "GIT_COMMITTER_NAME": "Orbit", "GIT_COMMITTER_EMAIL": "dev@orbit.example"}

    def git(*args: str) -> None:
        subprocess.run(["git", "-c", "core.autocrlf=false", *args], cwd=project, env=env, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    git("init", "-b", "main")
    git("add", "-A")
    git("commit", "-m", "Add invoice previews")
    git("tag", "v2.3.0")
    for message in ["Round CSV export lines to the cent", "Split previews at plan changes", "Update dependencies"]:
        git("commit", "--allow-empty", "-m", message)
    git("checkout", "-b", "feat/proration")


class Image:
    """An RGB image as a list of rows."""

    def __init__(self, width: int, height: int, rows: list[bytearray]):
        self.width, self.height, self.rows = width, height, rows

    @staticmethod
    def from_bmp(bmp: Path) -> "Image":
        """Reads the shell's top-down 32-bit BGRA capture."""
        data = bmp.read_bytes()
        offset, width, height = struct.unpack_from("<I", data, 10)[0], *struct.unpack_from("<ii", data, 18)
        rows = []
        for y in range(abs(height)):
            row = data[offset + y * width * 4: offset + (y + 1) * width * 4]
            rgb = bytearray(width * 3)
            rgb[0::3], rgb[1::3], rgb[2::3] = row[2::4], row[1::4], row[0::4]
            rows.append(rgb)
        return Image(width, abs(height), rows)

    def write_png(self, png: Path) -> None:
        def chunk(kind: bytes, body: bytes) -> bytes:
            return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))
        header = struct.pack(">IIBBBBB", self.width, self.height, 8, 2, 0, 0, 0)
        pixels = b"".join(b"\0" + bytes(row) for row in self.rows)
        png.parent.mkdir(parents=True, exist_ok=True)
        png.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(pixels, 9))
                        + chunk(b"IEND", b""))


def stack(cards: list[Image], step: int, shadow: int = 28) -> Image:
    """Lays the cards left to right, each one over the one before, like a fanned hand. Only the last shows whole.
    Each card casts a soft shadow on the card under its left edge."""
    width, height = cards[0].width + step * (len(cards) - 1), cards[0].height
    rows = [bytearray(width * 3) for _ in range(height)]
    for index, card in enumerate(cards):
        left = index * step
        if index:
            band = range(left - shadow, left)
            darken = [1 - 0.5 * (1 - (left - x) / shadow) ** 2 for x in band]
            for row in rows:
                for x, factor in zip(band, darken):
                    for c in range(x * 3, x * 3 + 3):
                        row[c] = int(row[c] * factor)
        for row, source in zip(rows, card.rows):
            row[left * 3: (left + card.width) * 3] = source
    return Image(width, height, rows)


def shell_state(projects: Path, loaded: list[str], dormant: dict[str, int], window: tuple[int, int],
                sidebar: bool) -> str:
    """The shell's saved Window: the loaded Projects, the Sidebar, and each Project's last activity."""
    def entry(name: str) -> str:
        path = native_path(projects / name)
        return f"{len(path.encode('utf-8'))} {path}"
    now = int(time.time())
    lines = ["anvil-shell-windows 7", "sequence 1", "sidebar 300",
             f"window 1 40 40 {window[0]} {window[1]} 0 {0 if sidebar else 1} {entry(loaded[0])}"]
    lines += [f"loaded 1 {entry(name)}" for name in loaded[1:]]
    lines += [f"project {now - 60 * index} {entry(name)}" for index, name in enumerate(loaded)]
    lines += [f"project {now - days * 86400} {entry(name)}" for name, days in dormant.items()]
    return "\n".join(lines) + "\n"


def capture(scene: str, theme: str, real_pi: str, keep: bool) -> Image:
    """Runs one scene in the real app on a private desktop, and returns the shell's capture of its Window."""
    loaded, dormant, window, sidebar = SCENES[scene]
    # Projects report long paths. A TEMP with an 8.3 short name would not match them.
    work = Path(tempfile.mkdtemp(prefix="anvil-showcase-")).resolve()
    server = ThreadingHTTPServer(("127.0.0.1", 0), CannedModel)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    ok = False
    try:
        exe = copy_app_tree(work / "app")
        shutil.copy2(HERE / "showcase.lua", work / "app/share/anvil/plugins/showcase.lua")
        # Pi shows paths in the home folder with "~", so the Projects live in a fake home.
        home = work / "home"
        projects = home / "Projects"
        shutil.copytree(HERE / "projects", projects)
        git_history(projects / "orbit-api")
        pi_agent_dir(work / "pi-agent", f"http://127.0.0.1:{server.server_port}/v1")
        (work / "driver").mkdir()
        user = work / "user"
        user.mkdir()
        recents = ",".join(json.dumps(str(projects / name).replace("\\", "/")) for name in [*loaded, *dormant])
        (user / "appstate.lua").write_text("return {recents={" + recents + "}}", encoding="utf-8")
        (user / "shell-windows.state").write_text(shell_state(projects, loaded, dormant, window, sidebar),
                                                  encoding="utf-8", newline="\n")
        (user / "user_settings.lua").write_text(f'return {{config = {{theme = "{theme}"}}}}\n', encoding="utf-8")
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
                "ANVIL_USERDIR": native_path(user), "USERPROFILE": native_path(home), "HOME": native_path(home),
                "ANVIL_SHOWCASE_ROOT": native_path(work).replace("\\", "/"),
                "ANVIL_SHOWCASE_LOADED": ",".join(loaded),
                "ANVIL_SHOWCASE_PI": native_path(Path(real_pi)),
                "ANVIL_SHOWCASE_AGENTS": native_path(HERE / "agents.json"),
                "PI_CODING_AGENT_DIR": native_path(work / "pi-agent"),
                "PI_OFFLINE": "1", "PI_SKIP_VERSION_CHECK": "1",
                "PATH": native_path(HERE / "bin") + os.pathsep + os.environ.get("PATH", ""),
                "ANVIL_TEST_DISABLE_PLUGINS": "autorestart,autoreload,autosave_fast,autosaveonfocuslost",
                "ANVIL_RENDERER": "d3d11",
                "ANVIL_SURFACE_FAULT_PROBE": "1",
                "ANVIL_SURFACE_LOG": native_path(work / "surface.log"),
                "ANVIL_SHELL_CAPTURE_DIR": native_path(capture_dir),
            }, "startup_timeout_seconds": 0, "stable_ui_scheduling": False,
        }
        config_path = work / "launch.json"
        config_path.write_text(json.dumps(config), encoding="utf-8")
        launcher = invoke_hidden(config_path, 240)
        result = work / "result.txt"
        text = result.read_text(encoding="utf-8") if result.exists() else "missing result"
        for error in work.glob("error-*.txt"):
            text += f"\n{error.stem}: {error.read_text(encoding='utf-8')}"
        bmp = capture_dir / "capture-1.bmp"
        if text != "ok" or not bmp.exists():
            raise RuntimeError(f"{scene} in {theme}: exit={launcher.get('exit_code')} {text}")
        ok = True
        return Image.from_bmp(bmp)
    finally:
        CannedModel.stop.set()
        server.shutdown()
        CannedModel.stop.clear()
        if keep or not ok:
            print(f"work folder: {work}")
        else:
            # Git writes its objects read-only, and Windows does not delete read-only files.
            shutil.rmtree(work, onerror=lambda remove, path, _: (os.chmod(path, stat.S_IWRITE), remove(path)))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--no-build", action="store_true")
    parser.add_argument("--scene", choices=["all", *SCENES], default="all")
    parser.add_argument("--out", type=Path, default=ROOT / "docs" / "screenshots")
    parser.add_argument("--keep", action="store_true", help="keep the temporary work folders")
    args = parser.parse_args()
    real_pi = shutil.which("pi")
    if not real_pi:
        print("The showcase needs Pi on PATH: https://pi.dev")
        return 1
    if not args.no_build:
        build_anvil()
    # Settings from the shell that runs this script, such as an outer Pi's model or session, stay out.
    for name in [name for name in os.environ if name.startswith(("PI_", "ANVIL_"))]:
        del os.environ[name]
    try:
        if args.scene in ("all", "workspace"):
            capture("workspace", "dark", real_pi, args.keep).write_png(args.out / "workspace.png")
            print(f"Screenshot written: {args.out / 'workspace.png'}")
        if args.scene in ("all", "themes"):
            cards = [capture("themes", theme, real_pi, args.keep) for theme in THEMES]
            stack(cards, cards[0].width * 2 // 9).write_png(args.out / "themes.png")
            print(f"Screenshot written: {args.out / 'themes.png'}")
    except RuntimeError as error:
        print(f"Showcase failed: {error}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
