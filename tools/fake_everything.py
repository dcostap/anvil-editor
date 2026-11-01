"""A fake Everything HTTP server for Path Search scenarios.

Path Search asks Everything (http://localhost:5777/ by default) for folders and
files anywhere on the PC. A scenario cannot depend on the real Everything and the
real disk, so this server answers the same JSON queries from one folder tree.

It understands the query parts that the Fuzzy Searcher sends: `file:`, `folder:`,
`ancestor:"<path>"` and plain words. Each word must appear in the item's name or
path, without regard to case unless `case=1`. Results are sorted by path and paged
with `offset` and `count`, as Everything does.
"""
from __future__ import annotations

from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shlex
import threading
from typing import Any
from urllib.parse import parse_qs, urlparse

# Seconds between 1601-01-01 (Windows FILETIME) and 1970-01-01.
FILETIME_EPOCH_SECONDS = 11644473600


@dataclass(frozen=True)
class Item:
    folder: bool
    parent: str
    name: str
    size: int
    modified: float

    @property
    def path(self) -> str:
        return os.path.join(self.parent, self.name)


def scan(root: Path) -> list[Item]:
    """Return every folder and file under `root`, without `.git` contents."""
    items = []
    for parent, folders, files in os.walk(root):
        folders[:] = [name for name in folders if name != ".git"]
        for name in folders:
            stat = os.stat(os.path.join(parent, name))
            items.append(Item(True, parent, name, 0, stat.st_mtime))
        for name in files:
            stat = os.stat(os.path.join(parent, name))
            items.append(Item(False, parent, name, stat.st_size, stat.st_mtime))
    items.sort(key=lambda item: item.path.lower())
    return items


def parse_search(search: str) -> tuple[str | None, list[str], list[str]]:
    """Split an Everything search into its kind, ancestor folders and plain words."""
    kind, ancestors, words = None, [], []
    for part in shlex.split(search.replace("\\", "\\\\"), posix=True):
        lowered = part.lower()
        if lowered in ("file:", "folder:"):
            kind = lowered[:-1]
        elif lowered.startswith("ancestor:"):
            ancestors.append(part[len("ancestor:"):])
        elif part:
            words.append(part)
    return kind, ancestors, words


def matches(item: Item, kind: str | None, ancestors: list[str], words: list[str], case: bool) -> bool:
    if kind == "file" and item.folder or kind == "folder" and not item.folder:
        return False
    path = item.path if case else item.path.lower()
    for ancestor in ancestors:
        prefix = os.path.normcase(os.path.normpath(ancestor)) + os.sep
        if not os.path.normcase(item.path).startswith(prefix):
            return False
    return all((word if case else word.lower()) in path for word in words)


def search(items: list[Item], params: dict[str, str]) -> dict[str, Any]:
    kind, ancestors, words = parse_search(params.get("search", ""))
    case = params.get("case") == "1"
    found = [item for item in items if matches(item, kind, ancestors, words, case)]
    offset = int(params.get("offset", "0") or 0)
    count = int(params.get("count", "100") or 100)
    page = found[offset:offset + count]
    return {"totalResults": len(found), "results": [{
        "type": "folder" if item.folder else "file",
        "name": item.name,
        "path": item.parent,
        "size": "" if item.folder else str(item.size),
        "date_modified": str(int((item.modified + FILETIME_EPOCH_SECONDS) * 10_000_000)),
    } for item in page]}


class FakeEverything:
    """Serve one folder tree on a free local port. Use it as a context manager."""

    def __init__(self, root: Path):
        self.items = scan(root)
        self.requests: list[dict[str, str]] = []
        items, requests = self.items, self.requests

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # noqa: N802 - the http.server API
                params = {key: values[-1] for key, values in parse_qs(urlparse(self.path).query).items()}
                requests.append(params)
                body = json.dumps(search(items, params)).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args: Any) -> None:
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    @property
    def port(self) -> int:
        return self.server.server_address[1]

    def environment(self) -> dict[str, str]:
        return {"EVERYTHING_HOST": "127.0.0.1", "EVERYTHING_PORT": str(self.port)}

    def __enter__(self) -> "FakeEverything":
        self.thread.start()
        return self

    def __exit__(self, *exc: Any) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
