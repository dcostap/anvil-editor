"""Deterministic Project and Git fixtures for scenario runs.

A fixture spec describes a codebase, its Git history, and its working-tree
state. Building a large repository takes minutes, so each built fixture is
cached under one directory per spec hash. Every run resets the cached
repository to its commit and applies the same working-tree changes again.
"""
from __future__ import annotations

import base64
from collections import deque
from dataclasses import asdict, dataclass, field
import hashlib
import json
import os
from pathlib import Path
import random
import shutil
import struct
import subprocess
import threading
import time
from typing import Iterator
import zlib

# Bump when generated content changes, so stale caches are rebuilt.
GENERATOR_VERSION = 1
FIXED_MTIME = 1700000000
COMMITTER = "Anvil Fixture <fixture@example.invalid>"
REPO_ROOT = Path(__file__).resolve().parent.parent

WORDS = (
    "alpha", "anchor", "atlas", "beacon", "bridge", "buffer", "cache", "canvas",
    "cursor", "delta", "editor", "engine", "filter", "frame", "gutter", "index",
    "layout", "lexer", "marker", "matrix", "module", "native", "outline", "packet",
    "panel", "parser", "render", "scroll", "search", "shader", "signal", "socket",
    "status", "symbol", "syntax", "theme", "token", "vector", "viewport", "worker",
)
LANGUAGES = (".lua", ".c", ".h", ".py", ".js", ".ts", ".md", ".json")


@dataclass(frozen=True)
class RepoSpec:
    """A Git repository with generated code and a dirty working tree."""
    name: str
    files: int
    fanout: int = 8
    files_per_dir: int = 24
    min_lines: int = 4
    max_lines: int = 120
    commits: int = 1
    modified: int = 0
    staged: int = 0
    deleted: int = 0
    untracked: int = 0
    ignored: int = 0
    seed: int = 1

    @property
    def key(self) -> str:
        payload = json.dumps({"version": GENERATOR_VERSION, "kind": "repo", **asdict(self)},
                             sort_keys=True)
        return f"{self.name}-{hashlib.sha256(payload.encode()).hexdigest()[:12]}"


@dataclass(frozen=True)
class FolderSpec:
    """Generated code outside any Git repository, such as a downloads or scratch folder."""
    name: str
    files: int
    fanout: int = 8
    files_per_dir: int = 24
    min_lines: int = 4
    max_lines: int = 120
    seed: int = 1

    @property
    def key(self) -> str:
        payload = json.dumps({"version": GENERATOR_VERSION, "kind": "folder", **asdict(self)},
                             sort_keys=True)
        return f"{self.name}-{hashlib.sha256(payload.encode()).hexdigest()[:12]}"


@dataclass(frozen=True)
class ProjectSetSpec:
    """Several small Git repositories, such as recent Projects for the Project Sidebar."""
    name: str
    projects: int
    repo: RepoSpec = field(default_factory=lambda: RepoSpec("member", files=60, modified=3))

    @property
    def key(self) -> str:
        payload = json.dumps({"version": GENERATOR_VERSION, "kind": "set", **asdict(self)},
                             sort_keys=True)
        return f"{self.name}-{hashlib.sha256(payload.encode()).hexdigest()[:12]}"


@dataclass(frozen=True)
class MarkdownSpec:
    """A folder with one Markdown note that embeds a large image as a data URI.

    Pasted screenshots often arrive this way. The image line holds the whole
    encoded image, so it is far longer than any normal line.
    """
    name: str
    image_width: int = 640
    image_height: int = 333
    lines_before: int = 30
    lines_after: int = 300
    # Tables after the image. Their layout follows the view width.
    tables: int = 0
    seed: int = 1

    @property
    def key(self) -> str:
        payload = json.dumps({"version": GENERATOR_VERSION, "kind": "markdown", **asdict(self)},
                             sort_keys=True)
        return f"{self.name}-{hashlib.sha256(payload.encode()).hexdigest()[:12]}"

    @property
    def note(self) -> str:
        return "notes/embedded-image.md"

    @property
    def image_line(self) -> int:
        # Prose lines, then a blank line, then the image.
        return self.lines_before + 2


