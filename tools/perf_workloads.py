"""Fixed stress workloads and generated, private fixtures."""
from __future__ import annotations

import hashlib
import os
from pathlib import Path
from typing import Any


def scenario(kind: str, **settings: Any) -> dict[str, Any]:
    return dict(kind=kind, window_width=1920, window_height=1400,
                visual=True, paced=False, actions=12, code_scale=0.7, **settings)


SCENARIOS = {
    "diff-scroll-medium": scenario("diff", lines=4000, change_every=8, action="scroll"),
    "diff-scroll-large": scenario("diff", lines=40000, change_every=8, action="scroll"),
    "diff-steady-large": scenario("diff", lines=40000, change_every=8, action="redraw"),
    "diff-navigate-large": scenario("diff", lines=40000, change_every=8, action="navigate"),
    "fuzzy-files-medium": scenario("fuzzy", files=1000, action="file-query"),
    "fuzzy-files-large": scenario("fuzzy", files=10000, action="file-query"),
    "fuzzy-text-large": scenario("fuzzy", files=10000, action="text-query"),
    "file-switch-large": scenario("switch", files=16, lines=4000),
    "file-open-large": scenario("open", lines=100000),
    "file-open-huge": scenario("open", lines=500000),
    "long-line-edit": scenario("edit", lines=32, line_bytes=65536, carets=1),
    "multi-caret-edit": scenario("edit", lines=4000, line_bytes=100, carets=1024),
}
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
    if kind == "diff":
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
    else:
        raise ValueError(f"unknown workload: {kind}")
    digest = hashlib.sha256()
    for item in manifest:
        digest.update((item["path"] + "\0" + item["sha256"] + "\n").encode())
    return {"sha256": digest.hexdigest(), "files": manifest}
