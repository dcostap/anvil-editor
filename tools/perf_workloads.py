"""Fixed stress workloads and generated, private fixtures."""
from __future__ import annotations

import hashlib
import os
import subprocess
from pathlib import Path
from typing import Any


def scenario(kind: str, **settings: Any) -> dict[str, Any]:
    return dict(kind=kind, window_width=1920, window_height=1400,
                visual=True, paced=False, actions=12, code_scale=0.7, **settings)


SCENARIOS = {
    "find-overview": scenario("find", lines=6000, wrap=False),
    "find-overview-wrap": scenario("find", lines=600, wrap=True),
    "find-overview-wrap-reference": scenario("find", lines=600, wrap=True,
        reference_overview=True),
    "find-overview-alpha": dict(scenario("find", lines=6000, wrap=False,
        repeats=12, marker_alpha=7), window_height=480),
    "find-overview-alpha-reference": dict(scenario("find", lines=6000, wrap=False,
        repeats=12, marker_alpha=7, reference_overview=True), window_height=480),
    "diff-scroll-medium": scenario("diff", lines=4000, change_every=8, action="scroll", wrap=True),
    "diff-scroll-large": scenario("diff", lines=40000, change_every=8, action="scroll", wrap=True),
    "diff-steady-large": scenario("diff", lines=40000, change_every=8, action="redraw", wrap=True),
    "diff-navigate-large": scenario("diff", lines=40000, change_every=8, action="navigate", wrap=True),
    "fuzzy-files-medium": scenario("fuzzy", files=1000, action="file-query"),
    "fuzzy-files-large": scenario("fuzzy", files=10000, action="file-query"),
    "fuzzy-text-large": scenario("fuzzy", files=10000, action="text-query"),
    "file-switch-large": scenario("switch", files=16, lines=4000),
    "file-open-large": scenario("open", lines=100000),
    "file-open-huge": scenario("open", lines=500000),
    "long-line-edit": scenario("edit", lines=32, line_bytes=65536, carets=1),
    "multi-caret-edit": scenario("edit", lines=4000, line_bytes=100, carets=1024),
}

DIFF_WHEEL_SCENARIOS = {
    f"diff-wheel-{mode}": dict(
        scenario("diff", lines=4000, change_every=8, action="wheel", wrap=wrap,
                 save_workspace=True, capture_actions=True,
                 capture_checkpoints=[10, 30, 40, 41]),
        actions=41, code_scale=1, window_width=2560,
    )
    for mode, wrap in (("wrapped", True), ("unwrapped", False))
}
SCENARIOS.update(DIFF_WHEEL_SCENARIOS)


def editor_scene(content: str, lines: int, wrap: bool = False,
                 action: str = "jump") -> dict[str, Any]:
    settings = scenario("editor", content=content, lines=lines, wrap=wrap)
    if action != "jump":
        settings["action"] = action
    checkpoints = [1, 15, 30, 40] if action == "scroll" else [1, 2, 3, 40]
    settings.update(window_width=2560, window_height=1407, code_scale=1.0,
                    actions=40, capture_actions=True, capture_checkpoints=checkpoints)
    return settings


# Keep these fixtures private and fixed across the before/after render comparison.
EDITOR_SCENARIOS = {
    "editor-code-small-nowrap": editor_scene("code", 24),
    "editor-code-small-wrap": editor_scene("code", 24, True),
    "editor-code-large-nowrap": editor_scene("code", 100000),
    "editor-code-large-wrap": editor_scene("code", 100000, True),
    "editor-markdown-small": editor_scene("markdown", 24, True),
    "editor-markdown-large": editor_scene("markdown", 4000, True),
    "editor-unicode-wrap": editor_scene("unicode", 800, True),
    "editor-unicode-source-wrap": editor_scene("unicode-source", 204, True),
    "editor-unicode-source-nowrap": editor_scene("unicode-source", 204),
    "editor-code-large-type": editor_scene("code", 100000, action="type"),
    "editor-code-large-scroll": editor_scene("code", 100000, action="scroll"),
    "editor-markdown-large-type": editor_scene("markdown", 4000, True, action="type"),
    "editor-markdown-large-scroll": editor_scene("markdown", 4000, True, action="scroll"),
    "editor-unicode-source-scroll": editor_scene("unicode-source", 204, True, action="scroll"),
    "editor-fuzzy-open": dict(
        scenario("fuzzy", files=1000, action="file-query"),
        window_width=2560, window_height=1407, code_scale=1.0,
        actions=8, capture_actions=True, capture_checkpoints=[1, 2, 8],
    ),
}
SCENARIOS.update(EDITOR_SCENARIOS)
# A fresh process opens the large file once. It does not measure cached reopen calls.
for name in ("file-open-large", "file-open-huge"):
    SCENARIOS[name]["actions"] = 1