@dataclass(frozen=True)
class NoteSpec:
    """A folder with a checked-in Markdown note and a short note to start from.

    Use it for a hand-written specimen that a generator cannot reproduce.
    """
    name: str
    # Repository-relative path of the checked-in note.
    source: str

    @property
    def key(self) -> str:
        digest = hashlib.sha256((REPO_ROOT / self.source).read_bytes()).hexdigest()
        payload = json.dumps({"version": GENERATOR_VERSION, "kind": "note", **asdict(self),
                              "content": digest}, sort_keys=True)
        return f"{self.name}-{hashlib.sha256(payload.encode()).hexdigest()[:12]}"

    @property
    def note(self) -> str:
        return "notes/" + Path(self.source).name

    @property
    def start_note(self) -> str:
        return "notes/start.md"


@dataclass(frozen=True)
class VaultSpec:
    """A Markdown vault: a short task note to type into and longer notes that link to each other.

    Task items and wikilinks put `[` on most lines of each note, as in a
    to-do vault. The first project note links to the task note.
    """
    name: str
    projects: int = 8
    project_lines: int = 300
    task_lines: int = 95
    seed: int = 1

    @property
    def key(self) -> str:
        payload = json.dumps({"version": GENERATOR_VERSION, "kind": "vault", **asdict(self)},
                             sort_keys=True)
        return f"{self.name}-{hashlib.sha256(payload.encode()).hexdigest()[:12]}"

    @property
    def note(self) -> str:
        return "notes/tasks.md"

    @property
    def project_notes(self) -> list[str]:
        return [f"notes/project-{index:02d}.md" for index in range(self.projects)]

    @property
    def typing_line(self) -> int:
        # A task item in the middle of the note, with a wikilink after the typed text.
        return self.task_lines // 2


def default_cache_root() -> Path:
    base = os.environ.get("LOCALAPPDATA") or str(Path.home() / ".cache")
    # Projects report long paths. A short 8.3 name would not match them.
    return (Path(base) / "anvil-perf-fixtures").resolve()


