#!/usr/bin/env python3
"""Import single-line inline presentation cases from CommonMark 0.31.2."""

import argparse
from collections import Counter
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
from urllib.request import urlopen

VERSION = "0.31.2"
URL = f"https://spec.commonmark.org/{VERSION}/spec.json"
SOURCE_SHA256 = "d431b29d97b6f73e69d547109cf5081578fac931e72afe95639ebe766c1b2a20"
OUTPUT = Path(__file__).resolve().parents[1] / "tests/fixtures/markdown/commonmark-inline.json"
SECTIONS = {
    "Backslash escapes",
    "Code spans",
    "Emphasis and strong emphasis",
    "Textual content",
}


class OutsideScope(ValueError):
    pass


class InlineRuns(HTMLParser):
    """Read reference HTML, not Markdown. Keep text and font semantics only."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack = []
        self.runs = []
        self.paragraphs = 0

    def handle_starttag(self, tag, attrs):
        if tag not in {"p", "em", "strong", "code"} or attrs:
            raise OutsideScope("other HTML elements")
        if tag == "p":
            self.paragraphs += 1
            if self.stack or self.paragraphs != 1:
                raise OutsideScope("multiple paragraphs")
        elif not self.stack:
            raise OutsideScope("text outside a paragraph")
        self.stack.append(tag)

    def handle_endtag(self, tag):
        if not self.stack or self.stack.pop() != tag:
            raise OutsideScope("unbalanced HTML")

    def handle_data(self, text):
        if not self.stack:
            if text.strip():
                raise OutsideScope("text outside a paragraph")
            return
        if "code" in self.stack:
            style = "code"
        elif "strong" in self.stack and "em" in self.stack:
            style = "strong_emphasis"
        elif "strong" in self.stack:
            style = "strong"
        elif "em" in self.stack:
            style = "emphasis"
        else:
            style = "normal"
        if self.runs and self.runs[-1]["style"] == style:
            self.runs[-1]["text"] += text
        elif text:
            self.runs.append({"text": text, "style": style})

    def handle_comment(self, data):
        raise OutsideScope("HTML comments")


def convert(raw):
    cases = []
    excluded = Counter()
    for example in json.loads(raw):
        if example["section"] not in SECTIONS:
            continue
        source = example["markdown"]
        if not source.endswith("\n") or "\n" in source[:-1] or "\r" in source:
            excluded["multiline source"] += 1
            continue
        parser = InlineRuns()
        try:
            parser.feed(example["html"])
            parser.close()
            if parser.stack or parser.paragraphs != 1:
                raise OutsideScope("not one paragraph")
        except OutsideScope as error:
            excluded[str(error)] += 1
            continue
        cases.append({
            "example": example["example"],
            "section": example["section"],
            "markdown": source,
            "html": example["html"],
            "runs": parser.runs,
        })
    return {
        "version": VERSION,
        "source": URL,
        "source_sha256": hashlib.sha256(raw).hexdigest(),
        "sections": sorted(SECTIONS),
        "excluded": dict(sorted(excluded.items())),
        "cases": cases,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, help="Use a local spec.json instead of downloading it")
    parser.add_argument("--check", action="store_true", help="Check the committed fixture without writing it")
    args = parser.parse_args()
    if args.source:
        raw = args.source.read_bytes()
    else:
        with urlopen(URL, timeout=30) as response:
            raw = response.read()
    if hashlib.sha256(raw).hexdigest() != SOURCE_SHA256:
        raise SystemExit("CommonMark source digest differs; review the source before changing the pin")
    result = convert(raw)
    output = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    if args.check:
        if OUTPUT.read_text(encoding="utf-8") != output:
            raise SystemExit("CommonMark inline fixture differs; run the importer without --check")
    else:
        OUTPUT.write_text(output, encoding="utf-8", newline="\n")
    print(f"{len(result['cases'])} cases; excluded: {result['excluded']}")


if __name__ == "__main__":
    main()