def generate(root: Path, settings: dict[str, Any]) -> dict[str, Any]:
    """Return a portable content manifest. Generation is outside measured time."""
    root.mkdir(parents=True, exist_ok=True)
    manifest: list[dict[str, Any]] = []

    def save(name: str, text: str) -> None:
        data = text.encode("utf-8")
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        # Stable metadata also keeps File Tree text repeatable.
        os.utime(path, (1700000000, 1700000000))
        manifest.append(dict(path=name, bytes=len(data), lines=text.count("\n"),
                             sha256=hashlib.sha256(data).hexdigest()))

    kind = settings["kind"]
    count = settings.get("lines", 1)
    if kind == "find":
        save("find.c", "".join(
            ("int input = input + 1; /* input */" * settings.get("repeats", 12 if settings["wrap"] else 1)
             + "\n") if i % 7 < 3 else "/* no match */\n"
            for i in range(count)))
    elif kind == "diff":
        left, right = [], []
        for i in range(1, count + 1):
            line = f'local row_{i:07d} = "stable value {i:07d} office affine éλ漢字"\n'
            left.append(line)
            if i % settings["change_every"] == 0:
                # Replacement, deletion, and unequal insertion blocks.
                left[-1] = f'local removed_{i:07d} = "before {i}"\n'
                if (i // settings["change_every"]) % 3 != 0:
                    right.append(f'local inserted_{i:07d} = "after {i}"\n')
                    right.append(f'local inserted_extra_{i:07d} = true\n')
            else:
                right.append(line)
        save("left.lua", "".join(left))
        save("right.lua", "".join(right))
    elif kind == "fuzzy":
        for i in range(1, settings["files"] + 1):
            save(f"project/group-{i % 64:02d}/candidate_{i:06d}.lua",
                 f"-- BENCH_NEEDLE_{i:06d}\nreturn {i}\n")
    elif kind == "switch":
        for file in range(1, settings["files"] + 1):
            save(f"switch-{file:03d}.lua", "".join(
                f"local value_{i:06d} = {file} -- switch fixture\n"
                for i in range(1, count + 1)))
    elif kind == "open":
        save("huge.lua", "".join(
            f'local value_{i:07d} = "large file row {i:07d} with syntax and words"\n'
            for i in range(1, count + 1)))
    elif kind == "edit":
        save("edit.txt", ("x" * (settings["line_bytes"] - 1) + "\n") * count)
    elif kind == "editor":
        content = settings["content"]
        if content == "unicode-source":
            source = Path(__file__).resolve().parents[1] / "tests/fixtures/unicode-stress-test.txt"
            save("scene.txt", source.read_bytes().decode("utf-8"))
        elif content == "code":
            save("scene.cpp", "".join(
                f'auto Panel_{i:06d}::draw(const Widget& widget) -> bool {{ '
                f'const auto label = "row {i:06d} syntax and selected text"; '
                f'return widget.paint(label, {i} * 3 + 7); }}\n'
                for i in range(1, count + 1)))
        elif content == "markdown":
            save("scene.md", "".join(
                (f"## Section {i:06d}: an editor heading\n" if i % 12 == 1 else
                 f"- [ ] **Task {i:06d}** with *emphasis*, `inline code`, "
                 f"and [a link](https://example.invalid/{i}) in a long paragraph "
                 f"that wraps in the reading lane.\n")
                for i in range(1, count + 1)))
        elif content == "unicode":
            samples = (
                'café naïve e\u0301 A\u030a — ελληνικά Ελληνικά 中文 漢字 日本語',
                'العَرَبِيَّة עברית नमस्ते ไทย 한글 🦊 👩‍💻 🚀',
                '┌────┐ │ box │ └────┘ 𝛌 𝔄 𝒙 \t tab  🌍🌎🌏',
            )
            save("scene.cpp", "".join(
                f'// Unicode row {i:04d}: {samples[(i - 1) % len(samples)]}\n'
                for i in range(1, count + 1)))
        else:
            raise ValueError(f"unknown editor content: {content}")
    else:
        raise ValueError(f"unknown workload: {kind}")
    digest = hashlib.sha256()
    for item in manifest:
        digest.update((item["path"] + "\0" + item["sha256"] + "\n").encode())
    if settings.get("capture_actions"):
        # Do not let Git scan the source checkout above this private fixture.
        subprocess.run(["git", "init", "-q", str(root)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    return {"sha256": digest.hexdigest(), "files": manifest}
