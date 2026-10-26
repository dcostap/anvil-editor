#!/usr/bin/env python3
"""Refresh cached Git subprojects when their checked-in build inputs change."""

import argparse
import configparser
import hashlib
import os
from pathlib import Path
import subprocess
import sys


def sync(source_root, meson_command):
    subprojects = source_root / "subprojects"
    state_dir = subprojects / ".anvil-wrap-state"
    for wrap in sorted(subprojects.glob("*.wrap")):
        config = configparser.ConfigParser(interpolation=None)
        config.read(wrap, encoding="utf-8")
        if not config.has_section("wrap-git"):
            continue
        options = config["wrap-git"]
        inputs = [wrap]
        if "patch_directory" in options:
            overlay = subprojects / "packagefiles" / options["patch_directory"]
            inputs.extend(sorted(path for path in overlay.rglob("*") if path.is_file()))
        inputs.extend(subprojects / "packagefiles" / name.strip()
                      for name in options.get("diff_files", "").split(",") if name.strip())
        digest = hashlib.sha256()
        for path in inputs:
            # Meson reads these paths to track configure dependencies.
            print(path.as_posix())
            digest.update(path.relative_to(source_root).as_posix().encode())
            digest.update(b"\0")
            digest.update(path.read_bytes())
            digest.update(b"\0")
        fingerprint = digest.hexdigest()
        state = state_dir / wrap.stem
        if state.is_file() and state.read_text(encoding="ascii") == fingerprint:
            continue
        checkout = subprojects / options.get("directory", wrap.stem)
        if checkout.exists():
            if not (checkout / ".git").exists():
                raise RuntimeError(f"Refusing to replace non-Git dependency: {checkout}")
            print(f"Refreshing {wrap.stem}: dependency inputs changed. "
                  "Local edits go to the dependency's Git stash.", file=sys.stderr)
            # Meson stashes with --all, which also removes ignored build caches.
            # Stash edits first, so Meson finds only ignored files and keeps them.
            subprocess.run(["git", "stash", "push", "--include-untracked", "--", ".",
                            ":!/.meson-subproject-wrap-hash.txt"],
                           cwd=checkout, check=True, stdout=sys.stderr)
            subprocess.run([*meson_command, "subprojects", "update", "--reset", wrap.stem],
                           cwd=source_root, check=True, stdout=sys.stderr)
        # Missing checkouts use Meson's normal download path during setup.
        state_dir.mkdir(exist_ok=True)
        temporary = state.with_suffix(f".{os.getpid()}.tmp")
        temporary.write_text(fingerprint, encoding="ascii")
        temporary.replace(state)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_root", type=Path)
    parser.add_argument("meson_command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not args.meson_command:
        parser.error("a Meson command is required")
    sync(args.source_root.resolve(), args.meson_command)
