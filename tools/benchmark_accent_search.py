"""Compare literal ripgrep with accent-equivalent patterns on private generated Projects.

This is a scan experiment, not an editor benchmark. Output goes to the null device,
so times include ripgrep formatting but exclude editor ranking and drawing.
"""
import argparse
import json
from pathlib import Path
import random
import statistics
import subprocess
import tempfile
import time
import unicodedata


def pattern(probe, query, sensitive=False):
    result = subprocess.run([str(probe)] + (["--case-sensitive"] if sensitive else []),
                            input=query.encode("utf-8"), capture_output=True, check=True)
    return result.stdout.decode("ascii").strip()


def check_variants(rg, probe, root):
    """Check candidate retention against independent Unicode decompositions."""
    variants = []
    for cp in list(range(0xC0, 0x250)) + list(range(0x1E00, 0x1F00)):
        text = chr(cp)
        nfd = unicodedata.normalize("NFD", text)
        base = "".join(c for c in nfd if not unicodedata.combining(c))
        if len(base) == 1 and base.isascii() and base.isalpha():
            if text in "ñÑ":
                base = text
            variants.extend([(text, base), (nfd, base)])
    for cp in range(0x110000):
        text = chr(cp)
        decomposition = unicodedata.decomposition(text)
        if not decomposition or decomposition.startswith("<"):
            continue
        nfd = unicodedata.normalize("NFD", text)
        base = "".join(c for c in nfd if not unicodedata.combining(c))
        if len(base) > 1:
            # Only NFC-composable forms share a query. Other forms must still find themselves.
            composed_query = base if unicodedata.normalize("NFC", nfd) == text else text
            variants.extend([(text, composed_query), (nfd, base)])
    path = root / "unicode-oracle.txt"
    path.write_text("\n".join(text for text, _ in variants) + "\n", encoding="utf-8")
    for sensitive in (False, True):
        for query in sorted({base for _, base in variants}):
            cmd = [rg, "--no-config", "-n"] + ([] if sensitive else ["-i"])
            result = subprocess.run(cmd + ["-e", pattern(probe, query, sensitive), str(path)],
                                    capture_output=True, check=True)
            lines = {int(line.split(b":", 1)[0]) for line in result.stdout.splitlines()}
            expected = {i + 1 for i, (_, base) in enumerate(variants)
                        if (base == query if sensitive else base.casefold() == query.casefold())}
            missing = expected - lines
            if missing:
                raise AssertionError((query, sensitive, [variants[i - 1] for i in missing]))
    path.unlink()
    print(f"Candidate filter kept all {len(variants)} canonical variants", flush=True)
    return len(variants)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rg", type=Path, default=Path("data/plugins/fuzzy_searcher/rg.exe"))
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--files", type=int, default=512)
    parser.add_argument("--lines", type=int, default=640)
    parser.add_argument("--probe", type=Path, default=Path("build-windows-x86_64/accent_search_probe.exe"))
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    rg = str(args.rg.resolve())
    probe = args.probe.resolve()
    queries = ["a", "cafe", "café", "resume", "configuration", "missing_configuration_xyz",
               "cafe con leche", "render_widget(value)", "niño", "nino"]
    report = {"runs": args.runs, "files": args.files, "lines": args.lines, "results": []}
    patterns = {query: pattern(probe, query) for query in queries}
    report["prepare_ms"] = {
        query: float(subprocess.run([str(probe), "--bench"], input=query.encode("utf-8"),
                                    capture_output=True, check=True).stdout)
        for query in queries
    }
    with tempfile.TemporaryDirectory(prefix="anvil-accent-scan-") as temp:
        report["checked_variants"] = check_variants(rg, probe, Path(temp))
        for kind in ("ascii", "notes"):
            root = Path(temp) / kind
            root.mkdir()
            size = 0
            for index in range(args.files):
                rows = []
                for line in range(args.lines):
                    text = f"configuration_{index}_{line}: render_widget(value); return sample_value;"
                    if kind == "notes":
                        text = f"La configuración del café {index} incluye información y un resumen número {line}."
                    if line % 53 == 0:
                        text += " cafe con leche résumé café cafe\u0301 niño nin\u0303o"
                    rows.append(text)
                data = ("\n".join(rows) + "\n").encode("utf-8")
                (root / f"part-{index:04d}.txt").write_bytes(data)
                size += len(data)
            for query in queries:
                commands = {
                    "literal": [rg, "-F", "-i", "-e", query],
                    "equivalent": [rg, "-i", "-e", patterns[query]],
                }
                for cmd in commands.values():
                    cmd.extend(["--no-config", "--line-number", "--column", "--with-filename",
                                "--color", "never", "--max-columns", "4096", "."])
                    subprocess.run(cmd, cwd=root, stdout=subprocess.DEVNULL, check=False)
                samples = {key: [] for key in commands}
                order = list(commands) * args.runs
                random.Random(37).shuffle(order)
                for key in order:
                    start = time.perf_counter()
                    result = subprocess.run(commands[key], cwd=root, stdout=subprocess.DEVNULL,
                                            stderr=subprocess.PIPE, timeout=60)
                    if result.returncode not in (0, 1):
                        raise RuntimeError(result.stderr.decode("utf-8", errors="replace"))
                    samples[key].append((time.perf_counter() - start) * 1000)
                medians = {key: statistics.median(values) for key, values in samples.items()}
                counts = {}
                for key, query_pattern in (("literal", query), ("equivalent", patterns[query])):
                    cmd = [rg, "--no-config", "-i", "--count"]
                    if key == "literal":
                        cmd.append("-F")
                    result = subprocess.run(cmd + ["-e", query_pattern, "."], cwd=root,
                                            capture_output=True, timeout=60)
                    if result.returncode not in (0, 1):
                        raise RuntimeError(result.stderr.decode("utf-8", errors="replace"))
                    counts[key] = sum(int(line.rsplit(b":", 1)[1]) for line in result.stdout.splitlines())
                row = {"project": kind, "bytes": size, "query": query, "median_ms": medians,
                       "ratio": medians["equivalent"] / medians["literal"], "samples_ms": samples,
                       "matching_lines": counts}
                report["results"].append(row)
                print(f"{kind:5} {query:28} {medians['literal']:8.1f} -> "
                      f"{medians['equivalent']:8.1f} ms ({row['ratio']:.2f}x); "
                      f"lines {counts['literal']} -> {counts['equivalent']}", flush=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")


if __name__ == "__main__":
    main()
