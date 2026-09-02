#!/usr/bin/env python3
"""Build Anvil's deterministic compressed runtime archive."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import struct
import sys
import zlib

MAGIC = b"ANVRT001"
HEADER = struct.Struct("<8s16sI")
ENTRY = struct.Struct("<HQQI")
MAX_FILES = 10_000
MAX_FILE_SIZE = 64 * 1024 * 1024


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", required=True, type=Path)
    parser.add_argument("--start-file", required=True, type=Path)
    parser.add_argument("--vmdef-file", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--resource-script", required=True, type=Path)
    parser.add_argument("--extra-languages", action="store_true")
    return parser.parse_args()


def archive_name(path: Path) -> str:
    name = PurePosixPath(path.as_posix()).as_posix()
    if name.startswith("/") or ".." in PurePosixPath(name).parts:
        raise ValueError(f"unsafe archive path: {name}")
    encoded = name.encode("utf-8")
    if not encoded or len(encoded) > 0xFFFF:
        raise ValueError(f"invalid archive path length: {name}")
    return name


def add_file(files: dict[str, Path], name: str, source: Path) -> None:
    name = archive_name(Path(name))
    previous = files.get(name)
    if previous and previous.resolve() != source.resolve():
        raise ValueError(f"duplicate archive path: {name}")
    files[name] = source


def add_tree(files: dict[str, Path], source: Path, destination: str = "") -> None:
    for path in sorted(source.rglob("*")):
        if path.is_file() and path.name != ".gitignore":
            relative = path.relative_to(source).as_posix()
            add_file(files, f"{destination}/{relative}".lstrip("/"), path)


def collect_files(args: argparse.Namespace) -> dict[str, Path]:
    source_root = args.source_root.resolve()
    files: dict[str, Path] = {}

    add_tree(files, source_root / "data")
    files.pop("core/start.lua", None)
    add_file(files, "core/start.lua", args.start_file.resolve())

    add_tree(files, source_root / "resources" / "icons", "icons")
    add_tree(files, source_root / "subprojects" / "luajit" / "src" / "jit", "jit")
    add_file(files, "jit/vmdef.lua", args.vmdef_file.resolve())

    if args.extra_languages:
        plugin_root = source_root / "subprojects" / "plugins" / "plugins"
        for path in sorted(plugin_root.glob("language_*")):
            if path.is_file():
                name = f"plugins/{path.name}"
                if name not in files:
                    add_file(files, name, path)

    add_file(files, "doc/LICENSE", source_root / "LICENSE")
    add_file(files, "doc/licenses.md", source_root / "licenses" / "licenses.md")
    add_file(files, "doc/tree-sitter.md", source_root / "licenses" / "tree-sitter.md")

    missing = [str(path) for path in files.values() if not path.is_file()]
    if missing:
        raise FileNotFoundError("missing runtime input: " + ", ".join(missing))
    return files


def build_id(files: dict[str, Path]) -> bytes:
    digest = hashlib.sha256()
    for name, path in sorted(files.items()):
        data = path.read_bytes()
        digest.update(name.encode("utf-8"))
        digest.update(b"\0")
        digest.update(struct.pack("<Q", len(data)))
        digest.update(data)
    return digest.digest()[:16]


def write_archive(output: Path, files: dict[str, Path]) -> None:
    if not files or len(files) > MAX_FILES:
        raise ValueError(f"invalid runtime file count: {len(files)}")
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(output.name + f".tmp-{os.getpid()}")
    identifier = build_id(files)

    try:
        with temporary.open("wb") as stream:
            stream.write(HEADER.pack(MAGIC, identifier, len(files)))
            for name, path in sorted(files.items()):
                raw = path.read_bytes()
                if len(raw) > MAX_FILE_SIZE:
                    raise ValueError(f"runtime file is too large: {name}")
                compressed = zlib.compress(raw, level=9)
                encoded_name = name.encode("utf-8")
                stream.write(ENTRY.pack(
                    len(encoded_name), len(raw), len(compressed), zlib.crc32(raw)
                ))
                stream.write(encoded_name)
                stream.write(compressed)
        os.replace(temporary, output)
    finally:
        temporary.unlink(missing_ok=True)

    print(
        f"Embedded runtime: {len(files)} files, "
        f"{output.stat().st_size} bytes, id={identifier.hex()}"
    )


def write_resource_script(path: Path, archive: Path) -> None:
    path.write_text(
        '#define ANVIL_RUNTIME_RESOURCE_ID 201\n\n'
        f'ANVIL_RUNTIME_RESOURCE_ID RCDATA "{archive.resolve().as_posix()}"\n',
        encoding="utf-8",
    )


def main() -> int:
    args = parse_args()
    try:
        write_archive(args.output, collect_files(args))
        write_resource_script(args.resource_script, args.output)
    except Exception as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    raise SystemExit(main())