def git(root: Path, *args: str, input_bytes: bytes | None = None) -> str:
    env = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
               GIT_CEILING_DIRECTORIES=str(root.parent))
    completed = subprocess.run(["git", *args], cwd=root, input=input_bytes, env=env,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if completed.returncode != 0:
        raise RuntimeError(f"git {' '.join(args[:3])} failed: "
                           + completed.stderr.decode("utf-8", "replace").strip())
    return completed.stdout.decode("utf-8", "replace")


def tracked_paths(spec: RepoSpec) -> list[str]:
    """Return the tracked file paths in a balanced directory tree."""
    rng = random.Random(spec.seed)
    paths: list[str] = []
    queue = deque([("src", 0)])
    directories = 0
    while queue and len(paths) < spec.files:
        directory, depth = queue.popleft()
        directories += 1
        for index in range(spec.files_per_dir):
            if len(paths) >= spec.files:
                break
            word = WORDS[rng.randrange(len(WORDS))]
            extension = LANGUAGES[rng.randrange(len(LANGUAGES))]
            paths.append(f"{directory}/{word}_{index:03d}{extension}")
        for child in range(spec.fanout):
            queue.append((f"{directory}/{WORDS[(directories + child) % len(WORDS)]}_{child:02d}",
                          depth + 1))
    return paths


def source_text(path: str, lines: int, revision: int) -> str:
    """Return plausible source text for the path's language."""
    stem = Path(path).stem
    extension = Path(path).suffix
    rows: list[str] = []
    for row in range(1, lines + 1):
        word = WORDS[(row * 7 + len(stem)) % len(WORDS)]
        if extension == ".lua":
            rows.append(f"local {word}_{row} = require(\"{stem}\").{word}({row}, {revision})")
        elif extension in (".c", ".h"):
            rows.append(f"static int {word}_{row}(int value) {{ return value * {row} + {revision}; }}")
        elif extension == ".py":
            rows.append(f"def {word}_{row}(value):\n    return value * {row} + {revision}")
        elif extension in (".js", ".ts"):
            rows.append(f"export function {word}{row}(value) {{ return value * {row} + {revision}; }}")
        elif extension == ".md":
            rows.append(f"## {word.title()} {row}\n\nThe {word} section of {stem}, revision {revision}.")
        else:
            rows.append(f'  "{word}_{row}": {row + revision},')
    if extension == ".json":
        return "{\n" + "\n".join(rows) + '\n  "end": 0\n}\n'
    return "\n".join(rows) + "\n"


def line_count(spec: RepoSpec, index: int) -> int:
    span = max(1, spec.max_lines - spec.min_lines + 1)
    return spec.min_lines + (index * 2654435761 + spec.seed) % span


def fast_import_stream(spec: RepoSpec, paths: list[str]) -> Iterator[bytes]:
    """Yield a `git fast-import` stream that builds the whole history."""
    gitignore = b"build/\nnode_modules/\n"
    for commit in range(1, spec.commits + 1):
        when = FIXED_MTIME - (spec.commits - commit) * 3600
        message = f"Fixture commit {commit}\n".encode()
        header = (f"commit refs/heads/main\ncommitter {COMMITTER} {when} +0000\n"
                  f"data {len(message)}\n").encode() + message
        yield header
        if commit == 1:
            yield f"M 100644 inline .gitignore\ndata {len(gitignore)}\n".encode() + gitignore + b"\n"
            selected = range(len(paths))
        else:
            # Later commits touch a small, stable share of the files.
            stride = max(1, len(paths) // max(1, len(paths) // 200))
            selected = range(commit % stride, len(paths), stride)
        for index in selected:
            data = source_text(paths[index], line_count(spec, index), commit).encode()
            yield f"M 100644 inline {paths[index]}\ndata {len(data)}\n".encode() + data + b"\n"
        yield b"\n"


def stride_pick(count: int, total: int, offset: int) -> list[int]:
    if count <= 0 or total <= 0:
        return []
    step = max(1, total // count)
    return [(offset + step * i) % total for i in range(min(count, total))]


def worktree_changes(spec: RepoSpec, paths: list[str]) -> dict[str, list[str]]:
    """Choose disjoint files for each working-tree change kind."""
    total = len(paths)
    used: set[int] = set()

    def pick(count: int, offset: int) -> list[str]:
        chosen = []
        for index in stride_pick(count * 2, total, offset):
            if index not in used and len(chosen) < count:
                used.add(index)
                chosen.append(paths[index])
        return chosen

    modified = pick(spec.modified, 1)
    staged = pick(spec.staged, 3)
    deleted = pick(spec.deleted, 5)
    untracked = []
    for index, path in enumerate(paths[::max(1, total // max(1, spec.untracked))][:spec.untracked]):
        parent = path.rsplit("/", 1)[0]
        untracked.append(f"{parent}/draft_{index:04d}.lua")
    return {"modified": modified, "staged": staged, "deleted": deleted, "untracked": untracked}


def write_bytes(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    os.utime(path, (FIXED_MTIME, FIXED_MTIME))


def write_text(path: Path, text: str) -> None:
    write_bytes(path, text.encode("utf-8"))


def changed_text(original: str, label: str) -> str:
    lines = original.splitlines()
    # One replaced line and three added lines give every changed file a diffstat.
    if len(lines) > 1:
        lines[1] = f"-- {label}: replaced line"
    lines.extend(f"-- {label}: added line {i}" for i in range(1, 4))
    return "\n".join(lines) + "\n"


def build_repo(spec: RepoSpec, root: Path) -> None:
    started = time.monotonic()
    root.mkdir(parents=True)
    paths = tracked_paths(spec)
    git(root, "init", "-q")
    for key, value in (("core.autocrlf", "false"), ("core.safecrlf", "false"),
                       ("gc.auto", "0"), ("user.name", "Anvil Fixture"),
                       ("user.email", "fixture@example.invalid")):
        git(root, "config", key, value)
    env = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
    importer = subprocess.Popen(["git", "fast-import", "--quiet"], cwd=root, env=env,
                                stdin=subprocess.PIPE, stderr=subprocess.PIPE)
    assert importer.stdin is not None
    for chunk in fast_import_stream(spec, paths):
        importer.stdin.write(chunk)
    importer.stdin.close()
    if importer.wait() != 0:
        raise RuntimeError("git fast-import failed: "
                           + (importer.stderr.read() if importer.stderr else b"").decode("utf-8", "replace"))
    git(root, "symbolic-ref", "HEAD", "refs/heads/main")
    git(root, "reset", "-q", "--hard")
    for index in range(spec.ignored):
        write_text(root / f"node_modules/package_{index // 50:03d}/lib/file_{index:05d}.js",
                   source_text(f"file_{index}.js", 12, 0))
    for current, _, names in os.walk(root):
        if ".git" in Path(current).parts:
            continue
        for name in names:
            os.utime(Path(current) / name, (FIXED_MTIME, FIXED_MTIME))
    # Refresh the index once, so later status checks do not rehash every file.
    git(root, "update-index", "-q", "--refresh")
    (root / ".git" / "anvil-fixture-files.txt").write_text("\n".join(paths), encoding="utf-8")
    print(f"Built fixture {spec.name}: {len(paths)} files, {spec.commits} commits "
          f"in {time.monotonic() - started:.1f}s", flush=True)


def build_folder(spec: FolderSpec, root: Path) -> None:
    root.mkdir(parents=True)
    for index, path in enumerate(tracked_paths(spec)):
        write_text(root / path, source_text(path, line_count(spec, index), 1))


def noise_png(width: int, height: int, rng: random.Random) -> bytes:
    """Return an RGB PNG of random pixels, so compression keeps it large."""
    def chunk(kind: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff))
    rows = b"".join(bytes(1) + rng.randbytes(width * 3) for _ in range(height))
    return (bytes((0x89,)) + b"PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows, 6)) + chunk(b"IEND", b""))


def prose_line(rng: random.Random, index: int) -> str:
    if index % 12 == 0:
        return f"## {WORDS[rng.randrange(len(WORDS))].title()} notes {index}"
    if index % 5 == 0:
        return "- " + " ".join(WORDS[rng.randrange(len(WORDS))] for _ in range(8))
    return " ".join(WORDS[rng.randrange(len(WORDS))] for _ in range(14)) + "."


def table_lines(rng: random.Random, number: int) -> list[str]:
    def cell() -> str:
        return " ".join(WORDS[rng.randrange(len(WORDS))] for _ in range(rng.randrange(1, 5)))
    rows = [f"| Item {number} | Owner | Status | Notes |", "| --- | --- | --- | --- |"]
    rows += [f"| {cell()} | {cell()} | {cell()} | {cell()} |" for _ in range(5)]
    return rows


def build_markdown(spec: MarkdownSpec, root: Path) -> None:
    rng = random.Random(spec.seed)
    image = base64.b64encode(noise_png(spec.image_width, spec.image_height, rng)).decode("ascii")
    lines = [prose_line(rng, index + 1) for index in range(spec.lines_before)]
    lines += ["", f"![](data:image/png;base64,{image})", "# After the image"]
    after = [prose_line(rng, index + 1) for index in range(spec.lines_after)]
    gap = max(1, spec.lines_after // (spec.tables + 1))
    for number in range(spec.tables, 0, -1):
        after[number * gap:number * gap] = ["", *table_lines(rng, number), ""]
    lines += after
    root.mkdir(parents=True)
    write_text(root / spec.note, "\n".join(lines) + "\n")


def build_note(spec: NoteSpec, root: Path) -> None:
    (root / "notes").mkdir(parents=True)
    shutil.copyfile(REPO_ROOT / spec.source, root / spec.note)
    write_text(root / spec.start_note, "# Start\n\nA short note to open first.\n")


def vault_line(rng: random.Random, index: int, projects: int) -> str:
    def words(count: int) -> str:
        return " ".join(WORDS[rng.randrange(len(WORDS))] for _ in range(count))
    if index % 12 == 0:
        return f"## {WORDS[rng.randrange(len(WORDS))].title()} {index}"
    if index % 4 == 0:
        return f"- [ ] {words(5)} [[project-{rng.randrange(projects):02d}]] {words(4)}"
    if index % 4 == 2:
        return f"- [x] {words(9)}"
    return words(14) + "."


def build_vault(spec: VaultSpec, root: Path) -> None:
    rng = random.Random(spec.seed)
    tasks = ["# Tasks", ""] + [vault_line(rng, index, spec.projects)
                               for index in range(1, spec.task_lines - 1)]
    tasks[spec.typing_line - 1] = f"- [ ] Call about the {WORDS[0]} [[project-01]] before Friday"
    write_text(root / spec.note, "\n".join(tasks) + "\n")
    for number, path in enumerate(spec.project_notes):
        lines = [f"# Project {number:02d}", ""]
        if number == 0:
            lines += ["Open items live in [[tasks]].", ""]
        lines += [vault_line(rng, index, spec.projects) for index in range(1, spec.project_lines)]
        write_text(root / path, "\n".join(lines) + "\n")


def pathspec(root: Path, command: str, paths: list[str], *options: str) -> None:
    if paths:
        # Large lists exceed the Windows command-line limit.
        git(root, command, *options, "--pathspec-from-file=-", input_bytes="\n".join(paths).encode())


def apply_worktree(spec: RepoSpec, root: Path, touched: list[str] | None = None) -> dict[str, list[str]]:
    """Restore the fixture commit, then apply the spec's working-tree changes.

    `touched` lists further tracked paths that a scene may edit during a run.
    """
    paths = (root / ".git" / "anvil-fixture-files.txt").read_text(encoding="utf-8").split("\n")
    changes = worktree_changes(spec, paths)
    touched = sorted(set(touched or []))
    applied = root / ".git" / "anvil-fixture-applied.json"
    originals = root / ".git" / "anvil-fixture-originals"
    previous = json.loads(applied.read_text(encoding="utf-8")) if applied.exists() else None
    restorable = previous is not None and set(previous["touched"]) <= set(touched) and all(
        (originals / path).exists()
        for path in previous["modified"] + previous["staged"] + previous["deleted"] + previous["touched"])
    if restorable:
        # Copying saved originals back keeps Git from rewriting a large index for each run.
        for path in previous["untracked"]:
            (root / path).unlink(missing_ok=True)
        for path in previous["modified"] + previous["staged"] + previous["deleted"] + previous["touched"]:
            write_bytes(root / path, (originals / path).read_bytes())
        pathspec(root, "reset", previous["staged"], "-q")
    else:
        git(root, "reset", "-q", "--hard")
        git(root, "clean", "-fdq")
        shutil.rmtree(originals, ignore_errors=True)
    applied.unlink(missing_ok=True)
    for path in changes["modified"] + changes["staged"] + changes["deleted"] + touched:
        saved = originals / path
        if not saved.exists():
            saved.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(root / path, saved)
    for path in changes["modified"] + changes["staged"]:
        target = root / path
        write_text(target, changed_text(target.read_text(encoding="utf-8"), "change"))
    pathspec(root, "add", changes["staged"])
    for path in changes["deleted"]:
        (root / path).unlink()
    for path in changes["untracked"]:
        write_text(root / path, source_text(path, 10, 99))
    applied.write_text(json.dumps(dict(changes, touched=touched)), encoding="utf-8")
    return changes


class Churn:
    """Edit files in a fixture in the background, as a build or a coding agent does.

    Each write appends a line to one of the spec's modified files, so Git status
    keeps the same entries while the file watcher and status refresh keep
    running. The next `apply_worktree` restores these files.
    """

    def __init__(self, spec: RepoSpec, root: Path, interval: float):
        paths = (root / ".git" / "anvil-fixture-files.txt").read_text(encoding="utf-8").split("\n")
        self.paths = worktree_changes(spec, paths)["modified"]
        if not self.paths:
            raise ValueError(f"fixture {spec.name} has no modified files to churn")
        self.root, self.interval = root, interval
        self.writes = 0
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, name="fixture-churn", daemon=True)

    def _run(self) -> None:
        while not self._stop.wait(self.interval):
            target = self.root / self.paths[self.writes % len(self.paths)]
            with target.open("a", encoding="utf-8", newline="\n") as stream:
                stream.write(f"-- churn {self.writes}\n")
            self.writes += 1

    def __enter__(self) -> "Churn":
        self._thread.start()
        return self

    def __exit__(self, *_exc) -> None:
        self._stop.set()
        self._thread.join()


def clean_files(spec: RepoSpec | FolderSpec, count: int) -> list[str]:
    """Return tracked files that the working-tree changes leave untouched, spread over the tree."""
    paths = tracked_paths(spec)
    changed = set()
    if isinstance(spec, RepoSpec):
        changed = {path for paths_of_kind in worktree_changes(spec, paths).values() for path in paths_of_kind}
    clean = [path for path in paths if path not in changed]
    return [clean[index] for index in stride_pick(count, len(clean), 7)]


def members(spec: ProjectSetSpec) -> list[tuple[str, RepoSpec]]:
    """Return each Project's folder name and repository spec."""
    return [(f"project-{index:02d}", RepoSpec(**dict(asdict(spec.repo), name=f"project-{index:02d}",
                                                     seed=spec.repo.seed + index)))
            for index in range(spec.projects)]


def materialize(spec: RepoSpec | FolderSpec | ProjectSetSpec | MarkdownSpec | NoteSpec | VaultSpec,
                cache_root: Path | None = None,
                rebuild: bool = False, touched: list[str] | None = None) -> Path:
    """Return a ready fixture root, building it into the cache when needed.

    `touched` lists tracked files that a scene edits. The next call restores them.
    """
    cache_root = cache_root or default_cache_root()
    root = cache_root / spec.key
    marker = root.with_name(root.name + ".complete")
    if rebuild or not marker.exists():
        if root.exists():
            shutil.rmtree(root, onerror=_make_writable)
        marker.unlink(missing_ok=True)
        if isinstance(spec, ProjectSetSpec):
            root.mkdir(parents=True)
            for name, member in members(spec):
                build_repo(member, root / name)
        elif isinstance(spec, FolderSpec):
            build_folder(spec, root)
        elif isinstance(spec, MarkdownSpec):
            build_markdown(spec, root)
        elif isinstance(spec, NoteSpec):
            build_note(spec, root)
        elif isinstance(spec, VaultSpec):
            build_vault(spec, root)
        else:
            build_repo(spec, root)
        marker.write_text(json.dumps(asdict(spec), indent=2), encoding="utf-8")
    if isinstance(spec, ProjectSetSpec):
        for name, member in members(spec):
            apply_worktree(member, root / name)
    elif isinstance(spec, RepoSpec):
        apply_worktree(spec, root, touched)
    return root


def _make_writable(function, path, _exc_info) -> None:
    # Git marks pack files read-only.
    os.chmod(path, 0o666)
    function(path)
